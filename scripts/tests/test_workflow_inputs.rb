# frozen_string_literal: true

require_relative "test_helper"

class XcodeBuildInputTests < Minitest::Test
  include WorkflowHelpers

  def validate(value)
    command("/bin/bash", ROOT.join("scripts/validate-xcode-build.sh"), value)
  end

  def test_every_published_xcode_build_is_accepted
    JSON.parse(ROOT.join("data/xcode/releases.json").read).each do |entry|
      assert validate(entry.fetch("buildNumber")).success?, entry.fetch("buildNumber")
    end
  end

  def test_untrusted_build_syntax_is_rejected
    ["", "17E5170d\nXIP_FILE=/tmp/other.xip", "17E5170d\rXIP_FILE=/tmp/other.xip",
     "17E5170d/../../other", '17E5170d\other', "17E5170d ", "17e5170d", "17E5170dd", "１７E5170d"].each do |value|
      result = validate(value)
      refute result.success?, value.inspect
      assert_empty result.stdout
      assert_empty result.stderr
    end
  end
end

class WorkflowSafetyContractTests < Minitest::Test
  include WorkflowHelpers

  def test_site_dispatch_cannot_cancel_main_deployment
    workflow = ROOT.join(".github/workflows/deploy-site.yml").read
    assert_includes workflow, "group: ${{ github.ref == 'refs/heads/main' && 'deploy-site' || format('rejected-deploy-{0}', github.run_id) }}"
    push = workflow.split("  workflow_dispatch:", 2).first
    %w[.github/workflows/deploy-site.yml scripts/check-npm-install-policy.mjs scripts/lint-json.rb scripts/strict-json.rb].each do |path|
      assert_includes push, "      - '#{path}'"
    end
    script = workflow_run_block(workflow.split("\n  build:", 2).first, "Validate deployment ref")
    { "refs/heads/main" => true, "refs/heads/topic" => false, "refs/tags/main" => false }.each do |ref, accepted|
      result = bash(script, env: { "GITHUB_REF" => ref, "REF_NAME" => ref.split("/").last })
      assert_equal accepted, result.success?, ref
    end
  end

  def test_site_build_never_runs_with_deploy_credentials
    workflow = ROOT.join(".github/workflows/deploy-site.yml").read
    build = workflow.split("\n  build:\n", 2).last.split("\n  deploy:\n", 2).first
    deploy = workflow.split("\n  deploy:\n", 2).last
    assert_includes build, "run: npm run build\n"
    refute_includes build, "environment:"
    refute_includes build, "secrets."
    assert_includes deploy, "    needs: build\n"
    assert_includes deploy, "    environment: cloudflare\n"
    assert_includes deploy, "run: npm run deploy\n"
    ["npm run build", "npm run check", "npm test", "astro", "wrangler.json"].each { |cmd| refute_includes deploy, cmd }
  end

  def test_rescan_reads_only_verified_cache_and_publishes_as_replacement
    workflow = RESCAN_WORKFLOW.read
    scan = workflow.split("\n  scan:\n", 2).last.split("\n  publish:\n", 2).first
    publish = workflow.split("\n  publish:\n", 2).last
    %w[curl wget --save-aea-key ADC_DOWNLOAD_AUTH].each { |fetch| refute_includes workflow, fetch }
    refute_includes scan, "environment:"
    refute_includes scan, "secrets."
    assert_operator scan.index("- name: Verify cached archive checksum"), :<, scan.index("- name: Rescan archive")
    assert_includes scan, 'if [[ -L "${path}" || ! -f "${path}" ]]; then'
    assert_includes publish, "ruby scripts/verify-release-artifact.rb \\\n            --replace \\\n"
    assert_operator publish.index("--replace"), :<, publish.index("- name: Mint bot token")
  end

  def test_scanner_dispatch_requires_main_before_checkout
    [IPSW_WORKFLOW, XIP_WORKFLOW, RESCAN_WORKFLOW].each do |path|
      workflow = path.read
      assert_operator workflow.index("- name: Require main branch"), :<, workflow.index("- uses: actions/checkout@")
      script = workflow_run_block(workflow, "Require main branch")
      { "refs/heads/main" => true, "refs/heads/topic" => false, "refs/tags/main" => false }.each do |ref, accepted|
        assert_equal accepted, bash(script, env: { "GITHUB_REF" => ref }).success?, "#{path}: #{ref}"
      end
    end
  end

  def test_release_verifies_cli_notarization_without_spctl
    script = workflow_run_block(RELEASE_WORKFLOW.read, "Notarize binary")
    expected = "if codesign --verify --strict -R='notarized' --check-notarization --verbose=4 \"${BINARY}\"; then"
    assert_equal [expected], script.lines.map(&:strip).select { |line| line.include?("--check-notarization") }
    ["for attempt in 1 2 3", "if (( status != 3 || attempt == 3 ))", "sleep 10"].each { |text| assert_includes script, text }
    refute_includes script, "spctl --assess"
  end

  def test_workflow_changes_run_script_contract_tests
    assert_includes workflow_run_block(CI_WORKFLOW.read, "Generate CI matrix"), "matches_changed_path '^\\.github/workflows/|^scripts/"
  end

  def test_device_registry_and_site_workflow_changes_select_site_checks
    script = workflow_run_block(CI_WORKFLOW.read, "Generate CI matrix")
    { "Sources/macOSdbCore/Models/DeviceRegistry.swift" => true,
      "Sources/macOSdbCore/ReleasePublicationValidator.swift" => false,
      ".github/workflows/ci.yml" => true, ".ruby-version" => true, "Gemfile.lock" => true }.each do |path, expected|
      assert ROOT.join(path).file?, "Routing fixture must name a real file: #{path}"
      Dir.mktmpdir do |directory|
        root = Pathname.new(directory)
        executable(root.join("git"), "#!/bin/sh\nprintf '%s\\0' '#{path}'\n")
        result = command("bash", "-euo", "pipefail", "-c", script, env: {
          "PATH" => "#{root}:#{ENV.fetch('PATH')}", "EVENT_NAME" => "pull_request", "BASE_SHA" => "fixture",
          "RUNNER_TEMP" => directory, "GITHUB_OUTPUT" => root.join("output").to_s
        })
        assert result.success?, result.stderr
        outputs = root.join("output").read.lines(chomp: true).map { |line| line.split("=", 2) }.to_h
        checks = JSON.parse(outputs.fetch("matrix")).map { |entry| entry.fetch("check") }
        assert_equal expected, checks.include?("site"), checks.inspect
        if [".ruby-version", "Gemfile.lock"].include?(path)
          assert_includes checks, "lint-json"
          assert_includes checks, "script-tests"
          assert_equal "true", outputs.fetch("run_codeql_interpreted")
        end
      end
    end
  end

  def test_pr_link_check_resolves_production_urls_against_the_built_site
    links = CI_WORKFLOW.read.split("  links:\n", 2).last.split("\n  conclusion:\n", 2).first
    args = JSON.parse(links.match(/args: ("[^\n]+")/)[1])
    assert_includes args, '--remap "^https://macosdb\.com/ file://${GITHUB_WORKSPACE}/site/dist/client/"'
    assert_includes args, '--remap "^https://macosdb\.com/404/$ file://${GITHUB_WORKSPACE}/site/dist/client/404.html"'
    refute_includes links, "--exclude ^https://macosdb"
  end

  def test_coverage_upload_is_isolated_and_uses_oidc_for_dependabot
    workflow = CI_WORKFLOW.read
    upload = workflow.split("  codecov:\n", 2).last.split("\n  zizmor:\n", 2).first
    assert_includes upload, "id-token: write"
    assert_includes upload, "python3 -I codecov-uploader/scripts/upload-codecov.py"
    assert_includes upload, "github.event.pull_request.base.sha || github.sha"
    refute_includes upload, "dependabot[bot]"
    refute_includes workflow, "CODECOV_TOKEN"
    refute_includes upload, "continue-on-error"
    refute_includes upload, "bundle install"
  end

  def test_xip_checks_existing_hashes_before_scanning_and_creates_new_ones_after_validation
    workflow = XIP_WORKFLOW.read
    ["Verify existing SHA-256 sidecar", "Scan XIP", "Lint JSON", "Package release JSON",
     "Create or verify SHA-256 sidecar", "Lock archive files"].each_cons(2) do |left, right|
      assert_operator workflow.index("- name: #{left}"), :<, workflow.index("- name: #{right}")
    end
    start = workflow.index('if [[ -f "${XIP_FILE}" ]]')
    finish = workflow.index('if [[ -z "${ADC_DOWNLOAD_AUTH}" ]]', start)
    cached = workflow[start...finish]
    assert_includes cached, "Preserving it for investigation"
    refute_includes cached, 'rm -f "${XIP_FILE}"'
    validation = workflow[workflow.index("- name: Validate XIP")...workflow.index("- name: Set or verify XIP modification time")]
    assert_includes validation, "steps.download-xip.outputs.downloaded"
    assert_includes validation, 'if [[ "${DOWNLOADED}" == "true" ]]'
    assert_includes validation, "Preserving the invalid preexisting cache entry"
  end

  def test_process_runner_reopens_stdin_after_capture_file_actions
    source = ROOT.join("Sources/macOSdbCore/Scanner/ProcessRunner.swift").read
    assert_operator source.index("try configure(stderr, as: STDERR_FILENO"), :<,
                    source.index("posix_spawn_file_actions_addopen(\n            &actions,\n            STDIN_FILENO")
  end

  def test_ipsw_url_gate_rejects_queries_and_fragments
    resolve = workflow_run_block(IPSW_WORKFLOW.read, "Resolve IPSW path")
    pattern = resolve.match(/\[\[ ! "\$\{IPSW_URL\}" =~ (\S+) \]\]/)[1]
    filename = "UniversalMac_27.0_26A123_Restore.ipsw"
    { "https://updates.cdn-apple.com/2026/macos/abc/#{filename}" => true,
      "https://updates.cdn-apple.com/2026/macos/abc/#{filename}?download=1" => false,
      "https://updates.cdn-apple.com/2026/macos/abc/#{filename}#fragment" => false,
      "https://updates.cdn-apple.com/a/other.ipsw#/#{filename}" => false,
      "https://updates.cdn-apple.com/a?b/#{filename}" => false }.each do |url, expected|
      assert_equal expected, command("/bin/bash", "-c", "[[ \"$1\" =~ #{pattern} ]]", "gate", url).success?, url
    end
  end

  def test_ipsw_cache_filename_requires_a_canonical_build_number
    assert_includes IPSW_WORKFLOW.read, '^UniversalMac_[0-9]+(\.[0-9]+){1,2}_[0-9]+[A-Z][0-9]+[a-z]?_Restore\.ipsw$'
  end
end
