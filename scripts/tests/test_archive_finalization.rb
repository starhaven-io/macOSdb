# frozen_string_literal: true
require_relative "test_helper"

class ArchiveFinalizationTests < Minitest::Test
  include WorkflowHelpers

  def run_workflow(product:, existing: false, failure: "", cached: true)
    xip = product == "xcode"
    workflow = (xip ? XIP_WORKFLOW : IPSW_WORKFLOW).read.split("\n  publish:\n", 2).first
    shell_match = workflow.match(/^defaults:\n  run:\n    shell: (.+)$/)
    refute_nil shell_match, "The workflow must declare its default shell"
    shell = Shellwords.split(shell_match[1])
    assert_equal "bash", shell.first
    assert_equal 1, shell.count("{0}")
    scan_job = workflow.split("\n  scan:\n", 2).last.split("\n    steps:\n", 2).first
    refute_match(/^    defaults:/, scan_job)
    product_type = xip ? "Xcode" : "macOS"
    extension = xip ? "xip" : "ipsw"
    steps = [xip ? "Verify existing SHA-256 sidecar" : "Download IPSW", xip ? "Scan XIP" : "Scan IPSW",
             "Lint JSON", "Package release JSON", xip ? "Create or verify SHA-256 sidecar" : "Generate SHA-256 sidecar",
             "Lock archive files"]
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      archive = root.join("#{product_type}-27.1-27A9275.#{extension}")
      archive.write("archive fixture") if cached
      sidecar = Pathname.new("#{archive}.sha256")
      sidecar.write("existing checksum") if existing
      events = root.join("events")
      events.write("")
      bin = root.join("bin")
      bin.mkdir
      cli = root.join(".build/release/macosdb")
      cli.dirname.mkpath
      executable(cli, <<~'SH')
        #!/bin/bash
        set -euo pipefail
        case "$1" in
          scan)
            echo scan >> "$EVENTS"
            [[ "$FAILURE" != scan ]] || exit 1
            mkdir -p "data/$PRODUCT/releases/27"
            build=27A9275
            [[ "$FAILURE" != metadata ]] || build=27A9276
            printf '{"osVersion":"27.1","buildNumber":"%s","productType":"%s"}\n' "$build" "$PRODUCT_TYPE" > "$DETAIL"
            if [[ "$PRODUCT" == macos ]]; then echo pem > "$IPSW_FILE.pem"; fi
            ;;
          identity)
            echo identity >> "$EVENTS"
            [[ "$FAILURE" != source ]] || exit 1
            ;;
          validate)
            if [[ -f "$2.sha256" ]]; then
              echo verify >> "$EVENTS"
              [[ "$FAILURE" != checksum ]] || exit 1
            else
              echo hash >> "$EVENTS"
              [[ "$FAILURE" != hash ]] || exit 1
              echo 'new checksum' > "$2.sha256"
            fi
            ;;
          *) exit 2 ;;
        esac
      SH
      stubs = {
        "ruby" => "echo lint >> \"$EVENTS\"\n[[ \"$FAILURE\" != lint ]]",
        "git" => 'if [[ "$FAILURE" == identity ]]; then echo data/xcode/releases/27/wrong.json; else echo "$DETAIL"; fi',
        "stat" => "exit 0", "chflags" => 'echo "lock${2#${ARCHIVE_FILE}}" >> "$EVENTS"',
        "tar" => '[[ "$FAILURE" != package ]]',
        "curl" => 'out=""; while (($#)); do [[ "$1" != -o ]] || out="$2"; shift; done; [[ -z "$out" ]] || echo "archive fixture" > "$out"',
        "sleep" => "exit 0"
      }
      stubs.each { |name, script| executable(bin.join(name), "#!/bin/bash\nset -euo pipefail\n#{script}\n") }
      env = {
        "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "XIP_FILE" => archive.to_s, "IPSW_FILE" => archive.to_s,
        "ARCHIVE_FILE" => archive.to_s, "IPSW_URL" => "https://updates.cdn-apple.com/fixture.ipsw",
        "PRODUCT" => product, "PRODUCT_TYPE" => product_type, "IS_DEVICE_SPECIFIC" => "false",
        "RELEASE_DATE" => "2026-10-05", "PUBLIC_URL" => "https://developer.apple.com/services-account/download?path=/Xcode_27.1.xip",
        "EXPECTED_VERSION" => "27.1", "EXPECTED_BUILD" => "27A9275", "IS_BETA" => "false", "BETA_NUMBER" => "",
        "BETA_REVISION" => "", "IS_RC" => "false", "RC_NUMBER" => "", "GITHUB_OUTPUT" => root.join("output").to_s,
        "RUNNER_TEMP" => directory, "EVENTS" => events.to_s, "FAILURE" => failure,
        "DETAIL" => "data/#{product}/releases/27/#{product_type}-27.1-27A9275.json"
      }
      executed = []
      result = nil
      workflow.scan(/^      - name: (.+)$/).flatten.each do |name|
        next unless steps.include?(name)

        executed << name
        step = workflow.split("      - name: #{name}\n", 2).last.split("\n      - ", 2).first
        refute_match(/^        (if|continue-on-error|shell):/, step, "#{name} must retain failure propagation and shell")
        script = step.include?("        run: |\n") ? workflow_run_block(workflow, name) : step.match(/^        run: (.+)$/)[1]
        script = script.gsub("/usr/bin/tar ", "tar ")
        script_path = root.join("step.sh")
        script_path.write(script)
        result = command(*shell.map { |argument| argument == "{0}" ? script_path.to_s : argument }, chdir: root, env: env)
        break unless result.success?
      end
      assert_equal steps.sort, executed.sort if failure.empty?
      @archive_exists = archive.exist?
      @partial_exists = Pathname.new("#{archive}.part").exist?
      [result, events.read.lines(chomp: true), sidecar.exist? ? sidecar.read : nil]
    end
  end

  def source_check(product) = product == "macos" ? ["identity"] : []
  def expected_locks(product) = product == "macos" ? ["lock", "lock.pem", "lock.sha256"] : ["lock", "lock.sha256"]

  def test_new_archive_is_hashed_and_locked_only_after_scan_and_validation
    %w[macos xcode].each do |product|
      result, events, checksum = run_workflow(product: product)
      assert result.success?, result.stderr
      assert_equal [*source_check(product), "scan", "lint", "hash", *expected_locks(product)], events
      assert_equal "new checksum\n", checksum
    end
  end

  def test_failed_scan_or_output_validation_never_creates_a_checksum_or_locks
    %w[macos xcode].product(%w[scan lint identity metadata package]).each do |product, failure|
      result, events, checksum = run_workflow(product: product, failure: failure)
      refute result.success?
      expected = failure == "scan" ? ["scan"] : ["scan", "lint"]
      assert_equal [*source_check(product), *expected], events, "#{product}: #{failure}"
      assert_nil checksum
    end
  end

  def test_existing_checksum_mismatch_stops_before_scan_and_preserves_sidecar
    %w[macos xcode].each do |product|
      result, events, checksum = run_workflow(product: product, existing: true, failure: "checksum")
      refute result.success?
      assert_equal ["verify"], events
      assert_equal "existing checksum", checksum
    end
  end

  def test_valid_cached_archive_is_verified_before_scanning
    %w[macos xcode].each do |product|
      result, events, checksum = run_workflow(product: product, existing: true)
      assert result.success?, result.stderr
      assert_equal ["verify", "scan", "lint", "verify", *expected_locks(product)], events
      assert_equal "existing checksum", checksum
    end
  end

  def test_hash_failure_does_not_lock_archive
    %w[macos xcode].each do |product|
      result, events, checksum = run_workflow(product: product, failure: "hash")
      refute result.success?
      assert_equal [*source_check(product), "scan", "lint", "hash"], events
      assert_nil checksum
    end
  end

  def test_unchecksummed_cached_ipsw_with_another_identity_is_preserved_before_scan
    result, events, checksum = run_workflow(product: "macos", failure: "source")
    refute result.success?
    assert_equal ["identity"], events
    assert_nil checksum
    assert @archive_exists
    assert_includes result.stdout, "Preserving it for investigation"
  end

  def test_fresh_ipsw_download_is_promoted_only_after_its_identity_matches
    result, events, checksum = run_workflow(product: "macos", cached: false)
    assert result.success?, result.stderr
    assert_equal ["identity", "scan", "lint", "hash", *expected_locks("macos")], events
    assert_equal "new checksum\n", checksum
    assert @archive_exists
    refute @partial_exists
  end

  def test_fresh_ipsw_download_with_another_identity_is_removed
    result, events, checksum = run_workflow(product: "macos", cached: false, failure: "source")
    refute result.success?
    assert_equal ["identity"], events
    assert_nil checksum
    refute @archive_exists
    refute @partial_exists
  end
end
