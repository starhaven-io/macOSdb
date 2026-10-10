# frozen_string_literal: true
require_relative "test_helper"

class CaskMergeProtocolTests < Minitest::Test
  include WorkflowHelpers

  def test_merge_is_bounded_synchronous_and_exact_head_bound
    workflow = RELEASE_WORKFLOW.read
    resolve = workflow_run_block(workflow, "Resolve Homebrew cask bump")
    wait = workflow_run_block(workflow, "Wait for checks on the validated head")
    revalidate = workflow_run_block(workflow, "Revalidate and merge the exact head")
    merge_job = workflow.split("\n  merge-cask-bump:\n", 2).last
    ['if [[ "${MATCH_COUNT}" != 1 ]]', '.user.login == $bot', '.changed_files == 1',
     'echo "base_sha=', 'echo "head_sha='].each { |text| assert_includes resolve, text }
    refute_includes resolve, "gh pr merge"
    ["CHECK_TIMEOUT_SECONDS=1500", "8) CHECK_SUMMARY=pending", "mergeStateStatus", "CHECK_STATUS == 0",
     '[[ "${MERGE_STATE}" == "CLEAN" || "${MERGE_STATE}" == "UNSTABLE" ]]'].each { |text| assert_includes wait, text }
    refute_includes wait, "--watch"
    refute_includes wait, "--fail-fast"
    assert_operator merge_job.index("Wait for checks on the validated head"), :<, merge_job.index("Mint bot token for tap")
    ['.base.sha == $base_sha', '.head.sha == $head', '.[0].filename == $cask',
     '--match-head-commit "${HEAD_SHA}"'].each { |text| assert_includes revalidate, text }
    refute_includes merge_job, "--auto"
  end

  def test_partial_required_check_registration_stays_blocked
    wait = workflow_run_block(RELEASE_WORKFLOW.read, "Wait for checks on the validated head")
           .sub("CHECK_INTERVAL_SECONDS=10", "CHECK_INTERVAL_SECONDS=0")
    stub = <<~'SH'
      gh() {
        if [[ "$1" == api ]]; then printf '%s\n' validated-head; return; fi
        if [[ "$1" == pr && "$2" == checks && "$*" == *--json* ]]; then
          printf '1\n'; return
        fi
        if [[ "$1" == pr && "$2" == checks ]]; then
          index=$(< "${GH_FIXTURE_COUNTER}")
          if [[ "${index}" == 1 ]]; then return 8; fi
          return
        fi
        if [[ "$1" == pr && "$2" == view ]]; then
          index=$(< "${GH_FIXTURE_COUNTER}")
          printf '%s\n' "$((index + 1))" > "${GH_FIXTURE_COUNTER}"
          cat "${GH_FIXTURE_DIR}/${index}.json"
          return
        fi
        return 1
      }
    SH
    Dir.mktmpdir do |directory|
      path = Pathname.new(directory)
      counter = path.join("counter")
      counter.write("0\n")
      %w[BLOCKED BLOCKED CLEAN].each_with_index do |state, index|
        path.join("#{index}.json").write(JSON.generate("headRefOid" => "validated-head", "mergeStateStatus" => state))
      end
      result = bash(stub + wait, timeout: 20, env: { "GH_FIXTURE_COUNTER" => counter.to_s,
                    "GH_FIXTURE_DIR" => directory, "PR_NUMBER" => "159", "HEAD_SHA" => "validated-head" })
      assert result.success?, result.stderr
      assert_equal "3", counter.read.strip
      assert_equal 2, result.stdout.scan("merge state: BLOCKED").size
      assert_includes result.stdout, "merge state: CLEAN"
    end
  end
end

class CaskDCOTests < Minitest::Test
  include WorkflowHelpers

  def setup
    @directory = Dir.mktmpdir
    @root = Pathname.new(@directory).realpath
    @tap, @runner, @bin = ["tap checkout", "runner temp", "bin"].map { |name| @root.join(name) }
    [@tap, @runner, @bin].each(&:mkdir)
    @env = ENV.keys.grep(/\AGIT_/).to_h { |key| [key, nil] }.merge(
      "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_SYSTEM" => File::NULL, "GIT_TERMINAL_PROMPT" => "0",
      "GIT_AUTHOR_NAME" => "Fixture Author", "GIT_AUTHOR_EMAIL" => "author@example.test",
      "PATH" => "#{@bin}:#{ENV.fetch('PATH')}", "RUNNER_TEMP" => @runner.to_s, "TAP_ROOT" => @tap.to_s,
      "APP_SLUG" => "fixture-bot", "VERSION" => "1.2.3"
    )
    git("init", "-q")
    git("config", "user.name", "Fixture Committer")
    git("config", "user.email", "committer@example.test")
    git("config", "core.hooksPath", ".githooks")
    @hooks = @tap.join(".githooks")
    @hooks.mkdir
    executable(@hooks.join("commit-msg"), ROOT.join(".githooks/commit-msg").read)
    executable(@hooks.join("pre-push"), "#!/bin/sh\nexit 1\n")
    executable(@bin.join("gh"), "#!/bin/sh\nif [ \"$1\" = api ]; then printf \"42\\n\"; fi\n")
    executable(@bin.join("brew"), <<~'SH')
      #!/bin/sh
      set -eu
      case "$1" in
        --repo) printf '%s\n' "$TAP_ROOT" ;;
        tap|trust) ;;
        ruby) shift; shift; exec ruby "$@" ;;
        bump-cask-pr)
          if [ "${REPLACE_HOOK:-0}" = 1 ]; then
            rm "$TAP_ROOT/.githooks/prepare-commit-msg"
            ln -s "$TAP_ROOT/keep-this-link" "$TAP_ROOT/.githooks/prepare-commit-msg"
            exit 9
          fi
          [ "${FAIL_BREW:-0}" = 0 ] || exit 9
          printf 'update\n' >> "$TAP_ROOT/cask.rb"
          git -C "$TAP_ROOT" add cask.rb
          message='macosdb 1.2.3'
          if [ "${EXISTING_SIGNOFF:-0}" = 1 ]; then
            message="$(printf '%s\n\nSigned-off-by: Fixture Author <author@example.test>\n' "$message")"
          fi
          git -C "$TAP_ROOT" -c commit.gpgSign=false commit --no-edit --verbose --message="$message" -- cask.rb
          ;;
        *) exit 8 ;;
      esac
    SH
    @script = workflow_run_block(RELEASE_WORKFLOW.read, "Bump Homebrew cask", strip_comments: false)
  end

  def teardown = FileUtils.remove_entry(@directory)

  def git(*args)
    result = command("git", "-C", @tap, *args, env: @env)
    assert result.success?, result.stderr
    result.stdout.strip
  end

  def run_bump = bash(@script, chdir: @root, env: @env, timeout: 20)

  def resolve_hook_path(path, setup: "")
    expression = @script.match(/HOOKS_DIR=\$\(env -u GH_TOKEN brew ruby -- -rpathname -e '([^']+)'/).captures.first
    runner = "#{setup}\nTimeout.timeout(1) { eval(ARGV.shift) }"
    command(RbConfig.ruby, "-rpathname", "-rtimeout", "-e", runner, expression, path, timeout: 5)
  end

  def test_hook_resolver_normalizes_missing_parent_segments
    raw = "#{@tap}/missing/../.githooks"
    result = resolve_hook_path(raw)
    assert result.success?, result.stderr
    assert_equal "#{@hooks}\n", result.stdout
    refute @tap.join("missing").exist?
    assert_empty @runner.children
  end

  def test_hook_resolver_stops_if_no_existing_ancestor_can_be_found
    result = resolve_hook_path(@tap.join("missing/hooks"), setup: <<~'RUBY')
      class Pathname
        def exist? = false
        def symlink? = false
      end
    RUBY
    assert_equal 1, result.returncode
    assert_equal "Cannot resolve the tap hooks directory.\n", result.stderr
    assert_empty result.stdout
    assert_empty @runner.children
  end

  def assert_cleaned
    refute @hooks.join("prepare-commit-msg").symlink?
    assert_empty @runner.children
    assert_equal ".githooks", git("config", "--local", "core.hooksPath")
  end

  def test_actual_author_is_signed_once_and_existing_hooks_are_preserved
    original = @hooks.join("commit-msg").binread
    %w[0 1].each do |duplicate|
      @env["EXISTING_SIGNOFF"] = duplicate
      result = run_bump
      assert result.success?, result.stderr
      message = git("log", "-1", "--format=%B")
      author = git("log", "-1", "--format=%an <%ae>")
      assert_equal "macosdb 1.2.3", message.lines(chomp: true).first
      assert_equal 1, message.scan("Signed-off-by:").size
      assert_includes message, "Signed-off-by: #{author}"
      refute_equal author, git("log", "-1", "--format=%cn <%ce>")
      assert_equal original, @hooks.join("commit-msg").binread
      assert_equal "#!/bin/sh\nexit 1\n", @hooks.join("pre-push").read
      assert_cleaned
    end
  end

  def test_existing_validator_still_blocks_commit
    executable(@hooks.join("commit-msg"), "#!/bin/sh\nexit 1\n")
    refute run_bump.success?
    assert_cleaned
  end

  def test_failure_cleans_hook_for_retry
    @env["FAIL_BREW"] = "1"
    assert_equal 9, run_bump.returncode
    assert_cleaned
    @env["FAIL_BREW"] = "0"
    assert run_bump.success?
    assert_cleaned
  end

  def test_existing_prepare_hook_is_preserved
    prepare = @hooks.join("prepare-commit-msg")
    executable(prepare, "#!/bin/sh\nexit 0\n")
    before = prepare.binread
    result = run_bump
    refute result.success?
    assert_includes result.stdout, "existing prepare-commit-msg"
    assert_equal before, prepare.binread
    assert_empty @runner.children
  end

  def test_external_hook_directory_is_not_modified
    external = @root.join("outside hooks")
    external.mkdir
    link = @tap.join("outside-link")
    link.make_symlink(external)
    [external, link].each do |location|
      git("config", "core.hooksPath", location.to_s)
      result = run_bump
      refute result.success?
      assert_includes result.stdout, "outside the fresh checkout"
      assert_empty external.children
      assert_empty @runner.children
    end
  end

  def test_git_resolves_symlinks_before_parent_segments_and_external_hooks_are_preserved
    outside = @root.join("outside")
    outside.join("target").mkpath
    hooks = outside.join("hooks")
    hooks.mkdir
    sentinel = hooks.join("prepare-commit-msg")
    executable(sentinel, "#!/bin/sh\nexit 7\n")
    before = sentinel.binread
    @tap.join("link").make_symlink(outside.join("target"))
    git("config", "core.hooksPath", "link/../hooks")

    assert_equal hooks.to_s, git("rev-parse", "--path-format=absolute", "--git-path", "hooks")
    result = run_bump
    refute result.success?
    assert_includes result.stdout, "outside the fresh checkout"
    assert_equal before, sentinel.binread
    assert_equal [sentinel], hooks.children
    assert_empty @runner.children
  end

  def test_inherited_global_hook_directory_is_not_modified
    external = @root.join("global hooks")
    external.mkdir
    global_config = @root.join("gitconfig")
    @env["GIT_CONFIG_GLOBAL"] = global_config.to_s
    git("config", "--global", "core.hooksPath", external.to_s)
    git("config", "--local", "--unset", "core.hooksPath")
    before = global_config.binread
    refute run_bump.success?
    assert_equal before, global_config.binread
    assert_empty external.children
    assert_empty @runner.children
  end

  def test_cleanup_preserves_a_substituted_link
    @env["REPLACE_HOOK"] = "1"
    assert_equal 9, run_bump.returncode
    assert_equal @tap.join("keep-this-link"), @hooks.join("prepare-commit-msg").readlink
    assert_empty @runner.children
  end
end
