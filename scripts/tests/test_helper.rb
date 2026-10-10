# frozen_string_literal: true

Encoding.default_external = Encoding::UTF_8

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "timeout"

module WorkflowHelpers
  ROOT = Pathname.new(__dir__).join("../..").realpath
  CI_WORKFLOW = ROOT.join(".github/workflows/ci.yml")
  IPSW_WORKFLOW = ROOT.join(".github/workflows/scan-ipsw.yml")
  XIP_WORKFLOW = ROOT.join(".github/workflows/scan-xip.yml")
  RESCAN_WORKFLOW = ROOT.join(".github/workflows/rescan.yml")
  RELEASE_WORKFLOW = ROOT.join(".github/workflows/release.yml")
  Result = Struct.new(:stdout, :stderr, :status) do
    def success? = status.success?
    def returncode = status.exitstatus
  end

  def command(*argv, env: {}, chdir: nil, timeout: 30)
    options = chdir ? { chdir: chdir.to_s } : {}
    Timeout.timeout(timeout) { Result.new(*Open3.capture3(env, *argv.map(&:to_s), **options)) }
  end

  def c_locale_ruby(script, *argv, env: {}, **options)
    launcher = <<~'RUBY'
      abort "locale fixture did not start in US-ASCII" unless Encoding.default_external == Encoding::US_ASCII
      abort "locale fixture loaded the test helper" if $LOADED_FEATURES.any? { |path| path.end_with?("/test_helper.rb") }
      $PROGRAM_NAME = ARGV.shift
      load $PROGRAM_NAME
    RUBY
    locale = { "LANG" => nil, "LC_ALL" => "C", "LC_CTYPE" => nil, "LANGUAGE" => nil }
    command(RbConfig.ruby, "-e", launcher, script, *argv, env: env.merge(locale), **options)
  end

  def bash(script, **options)
    command("/bin/bash", "-euo", "pipefail", "-c", script, **options)
  end

  def executable(path, contents)
    path.write(contents)
    path.chmod(0o755)
  end

  def workflow_run_block(workflow, step_name, strip_comments: true)
    marker = "      - name: #{step_name}\n"
    start = workflow.index(marker) or raise "Missing workflow step #{step_name}"
    step = workflow[(start + marker.length)..].split(/^      - /, 2).first
    run = step.split("        run: |\n", 2).fetch(1)
    run.lines(chomp: true).take_while { |line| line.strip.empty? || line.start_with?("          ") }
       .reject { |line| strip_comments && line.lstrip.start_with?("#") }
       .map { |line| line.delete_prefix("          ") }.join("\n")
  end
end
