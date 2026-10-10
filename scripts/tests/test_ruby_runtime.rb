# frozen_string_literal: true

require_relative "test_helper"
require_relative "../check-ruby"
require "yaml"

class RubyRuntimeTests < Minitest::Test
  include WorkflowHelpers

  def test_scanner_accepts_current_or_newer_patch_in_the_required_series
    %w[4.0.7 4.0.8 4.0.10].each { |version| assert RubyRuntime.compatible?(version, "4.0.7"), version }
    %w[3.4.9 4.0.6 4.1.0 4.0.8.preview1].each { |version| refute RubyRuntime.compatible?(version, "4.0.7"), version }
    refute RubyRuntime.compatible?("4.0.7", "4.0.8")
  end

  def test_current_runtime_has_required_validation_capabilities
    result = c_locale_ruby(ROOT.join("scripts/check-ruby.rb"))
    assert result.success?, result.stderr
  end

  def with_runtime_fixture(required: ROOT.join(".ruby-version").read)
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      root.join("scripts").mkdir
      root.join(".ruby-version").write(required)
      %w[check-ruby.rb strict-json.rb].each do |name|
        FileUtils.copy_file(ROOT.join("scripts", name), root.join("scripts", name))
      end
      yield root, root.join("scripts/check-ruby.rb")
    end
  end

  def test_cli_rejects_a_scanner_behind_the_required_patch
    with_runtime_fixture(required: "#{RUBY_VERSION.split('.').take(2).join('.')}.999999") do |_, script|
      result = c_locale_ruby(script)
      assert_equal 1, result.returncode
      assert_includes result.stderr, "or a newer patch in its major.minor series is required"
      assert_includes result.stderr, "docs/operations.md"
      assert_equal 1, result.stderr.lines.length
      assert_empty result.stdout
    end
  end

  def test_cli_rejects_an_unavailable_fiddle_library
    with_runtime_fixture do |root, script|
      root.join("missing-fiddle.rb").write(<<~'RUBY')
        module Kernel
          alias_method :original_require, :require
          def require(name)
            raise LoadError, "fiddle unavailable for runtime fixture" if name == "fiddle/import"

            original_require(name)
          end
        end
      RUBY
      result = command(RbConfig.ruby, "-r", root.join("missing-fiddle.rb"), script)
      assert_equal 1, result.returncode
      assert_equal "::error::Ruby runtime validation failed: fiddle unavailable for runtime fixture\n", result.stderr
      assert_empty result.stdout
    end
  end

  def test_cli_rejects_json_without_duplicate_key_rejection
    with_runtime_fixture do |root, script|
      json = root.join("scripts/strict-json.rb")
      original = json.read
      replacement = original.sub("DUPLICATE_KEYS_REJECTED = duplicate_keys_rejected?", "DUPLICATE_KEYS_REJECTED = false")
      refute_equal original, replacement
      json.write(replacement)
      result = c_locale_ruby(script)
      assert_equal 1, result.returncode
      assert_equal "::error::Ruby runtime validation failed: the JSON parser must support rejection of duplicate object keys; update Ruby\n", result.stderr
      assert_empty result.stdout
    end
  end

  def test_cli_reports_an_unreadable_version_pin_without_a_backtrace
    with_runtime_fixture do |root, script|
      root.join(".ruby-version").unlink
      result = c_locale_ruby(script)
      assert_equal 1, result.returncode
      assert_match(/\A::error::Ruby runtime validation failed: No such file or directory/, result.stderr)
      assert_equal 1, result.stderr.lines.length
      assert_empty result.stdout
    end
  end

  def test_scanner_checks_ruby_before_archive_work
    [IPSW_WORKFLOW, XIP_WORKFLOW, RESCAN_WORKFLOW].each do |path|
      scan = path.read.split("\n  scan:\n", 2).last.split("\n  publish:\n", 2).first
      assert_includes scan, "run: ruby scripts/check-ruby.rb"
      assert_operator scan.index("Verify scanner Ruby"), :<, scan.index("Identify Swift build environment")
    end
  end

  def test_privileged_ruby_setup_does_not_install_bundler_or_receive_tokens
    %w[release rescan scan-ipsw scan-xip deploy-site].each do |name|
      workflow = ROOT.join(".github/workflows/#{name}.yml").read
      document = YAML.safe_load(workflow)
      refute document.fetch("env", {}).key?("GH_TOKEN")
      document.fetch("jobs").each_value do |job|
        next unless job.fetch("steps", []).any? { |step| step.fetch("uses", "").start_with?("ruby/setup-ruby@") }

        refute job.fetch("env", {}).key?("GH_TOKEN")
      end
      workflow.split(/^      - /).grep(/\Aname: Set up Ruby/).each do |step|
        assert_includes step, "bundler: none"
        refute_includes step, "GH_TOKEN"
        refute_includes step, "secrets."
        refute_includes step, "bundler-cache:"
      end
    end
    workflow = RELEASE_WORKFLOW.read
    format = workflow.split("      - name: Format release notes\n", 2).last.split("\n      - ", 2).first
    publish = workflow.split("      - name: Publish formatted release notes\n", 2).last.split("\n  bump-cask:\n", 2).first
    refute_includes format, "GH_TOKEN"
    refute_includes format, "secrets."
    assert_includes format, "ruby scripts/format-release-notes.rb"
    assert_includes publish, "GH_TOKEN: ${{ steps.release-token.outputs.token }}"
    assert_includes publish, "gh release edit"
    refute_includes publish, "ruby scripts/format-release-notes.rb"
    bump = workflow_run_block(workflow, "Bump Homebrew cask")
    assert_includes bump, "env -u GH_TOKEN brew ruby -- -rpathname"
    assert_includes bump, "env -u GH_TOKEN brew ruby -- -e"
  end
end
