# frozen_string_literal: true
require_relative "test_helper"
require_relative "../check-catalog-publication"

class CatalogPublicationTests < Minitest::Test
  include WorkflowHelpers
  REPOSITORY = "starhaven-io/macOSdb"
  SCRIPT = ROOT.join("scripts/check-catalog-publication.rb")
  WORKFLOWS = %w[scan-ipsw.yml scan-xip.yml rescan.yml].freeze

  def publication(branch = "feat/data-macOS-27.0", number = 123)
    { "number" => number, "state" => "open", "base" => { "ref" => "main" },
      "user" => { "login" => "starhaven-bot[bot]" },
      "head" => { "ref" => branch, "repo" => { "full_name" => REPOSITORY } } }
  end

  def setup
    @directory = Dir.mktmpdir
    @root = Pathname.new(@directory)
    @bin = @root.join("bin")
    @bin.mkdir
    executable(@bin.join("gh"), <<~'RB')
      #!/usr/bin/env ruby
      require "json"
      require "rbconfig"
      File.write(ENV.fetch("GH_ARGS"), JSON.generate(ARGV))
      if ENV["GH_HANG"]
        Process.spawn(RbConfig.ruby, "-e", "sleep 60")
        exit 0
      end
      if ENV["MERGE_SOURCE"]
        source = ENV.fetch("MERGE_SOURCE")
        File.write(File.join(source, "index"), "previous catalog PR merged")
        abort "commit failed" unless system("git", "-C", source, "commit", "-qam", "Merge previous catalog")
      end
      puts ENV.fetch("GH_RESPONSE")
      exit ENV.fetch("GH_EXIT", "0").to_i
    RB
    @env = { "PATH" => "#{@bin}:#{ENV.fetch('PATH')}", "GH_ARGS" => @root.join("args").to_s,
             "GH_RESPONSE" => "[[]]", "GITHUB_REPOSITORY" => REPOSITORY }
  end

  def teardown = FileUtils.remove_entry(@directory)

  def run_guard(pages, env = {})
    command(RbConfig.ruby, SCRIPT, "--repository", REPOSITORY,
            env: @env.merge("GH_RESPONSE" => JSON.generate(pages)).merge(env))
  end

  def test_each_catalog_branch_blocks_even_on_a_later_page
    %w[feat/data-macOS-27.0 feat/data-Xcode-27 fix/data-rescan-macos-27].each do |branch|
      result = run_guard([[], [publication(branch)]])
      assert_equal 1, result.returncode
      assert_includes result.stderr, "#123"
      assert_includes result.stderr, "fresh scanner dispatch"
    end
    assert_equal ["api", "--paginate", "--slurp", "repos/#{REPOSITORY}/pulls?state=open&base=main&per_page=100"],
                 JSON.parse(@root.join("args").read)
  end

  def test_empty_inventory_and_unrelated_prs_do_not_block
    assert run_guard([[]]).success?
    cases = []
    { "state" => "closed", "number" => 124 }.each do |field, value|
      pr = publication
      pr[field] = value
      pr["head"]["ref"] = "fleet-sync-v2026.10.6" if field == "number"
      cases << pr
    end
    [[%w[base ref], "topic"], [%w[user login], "contributor"],
     [%w[head repo full_name], "contributor/macOSdb"]].each do |path, value|
      pr = publication
      pr.dig(*path[0...-1])[path.last] = value
      cases << pr
    end
    result = run_guard([cases])
    assert result.success?, result.stderr
  end

  def test_unknown_inventory_fails_closed
    malformed = [nil, [], {}, [nil], [[{}]], [[nil]]]
    [%w[head repo], %w[head ref], %w[user], %w[number]].each do |path|
      pr = publication
      target = path.size == 1 ? pr : pr.dig(*path[0...-1])
      target[path.last] = nil
      malformed << [[pr]]
    end
    malformed.each do |pages|
      result = run_guard(pages)
      assert_equal 1, result.returncode, pages.inspect
      assert_includes result.stderr, "Could not verify"
    end
    [{ "GH_EXIT" => "1" }, { "GH_RESPONSE" => "truncated JSON" },
     { "GH_RESPONSE" => "[/* hidden publication */[]]" },
     { "GH_RESPONSE" => "[// hidden publication\n[]]" }].each do |env|
      result = run_guard([[]], env)
      assert_equal 1, result.returncode
      assert_includes result.stderr, "Could not verify"
    end
  end

  def test_timeout_terminates_descendants_holding_output_open
    script = <<~'RB'
      require ARGV.fetch(0)
      begin
        CatalogPublication.inventory(ARGV.fetch(1), timeout: 0.25)
        exit 2
      rescue Timeout::Error
        exit 0
      end
    RB
    result = command(RbConfig.ruby, "-e", script, SCRIPT, REPOSITORY,
                     env: @env.merge("GH_HANG" => "1"), timeout: 5)
    assert result.success?, result.stderr
  end

  def test_unicode_metadata_is_independent_of_the_process_locale
    result = c_locale_ruby(SCRIPT, "--repository", REPOSITORY,
                           env: @env.merge("GH_RESPONSE" => JSON.generate([[publication("feat/data-é")]])))
    assert_equal 1, result.returncode
    assert_includes result.stderr, "#123"
    refute_includes result.stderr, "Could not verify"
  end

  def git(path, *args)
    result = command("git", "-C", path, *args)
    assert result.success?, result.stderr
    result.stdout.strip
  end

  def test_workflows_stop_before_scanning_and_refresh_a_pr_merged_during_the_query
    WORKFLOWS.each do |name|
      source = @root.join(name)
      source.mkdir
      git(source, "init", "-b", "main")
      git(source, "config", "user.name", "Fixture")
      git(source, "config", "user.email", "fixture@example.invalid")
      git(source, "config", "commit.gpgsign", "false")
      git(source, "config", "core.hooksPath", "/dev/null")
      source.join("index").write("old catalog")
      git(source, "add", "index")
      git(source, "commit", "-m", "Base")
      checkout = @root.join("checkout-#{name}")
      git(@root, "clone", source.to_s, checkout.to_s)
      checkout.join("scripts").mkdir
      FileUtils.copy_file(SCRIPT, checkout.join(SCRIPT.relative_path_from(ROOT)))
      FileUtils.copy_file(ROOT.join("scripts/strict-json.rb"), checkout.join("scripts/strict-json.rb"))
      old_head = git(checkout, "rev-parse", "HEAD")
      workflow = ROOT.join(".github/workflows", name).read
      prepare = workflow.split("\n  scan:\n", 2).first
      assert_includes prepare, "      pull-requests: read #"
      assert_includes prepare, "          GH_TOKEN: ${{ github.token }}\n"
      assert_includes workflow.split("\n  scan:\n", 2).last, "    needs: prepare\n"
      step = "Require previous catalog publication to finish"
      assert_operator prepare.index(step), :<, prepare.index('echo "base_sha=')
      script = workflow_run_block(prepare, step)
      blocked = bash(script, chdir: checkout, env: @env.merge("GH_RESPONSE" => JSON.generate([[publication]])))
      refute blocked.success?, blocked.stderr
      assert_equal old_head, git(checkout, "rev-parse", "HEAD")
      merged = bash(script, chdir: checkout, env: @env.merge("MERGE_SOURCE" => source.to_s))
      assert merged.success?, merged.stderr
      refute_equal old_head, git(checkout, "rev-parse", "HEAD")
      assert_equal git(source, "rev-parse", "HEAD"), git(checkout, "rev-parse", "HEAD")
      assert_equal "previous catalog PR merged", checkout.join("index").read
    end
  end
end
