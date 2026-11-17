# frozen_string_literal: true

require "yaml"

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
    ["", "17E5170d\nARCHIVE_FILE=/tmp/other.xip", "17E5170d\rARCHIVE_FILE=/tmp/other.xip",
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
    [IPSW_WORKFLOW, XCODE_WORKFLOW, RESCAN_WORKFLOW].each do |path|
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

  def test_xcode_checks_existing_hashes_before_scanning_and_creates_new_ones_after_validation
    workflow = XCODE_WORKFLOW.read
    ["Verify existing SHA-256 sidecar", "Scan Xcode archive", "Lint JSON", "Package release JSON",
     "Create or verify SHA-256 sidecar", "Lock archive files"].each_cons(2) do |left, right|
      assert_operator workflow.index("- name: #{left}"), :<, workflow.index("- name: #{right}")
    end
    start = workflow.index('if [[ -f "${ARCHIVE_FILE}" ]]')
    finish = workflow.index('if [[ -z "${ADC_DOWNLOAD_AUTH}" ]]', start)
    cached = workflow[start...finish]
    assert_includes cached, "Preserving it for investigation"
    refute_includes cached, 'rm -f "${ARCHIVE_FILE}"'
    validation = workflow[workflow.index("- name: Validate archive")...workflow.index("- name: Set or verify archive modification time")]
    assert_includes validation, "steps.download-archive.outputs.downloaded"
    assert_includes validation, 'if [[ "${DOWNLOADED}" == "true" ]]'
    assert_includes validation, "Preserving the invalid preexisting cache entry"
  end

  def test_xcode_download_gate_accepts_only_xip_and_aea_paths
    resolve = workflow_run_block(XCODE_WORKFLOW.read, "Resolve archive path")
    path_pattern = resolve.match(/\[\[ ! "\$\{DOWNLOAD_PATH\}" =~ (\S+) \]\]/)[1]
    name_pattern = resolve.match(/\[\[ ! "\$\{ORIG_NAME\}" =~ (\S+) \]\]/)[1]
    matches = ->(pattern, value) { command("/bin/bash", "-c", "[[ \"$1\" =~ #{pattern} ]]", "gate", value).success? }
    { "/Developer_Tools/Xcode_27.3_beta_2/Xcode_27.3_beta_2.xip" => true,
      "/Developer_Tools/Xcode_27.4_beta/Xcode_27.4_beta.aea" => true,
      "/Developer_Tools/Xcode_27.4_beta/Xcode_27.4_beta.AEA" => false,
      "/Developer_Tools/Xcode_27.4_beta/Xcode_27.4_beta.dmg" => false,
      "/Developer_Tools/Xcode_27.4_beta/Xcode_27.4_beta.aea?x=1" => false,
      "@evil.example.com/Xcode_27.4.aea" => false }.each do |value, expected|
      assert_equal expected, matches.call(path_pattern, value), value
    end
    { "Xcode_27.3_beta_2.xip" => true, "Xcode_27.4.aea" => true, "Xcode_27.4_Release_Candidate.aea" => true,
      "Xcode-27.4.aea" => false, "Xcode_27.4.aea.xip" => false, "Xcode_27.4.ipsw" => false }.each do |value, expected|
      assert_equal expected, matches.call(name_pattern, value), value
    end
    assert_includes resolve, 'ARCHIVE_FORMAT="${ORIG_NAME##*.}"'
    assert_includes resolve, 'ARCHIVE_FILE="${ARCHIVE_DIR}/Xcode-${VERSION}-${BUILD}.${ARCHIVE_FORMAT}"'
  end

  # A minimal xar header: magic, header size, version, two TOC lengths, SHA-1.
  XAR_HEADER = ["xar!", 28, 1, 1, 1, 1].pack("a4nnQ>Q>N").ljust(64, "\0").b.freeze
  AEA_HEADER = "AEA1#{"\0" * 60}".b.freeze
  XCODE_ARCHIVE_HEADERS = { "xip" => XAR_HEADER, "aea" => AEA_HEADER }.freeze
  MINIMUM_ARCHIVE_BYTES = 104_857_600
  FORMAT_CHECK = ROOT.join("scripts/check-xcode-archive-format.sh")
  # Fails the way a read from a dropped or locked volume does.
  FAILING_READ = { "head" => "echo 'head: Input/output error' >&2\nexit 1" }.freeze
  # Stands in for Apple's CDN: answers the header probes, then delivers CURL_DELIVERY.
  DOWNLOAD_STUBS = { "sleep" => "exit 0", "curl" => <<~'SH' }.freeze
    out=""; write_out=""; headers=false
    while (($#)); do
      case "$1" in
        -o) out="$2"; shift ;;
        -w) write_out="$2"; shift ;;
        -sSI) headers=true ;;
      esac
      shift
    done
    if [[ "${headers}" == true ]]; then
      if [[ -n "${write_out}" ]]; then printf '200'; else printf 'content-type: application/octet-stream\r\ncontent-length: 64\r\n'; fi
      exit 0
    fi
    [[ -f "${CURL_DELIVERY}" ]] || exit 22
    cat "${CURL_DELIVERY}" > "${out}"
  SH

  # The archive checks must not consult file(1), which exits 0 for a file it cannot read.
  def in_archive_fixture(format, contents, size: nil, stubs: {})
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory).realpath
      bin = root.join("bin")
      bin.mkdir
      stubs = { "file" => "touch '#{root.join('file-was-called')}'\necho data" }.merge(stubs)
      stubs = stubs.merge("stat" => "echo #{size}") if size
      stubs.each { |name, script| executable(bin.join(name), "#!/bin/bash\n#{script}\n") }
      archive = root.join("Xcode-27.4-27E1a.#{format}")
      archive.binwrite(contents) if contents
      yield archive, { "PATH" => "#{bin}:#{ENV.fetch('PATH')}" }, root
      refute root.join("file-was-called").exist?, "the archive checks consulted file(1)"
    end
  end

  def test_xcode_archive_format_check_separates_a_mismatch_from_a_failed_read
    { ["xip", XAR_HEADER] => [0, /\Axar archive\n\z/],
      ["xip", AEA_HEADER] => [1, /\Anot a xar archive \(leading bytes 41454131\)\n\z/],
      ["aea", AEA_HEADER] => [0, /\AApple Encrypted Archive\n\z/],
      ["aea", XAR_HEADER] => [1, /\Anot an Apple Encrypted Archive \(leading bytes 78617221\)\n\z/],
      ["aea", "AEA".b] => [1, /leading bytes 414541\)/], ["xip", "".b] => [1, /leading bytes none\)/],
      ["aea", nil] => [3, /\A\z/], ["xip", nil] => [3, /\A\z/], ["dmg", AEA_HEADER] => [2, /\A\z/] }
      .each do |(format, contents), (status, description)|
      in_archive_fixture(format, contents) do |archive, env|
        result = command("/bin/bash", FORMAT_CHECK, format, archive, env: env)
        assert_equal status, result.returncode, "#{format}: #{contents.inspect}"
        assert_match description, result.stdout, "#{format}: #{contents.inspect}"
      end
    end
    assert_equal 2, command("/bin/bash", FORMAT_CHECK, "aea").returncode
    XCODE_ARCHIVE_HEADERS.each do |format, header|
      in_archive_fixture(format, header, stubs: FAILING_READ) do |archive, env, root|
        assert_equal 3, command("/bin/bash", FORMAT_CHECK, format, archive, env: env).returncode, format
        assert_equal 3, command("/bin/bash", FORMAT_CHECK, format, root).returncode, "#{format}: a directory"
        # A pipe is not an archive, even one that delivers the right leading bytes.
        File.mkfifo(root.join("pipe"))
        File.open(root.join("pipe"), "r+") do |writer|
          writer.write(header)
          writer.flush
          assert_equal 3, command("/bin/bash", FORMAT_CHECK, format, root.join("pipe")).returncode, "#{format}: a pipe"
        end
      end
      next if Process.uid.zero?

      in_archive_fixture(format, header) do |archive, env|
        archive.chmod(0)
        assert_equal 3, command("/bin/bash", FORMAT_CHECK, format, archive, env: env).returncode, "#{format}: unreadable"
      end
    end
  end

  def validate_archive(archive, env, format, downloaded)
    bash(workflow_run_block(XCODE_WORKFLOW.read, "Validate archive"), chdir: ROOT,
         env: env.merge("ARCHIVE_FILE" => archive.to_s, "ARCHIVE_FORMAT" => format, "DOWNLOADED" => downloaded.to_s))
  end

  def test_xcode_archive_validation_rejects_the_other_format_and_keeps_cached_files
    large = 2 * MINIMUM_ARCHIVE_BYTES
    { ["aea", AEA_HEADER, large, true] => [true, true], ["xip", XAR_HEADER, large, true] => [true, true],
      ["aea", AEA_HEADER, MINIMUM_ARCHIVE_BYTES, true] => [true, true],
      ["aea", XAR_HEADER, large, true] => [false, false], ["xip", AEA_HEADER, large, true] => [false, false],
      ["aea", XAR_HEADER, large, false] => [false, true],
      ["aea", AEA_HEADER, MINIMUM_ARCHIVE_BYTES - 1, true] => [false, false],
      ["xip", XAR_HEADER, MINIMUM_ARCHIVE_BYTES - 1, false] => [false, true] }
      .each do |(format, contents, size, downloaded), (accepted, kept)|
      in_archive_fixture(format, contents, size: size) do |archive, env|
        result = validate_archive(archive, env, format, downloaded)
        label = "#{format} holding #{contents[0, 4]}, #{size} bytes, downloaded=#{downloaded}"
        assert_equal accepted, result.success?, "#{label}: #{result.stdout}#{result.stderr}"
        assert_equal kept, archive.exist?, label
        assert_includes result.stdout, "not a valid .#{format} archive" unless accepted
      end
    end
  end

  def test_xcode_archive_read_failure_neither_deletes_nor_strands_a_download
    # The second stub loses read permission after the caller's checks, as a file on a failing volume can.
    failures = [FAILING_READ]
    failures << { "head" => "chmod 000 \"${@: -1}\"\nexec /usr/bin/head \"$@\"" } unless Process.uid.zero?
    XCODE_ARCHIVE_HEADERS.to_a.product(failures).each do |(format, header), stubs|
      in_archive_fixture(format, header, size: MINIMUM_ARCHIVE_BYTES, stubs: stubs) do |archive, env|
        result = validate_archive(archive, env, format, true)
        refute result.success?
        assert archive.exist?, "a failed read deleted a fresh #{format} download"
        assert_includes result.stdout, "Could not check the format"
      end
      in_archive_fixture(format, header[0, 10], size: 10, stubs: stubs) do |archive, env|
        refute validate_archive(archive, env, format, true).success?
        refute archive.exist?, "an undersized fresh #{format} download stayed in the cache"
      end
    end
  end

  # Runs the resolve, download and validation steps in order, handing each one
  # the environment and outputs the previous step wrote, as the runner does.
  # `cached` seeds the cache; `fresh` is what the transfer delivers on a miss.
  def run_xcode_archive_steps(format:, cached: nil, fresh: nil, size: MINIMUM_ARCHIVE_BYTES, stubs: {})
    workflow = XCODE_WORKFLOW.read
    in_archive_fixture(format, nil, size: size, stubs: DOWNLOAD_STUBS.merge(stubs)) do |_, env, root|
      # The path the resolver must choose is computed here, so a routing mistake
      # fails the comparison below instead of redirecting the fixture write.
      archive = root.join("macOS-Archive-27+/Xcode/27/Xcode-27.4-27E1a.#{format}")
      archive.dirname.mkpath
      archive.binwrite(cached) if cached
      delivery = root.join("delivery")
      delivery.binwrite(fresh) if fresh
      files = %w[GITHUB_ENV GITHUB_OUTPUT].to_h { |name| [name, root.join(name).tap { |file| file.write("") }.to_s] }
      read = ->(name) { File.read(files.fetch(name)).lines(chomp: true).to_h { |line| line.split("=", 2) } }
      url = "https://developer.apple.com/services-account/download?path=/Developer_Tools/Xcode_27.4/Xcode_27.4.#{format}"
      env = env.merge(files, "BUILD" => "27E1a", "ADC_DOWNLOAD_AUTH" => "fixture", "ARCHIVE_URL" => url,
                             "CURL_DELIVERY" => delivery.to_s)
      resolve = workflow_run_block(workflow, "Resolve archive path").gsub("/Volumes/macOS-Archive-", "#{root}/macOS-Archive-")
      results = { resolve: bash(resolve, chdir: ROOT, env: env) }
      exported = read.call("GITHUB_ENV")
      if results.fetch(:resolve).success?
        assert_equal archive.to_s, exported.fetch("ARCHIVE_FILE")
        results[:download] = bash(workflow_run_block(workflow, "Download archive"), chdir: ROOT, env: env.merge(exported))
      end
      outputs = read.call("GITHUB_OUTPUT")
      if results[:download]&.success?
        results[:validate] = bash(workflow_run_block(workflow, "Validate archive"), chdir: ROOT,
                                  env: env.merge(exported, "DOWNLOADED" => outputs.fetch("downloaded", "")))
      end
      yield results, exported, outputs, archive
    end
  end

  def assert_steps_succeeded(results, label)
    assert_equal %i[resolve download validate], results.keys, label
    results.each { |step, result| assert result.success?, "#{label} #{step}: #{result.stdout}#{result.stderr}" }
  end

  def test_xcode_resolved_format_reaches_the_cache_check_and_validation
    XCODE_ARCHIVE_HEADERS.each do |format, header|
      run_xcode_archive_steps(format: format, cached: header) do |results, exported, outputs, archive|
        assert_steps_succeeded(results, format)
        assert_equal format, exported.fetch("ARCHIVE_FORMAT")
        assert_equal "https://adcdownload.apple.com/Developer_Tools/Xcode_27.4/Xcode_27.4.#{format}", exported.fetch("CDN_URL")
        assert_equal "false", outputs.fetch("downloaded")
        assert_equal header, archive.binread
      end
    end
  end

  def test_xcode_fresh_download_reports_itself_so_validation_can_remove_it
    XCODE_ARCHIVE_HEADERS.each do |format, header|
      run_xcode_archive_steps(format: format, fresh: header) do |results, _, outputs, archive|
        assert_steps_succeeded(results, format)
        assert_equal "true", outputs.fetch("downloaded")
        assert_equal header, archive.binread
        refute Pathname.new("#{archive}.part").exist?
      end
      other = XCODE_ARCHIVE_HEADERS.values.find { |candidate| candidate != header }
      run_xcode_archive_steps(format: format, fresh: other) do |results, _, outputs, archive|
        assert results.fetch(:download).success?, results.fetch(:download).stderr
        assert_equal "true", outputs.fetch("downloaded")
        refute results.fetch(:validate).success?
        refute archive.exist?, "a fresh #{format} download in the wrong format stayed in the cache"
      end
    end
    run_xcode_archive_steps(format: "aea") do |results, _, outputs, archive|
      refute results.fetch(:download).success?
      refute outputs.key?("downloaded")
      refute archive.exist?
    end
  end

  def test_xcode_cached_archive_that_fails_its_check_is_preserved_and_stops_the_run
    XCODE_ARCHIVE_HEADERS.each do |format, header|
      other = XCODE_ARCHIVE_HEADERS.values.find { |candidate| candidate != header }
      run_xcode_archive_steps(format: format, cached: other) do |results, _, outputs, archive|
        download = results.fetch(:download)
        refute download.success?, format
        assert_includes download.stdout, "not a valid .#{format} archive"
        assert_includes download.stdout, "Preserving it for investigation"
        refute outputs.key?("downloaded")
        assert_equal other, archive.binread
      end
      run_xcode_archive_steps(format: format, cached: header, stubs: FAILING_READ) do |results, _, _, archive|
        refute results.fetch(:download).success?, format
        assert_includes results.fetch(:download).stdout, "Could not check the format"
        assert_equal header, archive.binread
      end
    end
    run_xcode_archive_steps(format: "aea", cached: AEA_HEADER, size: MINIMUM_ARCHIVE_BYTES - 1) do |results, _, _, archive|
      assert results.fetch(:download).success?
      refute results.fetch(:validate).success?
      assert_includes results.fetch(:validate).stdout, "Preserving the invalid preexisting cache entry"
      assert archive.exist?
    end
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

  SCANNER_WORKFLOW_JOBS = %w[prepare scan publish wait-for-merge].freeze

  def environment_name(job)
    environment = job["environment"]
    environment.is_a?(Hash) ? environment["name"] : environment
  end

  # A job's whole secret context reaches its runner, so the self-hosted scan
  # job may bind only the environment and secret of the Apple download cookie.
  def test_scanner_jobs_never_declare_a_publishing_environment
    [IPSW_WORKFLOW, XCODE_WORKFLOW, RESCAN_WORKFLOW].each do |path|
      jobs = YAML.safe_load(path.read).fetch("jobs")
      assert_equal SCANNER_WORKFLOW_JOBS, jobs.keys, path.basename.to_s
      jobs.each do |name, job|
        secrets = JSON.generate(job).scan(/secrets\.(\w+)/).flatten.uniq
        if name == "scan"
          assert_equal "scanner", job["runs-on"], "#{path.basename}: the scan job runs on the self-hosted scanner"
          assert_includes [nil, "apple-developer"], environment_name(job), "#{path.basename}: the scan job binds a publishing environment"
          assert_empty secrets - ["ADC_DOWNLOAD_AUTH"], "#{path.basename}: the scan job references publishing secrets"
        else
          refute_equal "scanner", job["runs-on"], "#{path.basename}: hosted job #{name} runs on the scanner"
          refute_equal "apple-developer", environment_name(job), "#{path.basename}: hosted job #{name} does not need the download cookie"
        end
      end
    end
    xcode_scan = YAML.safe_load(XCODE_WORKFLOW.read).dig("jobs", "scan")
    assert_equal({ "name" => "apple-developer", "deployment" => false }, xcode_scan["environment"])
    assert_includes JSON.generate(xcode_scan), "gh secret set ADC_DOWNLOAD_AUTH --env apple-developer"
  end
end
