# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../publish-rescan'

class PublishRescanTests < Minitest::Test
  include WorkflowHelpers
  REPOSITORY = 'starhaven-io/macOSdb'
  BRANCH = 'fix/data-rescan-macOS-12.3-21E230-123'
  BASE = 'a' * 40
  HEAD = 'b' * 40
  TREE = 'c' * 40
  ADDITIONS = [{ 'path' => 'data/macos/releases.json', 'contents' => 'W10=' }].freeze

  class GitHub
    attr_accessor :head, :pr, :commit, :interrupt_after, :query_error
    attr_reader :writes

    def initialize
      @commit = { 'parents' => [{ 'sha' => BASE }], 'tree' => { 'sha' => TREE }, 'verification' => { 'verified' => true } }
      @writes = []
    end

    def copy(value) = Marshal.load(Marshal.dump(value))

    def call(_operation, endpoint, payload = nil)
      raise @query_error if @query_error

      prefix = "repos/#{REPOSITORY}"
      return @pr ? [copy(@pr)] : [] if endpoint.start_with?("#{prefix}/pulls?")
      if endpoint.start_with?("#{prefix}/git/matching-refs/heads/")
        return @head ? [{ 'ref' => "refs/heads/#{BRANCH}", 'object' => { 'type' => 'commit', 'sha' => @head } }] : []
      end
      return copy(@commit) if endpoint == "#{prefix}/git/commits/#{HEAD}"

      case endpoint
      when "#{prefix}/git/refs"
        raise 'incorrect branch creation' unless payload == { 'ref' => "refs/heads/#{BRANCH}", 'sha' => BASE } && @head.nil?

        @head = BASE
        result = {}
      when 'graphql'
        request = payload.fetch('variables').fetch('input')
        unless request.fetch('expectedHeadOid') == @head && @head == BASE && request.fetch('fileChanges') == { 'additions' => ADDITIONS }
          raise 'incorrect commit creation'
        end
        @head = HEAD
        result = { 'data' => { 'createCommitOnBranch' => { 'commit' => { 'oid' => HEAD } } } }
      when "#{prefix}/pulls"
        raise 'incorrect PR creation' unless @pr.nil? && payload['head'] == BRANCH && payload['base'] == 'main'

        @pr = {
          'number' => 42, 'state' => 'open', 'merged_at' => nil,
          'html_url' => "https://github.com/#{REPOSITORY}/pull/42",
          'head' => { 'sha' => HEAD, 'ref' => BRANCH, 'repo' => { 'full_name' => REPOSITORY } },
          'base' => { 'ref' => 'main', 'repo' => { 'full_name' => REPOSITORY } }
        }
        result = copy(@pr)
      else
        raise "unexpected API request: #{endpoint}"
      end
      @writes << endpoint
      raise IOError, 'interrupted after remote mutation' if @writes.length == @interrupt_after

      result
    end
  end

  def with_method(name, replacement)
    original = PublishRescan.method(name)
    PublishRescan.define_singleton_method(name) { |*args| replacement.call(*args) }
    yield
  ensure
    PublishRescan.define_singleton_method(name, original)
  end

  def publish(github)
    with_method(:api, github.method(:call)) do
      PublishRescan.publish(REPOSITORY, BRANCH, BASE, TREE, 'rescan', 'signed off', 'body', ADDITIONS)
    end
  end

  def test_new_publication_creates_one_signed_commit_and_pr
    github = GitHub.new
    assert_equal(42, publish(github).fetch('number'))
    assert_equal(HEAD, github.head)
    assert_equal(3, github.writes.length)
  end

  def test_retry_recovers_after_each_remote_mutation_without_duplicates
    [1, 2, 3].each do |step|
      github = GitHub.new
      github.interrupt_after = step
      assert_match(/interrupted/, assert_raises(IOError) { publish(github) }.message)
      github.interrupt_after = nil
      assert_equal(42, publish(github).fetch('number'))
      assert_equal(3, github.writes.length)
    end
  end

  def test_retry_after_merge_does_not_recreate_deleted_branch
    github = GitHub.new
    publish(github)
    github.pr.merge!('state' => 'closed', 'merged_at' => '2026-09-25T01:00:00Z')
    github.head = nil
    assert_equal(42, publish(github).fetch('number'))
    assert_equal(3, github.writes.length)
    assert_nil(github.head)
  end

  def test_unexpected_or_unsigned_commit_stops_before_pr_creation
    [
      { 'tree' => { 'sha' => 'd' * 40 } }, { 'parents' => [{ 'sha' => 'd' * 40 }] },
      { 'parents' => [{ 'sha' => BASE }, { 'sha' => 'd' * 40 }] }, { 'verification' => { 'verified' => false } }
    ].each do |mutation|
      github = GitHub.new
      github.head = HEAD
      github.commit.merge!(mutation)
      assert_match(/recorded base and verified tree/, assert_raises(PublishRescan::PublicationError) { publish(github) }.message)
      assert_empty(github.writes)
    end
  end

  def test_closed_unmerged_pr_requires_new_dispatch
    github = GitHub.new
    publish(github)
    github.pr['state'] = 'closed'
    assert_match(/closed without merging/, assert_raises(PublishRescan::PublicationError) { publish(github) }.message)
    assert_equal(3, github.writes.length)
  end

  def test_pull_request_identity_and_head_are_bound
    %w[repository branch base head].each do |change|
      github = GitHub.new
      publish(github)
      case change
      when 'repository' then github.pr['head']['repo']['full_name'] = 'other/macOSdb'
      when 'branch' then github.pr['head']['ref'] = 'other'
      when 'base' then github.pr['base']['ref'] = 'other'
      when 'head' then github.head = BASE
      end
      assert_raises(PublishRescan::PublicationError) do
        if change == 'head'
          github.pr['head']['sha'] = 'd' * 40
          with_method(:verify_commit, ->(*) {}) { publish(github) }
        else
          publish(github)
        end
      end
      assert_equal(3, github.writes.length)
    end
  end

  def test_failed_github_read_never_creates_or_overwrites_state
    github = GitHub.new
    github.query_error = IOError.new('GitHub unavailable')
    assert_match(/unavailable/, assert_raises(IOError) { publish(github) }.message)
    assert_empty(github.writes)
  end

  def test_github_responses_must_be_valid_utf8
    original = Open3.method(:capture3)
    status = Struct.new(:success?).new(true)
    Open3.define_singleton_method(:capture3) { |*_, **_| ["{\"field\": \"\xff\"}".b, '', status] }
    error = assert_raises(PublishRescan::PublicationError) { PublishRescan.api('read fixture', 'fixture') }
    assert_match(/not valid UTF-8/, error.message)
  ensure
    Open3.define_singleton_method(:capture3, original)
  end

  def test_cli_publishes_unicode_metadata_under_the_c_locale
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      additions = root.join('ajouts-é.json')
      output = root.join('résultat.txt')
      additions_payload = [{ 'path' => 'data/macos/releases/café.json', 'contents' => 'W10=' }]
      additions.write(JSON.generate(additions_payload), encoding: 'utf-8')
      fixture = {
        'repository' => REPOSITORY, 'branch' => BRANCH, 'base' => BASE, 'head' => HEAD, 'tree' => TREE,
        'title' => 'Résumé café', 'commit_body' => 'Signé café', 'pr_body' => 'Corps café',
        'additions' => additions_payload
      }
      fixture_path = root.join('fixture.json')
      fixture_path.write(JSON.generate(fixture), encoding: 'utf-8')
      executable(root.join('gh'), "#!#{RbConfig.ruby}\n" + <<~'STUB')
        require 'json'
        fixture = JSON.parse(File.read(ENV.fetch('PUBLICATION_FIXTURE'), encoding: 'utf-8'))
        abort 'unexpected gh command' unless ARGV.first == 'api'
        endpoint = ARGV.fetch(1)
        prefix = "repos/#{fixture.fetch('repository')}"
        case endpoint
        when "#{prefix}/git/refs"
          result = {}
        when 'graphql'
          request = JSON.parse($stdin.read.force_encoding(Encoding::UTF_8)).fetch('variables').fetch('input')
          abort 'Unicode file additions changed' unless request.fetch('fileChanges').fetch('additions') == fixture.fetch('additions')
          abort 'Unicode commit title changed' unless request.fetch('message').fetch('headline') == fixture.fetch('title')
          abort 'Unicode commit body changed' unless request.fetch('message').fetch('body') == fixture.fetch('commit_body')
          result = { 'data' => { 'createCommitOnBranch' => { 'commit' => { 'oid' => fixture.fetch('head') } } } }
        when "#{prefix}/git/commits/#{fixture.fetch('head')}"
          result = { 'parents' => [{ 'sha' => fixture.fetch('base') }], 'tree' => { 'sha' => fixture.fetch('tree') },
                     'verification' => { 'verified' => true } }
        when "#{prefix}/pulls"
          request = JSON.parse($stdin.read.force_encoding(Encoding::UTF_8))
          abort 'Unicode PR title changed' unless request.fetch('title') == fixture.fetch('title')
          abort 'Unicode PR body changed' unless request.fetch('body') == fixture.fetch('pr_body')
          result = { 'number' => 42, 'head' => { 'sha' => fixture.fetch('head') },
                     'merged_at' => '2026-10-01T00:00:00Z', 'html_url' => 'https://example.test/pull/42' }
        else
          abort "unexpected API endpoint: #{endpoint}" unless endpoint.start_with?("#{prefix}/pulls?", "#{prefix}/git/matching-refs/")
          result = []
        end
        $stdout.write(JSON.generate(result))
      STUB
      run_cli = lambda do
        c_locale_ruby(
          File.expand_path('../publish-rescan.rb', __dir__), '--repository', REPOSITORY, '--branch', BRANCH,
          '--base', BASE, '--tree', TREE, '--title', fixture.fetch('title'), '--commit-body', fixture.fetch('commit_body'),
          '--pr-body', fixture.fetch('pr_body'), '--additions', additions, '--github-output', output,
          env: { 'PATH' => directory, 'PUBLICATION_FIXTURE' => fixture_path.to_s }
        )
      end
      result = defined?(Bundler) ? Bundler.with_unbundled_env(&run_cli) : run_cli.call
      assert(result.success?, "#{result.stdout}\n#{result.stderr}")
      assert_empty(result.stderr)
      assert_equal("pr_number=42\n", output.read(encoding: 'utf-8'))
      assert_includes(result.stdout, 'Rescan publication: https://example.test/pull/42')
    end
  end

  def publisher_cli_fixture(mode, extra_args: [], fresh: false, fail_call: 1)
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      additions = root.join('additions.json')
      output = root.join('output.txt')
      calls = root.join('calls.jsonl')
      additions.write(JSON.generate(ADDITIONS), encoding: 'utf-8')
      fixture = {
        'repository' => REPOSITORY, 'branch' => BRANCH, 'base' => BASE, 'head' => HEAD, 'tree' => TREE,
        'fresh' => fresh, 'fail_call' => fail_call,
        'payload' => "gh: Not Found\n::warning::forged provider message\n##[error]forged legacy message\r\e[31m" + 'x' * 4096
      }
      fixture_path = root.join('fixture.json')
      fixture_path.write(JSON.generate(fixture), encoding: 'utf-8')
      executable(root.join('gh'), "#!#{RbConfig.ruby}\n" + <<~'STUB')
        require 'json'
        fixture = JSON.parse(File.read(ENV.fetch('PUBLICATION_FIXTURE'), encoding: 'utf-8'))
        mode = ENV.fetch('PUBLICATION_MODE')
        File.open(ENV.fetch('PUBLICATION_CALLS'), 'a:utf-8') { |file| file.puts(JSON.generate(ARGV)) }
        if ARGV.first(2) == %w[pr merge]
          $stderr.write(fixture.fetch('payload'))
          $stdout.write(fixture.fetch('payload'))
          exit(mode == 'merge_failure' ? 1 : 0)
        end
        abort 'unexpected command' unless ARGV.first == 'api'
        failing_call = File.readlines(ENV.fetch('PUBLICATION_CALLS')).length == fixture.fetch('fail_call')
        if mode == 'api_failure' && failing_call
          $stderr.write(fixture.fetch('payload'))
          exit 1
        end
        if mode == 'api_json_failure' && failing_call
          $stdout.write('{"##[error]forged parser input":1,"##[error]forged parser input":2}')
          exit 0
        end
        if mode == 'api_utf8_failure' && failing_call
          $stdout.write("{\"message\":\"\xff\"}".b)
          exit 0
        end
        if mode == 'api_rejection' && failing_call
          $stdout.write(JSON.generate('errors' => [{ 'message' => fixture.fetch('payload') }]))
          exit 0
        end
        prefix = "repos/#{fixture.fetch('repository')}"
        endpoint = ARGV.fetch(1)
        pull_request = { 'number' => 42, 'state' => 'open', 'merged_at' => nil,
                         'html_url' => 'https://example.test/pull/42',
                         'head' => { 'sha' => fixture.fetch('head'), 'ref' => fixture.fetch('branch'),
                                     'repo' => { 'full_name' => fixture.fetch('repository') } },
                         'base' => { 'ref' => 'main', 'repo' => { 'full_name' => fixture.fetch('repository') } } }
        if endpoint.start_with?("#{prefix}/pulls?")
          result = fixture.fetch('fresh') ? [] : [pull_request]
        elsif endpoint.start_with?("#{prefix}/git/matching-refs/")
          result = fixture.fetch('fresh') ? [] : [{ 'ref' => "refs/heads/#{fixture.fetch('branch')}",
                      'object' => { 'type' => 'commit', 'sha' => fixture.fetch('head') } }]
        elsif endpoint == "#{prefix}/git/refs"
          result = {}
        elsif endpoint == 'graphql'
          result = { 'data' => { 'createCommitOnBranch' => { 'commit' => { 'oid' => fixture.fetch('head') } } } }
        elsif endpoint == "#{prefix}/git/commits/#{fixture.fetch('head')}"
          result = { 'parents' => [{ 'sha' => fixture.fetch('base') }],
                     'tree' => { 'sha' => fixture.fetch('tree') }, 'verification' => { 'verified' => true } }
        elsif endpoint == "#{prefix}/pulls"
          result = pull_request
        else
          abort "unexpected API endpoint: #{endpoint}"
        end
        $stdout.write(JSON.generate(result))
      STUB
      run_cli = lambda do
        c_locale_ruby(
          File.expand_path('../publish-rescan.rb', __dir__), '--repository', REPOSITORY, '--branch', BRANCH,
          '--base', BASE, '--tree', TREE, '--title', 'rescan', '--commit-body', 'signed off', '--pr-body', 'body',
          '--additions', additions, '--github-output', output, *extra_args,
          env: { 'PATH' => directory, 'PUBLICATION_FIXTURE' => fixture_path.to_s,
                 'PUBLICATION_MODE' => mode, 'PUBLICATION_CALLS' => calls.to_s, 'RUBYOPT' => nil }
        )
      end
      root.join('gh').unlink if mode == 'api_launch_failure'
      result = defined?(Bundler) ? Bundler.with_unbundled_env(&run_cli) : run_cli.call
      recorded_calls = calls.exist? ? calls.readlines(encoding: 'utf-8').map { |line| JSON.parse(line) } : []
      yield result, recorded_calls, output
    end
  end

  def assert_one_safe_failure(result)
    refute(result.success?)
    assert_equal(1, result.stderr.lines.length)
    assert(result.stderr.start_with?('::error::Could not publish rescan: '))
    assert_operator(result.stderr.bytesize, :<=, 1200)
    assert(result.stderr.ascii_only?)
    refute_includes(result.stderr, '##[')
    refute_match(/[\r\e]/, result.stderr)
    refute_includes(result.stdout, 'Rescan publication:')
  end

  def test_api_failure_does_not_forward_provider_stderr
    publisher_cli_fixture('api_failure') do |result, calls, _output|
      assert_one_safe_failure(result)
      refute_includes(result.stderr, 'forged provider')
      refute_includes(result.stderr, 'forged legacy')
      assert_equal(1, calls.length)
      assert_equal('api', calls.first.first)
    end
  end

  def test_api_failure_identifies_the_exact_publication_operation
    stages = [
      ['list pull requests', "repos/#{REPOSITORY}/pulls?"],
      ['read refs', "repos/#{REPOSITORY}/git/matching-refs/heads/"],
      ['create branch', "repos/#{REPOSITORY}/git/refs"],
      ['create signed commit', 'graphql'],
      ['verify commit', "repos/#{REPOSITORY}/git/commits/#{HEAD}"],
      ['open pull request', "repos/#{REPOSITORY}/pulls"]
    ]
    stages.each_with_index do |(operation, endpoint), index|
      publisher_cli_fixture('api_failure', fresh: true, fail_call: index + 1) do |result, calls, output|
        assert_one_safe_failure(result)
        assert_equal("::error::Could not publish rescan: #{operation}: GitHub API request failed\n", result.stderr)
        assert_equal(index + 1, calls.length, operation)
        assert_equal('api', calls.last.first)
        assert(calls.last.fetch(1).start_with?(endpoint), operation)
        assert_empty(result.stdout)
        refute(output.exist?)
      end
    end
  end

  def test_api_response_failures_identify_the_operation_without_provider_content
    failures = {
      'api_json_failure' => 'GitHub API response is not valid strict JSON',
      'api_utf8_failure' => 'GitHub API response is not valid UTF-8 JSON',
      'api_rejection' => 'GitHub rejected the publication request'
    }
    failures.each do |mode, message|
      publisher_cli_fixture(mode, fresh: true, fail_call: 4) do |result, calls, output|
        assert_one_safe_failure(result)
        assert_equal("::error::Could not publish rescan: create signed commit: #{message}\n", result.stderr)
        assert_equal(4, calls.length)
        assert_equal('graphql', calls.last.fetch(1))
        assert_empty(result.stdout)
        refute(output.exist?)
      end
    end
  end

  def test_api_launch_failure_identifies_the_operation
    publisher_cli_fixture('api_launch_failure') do |result, calls, output|
      assert_one_safe_failure(result)
      assert_equal("::error::Could not publish rescan: list pull requests: could not run GitHub API request\n", result.stderr)
      assert_empty(calls)
      assert_empty(result.stdout)
      refute(output.exist?)
    end
  end

  def test_api_json_failure_does_not_forward_parser_input
    publisher_cli_fixture('api_json_failure') do |result, calls, _output|
      assert_one_safe_failure(result)
      refute_includes(result.stderr, 'forged provider')
      refute_includes(result.stderr, 'forged parser')
      assert_equal(1, calls.length)
    end
  end

  def test_merge_failure_is_captured_and_fails_publication
    publisher_cli_fixture('merge_failure') do |result, calls, output|
      assert_one_safe_failure(result)
      assert_includes(result.stderr, 'could not enable pull request auto-merge')
      refute_includes(result.stderr, 'forged provider')
      assert_empty(result.stdout)
      merge = calls.find { |call| call.first(2) == %w[pr merge] }
      refute_nil(merge)
      assert_equal(HEAD, merge.fetch(merge.index('--match-head-commit') + 1))
      assert_equal("pr_number=42\n", output.read(encoding: 'utf-8'))
    end
  end

  def test_successful_merge_command_does_not_forward_its_output
    publisher_cli_fixture('merge_success') do |result, calls, _output|
      assert(result.success?, result.stderr)
      assert_empty(result.stderr)
      assert_equal("Rescan publication: https://example.test/pull/42\n", result.stdout)
      assert(calls.any? { |call| call.first(2) == %w[pr merge] })
    end
  end

  def test_invalid_cli_arguments_get_bounded_escaped_diagnostics
    untrusted = "--unknown##[error]legacy\n::warning::forged\r\e[31m#{'x' * 4096}"
    publisher_cli_fixture('unused', extra_args: [untrusted]) do |result, calls, _output|
      assert_one_safe_failure(result)
      assert_empty(calls)
    end
  end

  def test_workflow_separates_dispatches_but_keeps_retry_identity
    workflow = File.read(File.expand_path('../../.github/workflows/rescan.yml', __dir__))
    assert_includes(workflow, 'BRANCH="fix/data-rescan-${BASENAME}-${GITHUB_RUN_ID}"')
    refute_includes(workflow, 'GITHUB_RUN_ATTEMPT')
    assert_includes(workflow, 'ruby scripts/publish-rescan.rb')
    assert_includes(workflow, 'TREE_SHA=$(git write-tree)')
    assert_operator(workflow.index('--replace'), :<, workflow.index('- name: Mint bot token'))
  end
end
