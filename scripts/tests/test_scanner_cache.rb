# frozen_string_literal: true
require_relative "test_helper"

class ScannerCacheTests < Minitest::Test
  include WorkflowHelpers

  def test_distinct_scans_and_releases_are_retained
    { IPSW_WORKFLOW => "scan", XIP_WORKFLOW => "scan", RESCAN_WORKFLOW => "scan", RELEASE_WORKFLOW => "release" }.each do |path, group|
      concurrency = path.read.split("concurrency:\n", 2).last.split("\n\n", 2).first
      assert_equal({ "group" => group, "cancel-in-progress" => "false", "queue" => "max" },
                   concurrency.lines.map { |line| line.strip.split(": ", 2) }.to_h)
    end
  end

  def identity(script, overrides = {})
    Dir.mktmpdir do |directory|
      output = Pathname.new(directory).join("output")
      shims = <<~'SH'
        swift() { test "${FAIL_SWIFT}" = false || return 1; printf '%s\n' "${SWIFT_VERSION_FIXTURE}"; }
        xcrun() {
          test "${FAIL_SDK}" = false || return 1
          case "$3" in
            --show-sdk-build-version) printf '%s\n' "${SDK_BUILD_FIXTURE}" ;;
            --show-sdk-path) printf '%s\n' "${SDK_PATH_FIXTURE}" ;;
            *) return 2 ;;
          esac
        }
      SH
      result = bash(shims + script, env: {
        "GITHUB_OUTPUT" => output.to_s, "SWIFT_VERSION_FIXTURE" => "Swift fixture 1\nTarget: arm64-apple-macos",
        "SDK_BUILD_FIXTURE" => "fixture-build-1", "SDK_PATH_FIXTURE" => "/Applications/Xcode Fixture.app/SDK",
        "FAIL_SWIFT" => "false", "FAIL_SDK" => "false"
      }.merge(overrides))
      [result, output.exist? ? output.read : ""]
    end
  end

  def test_scanner_keys_share_compiler_sdk_platform_and_source_identity
    scripts = []
    keys = []
    [IPSW_WORKFLOW, XIP_WORKFLOW, RESCAN_WORKFLOW].each do |path|
      workflow = path.read
      scripts << workflow_run_block(workflow, "Identify Swift build environment")
      workflow_keys = workflow.lines.map(&:strip).grep(/key: macosdb-cli-/)
      assert_equal 2, workflow_keys.size
      assert_equal workflow_keys.first, workflow_keys.last
      keys.concat(workflow_keys)
    end
    assert_equal 1, scripts.uniq.size
    assert_equal 1, keys.uniq.size
    ["runner.os", "runner.arch", "steps.swift-build-environment.outputs.digest",
     "hashFiles('Sources/**/*.swift', 'Package.swift', 'Package.resolved')"].each { |value| assert_includes keys.first, value }
  end

  def test_compiler_and_sdk_changes_invalidate_the_identity
    script = workflow_run_block(IPSW_WORKFLOW.read, "Identify Swift build environment")
    result, baseline = identity(script)
    assert result.success?, result.stderr
    assert_match(/\Adigest=[0-9a-f]{64}\n\z/, baseline)
    assert_equal baseline, identity(script).last
    { "SWIFT_VERSION_FIXTURE" => "Swift fixture 2\nTarget: arm64-apple-macos", "SDK_BUILD_FIXTURE" => "fixture-build-2",
      "SDK_PATH_FIXTURE" => "/Applications/Other Xcode.app/SDK" }.each do |name, value|
      result, changed = identity(script, name => value)
      assert result.success?, result.stderr
      refute_equal baseline, changed
    end
  end

  def test_missing_compiler_or_sdk_cannot_create_a_cache_identity
    script = workflow_run_block(IPSW_WORKFLOW.read, "Identify Swift build environment")
    %w[FAIL_SWIFT FAIL_SDK].each do |name|
      result, output = identity(script, name => "true")
      refute result.success?
      assert_empty output
    end
  end
end
