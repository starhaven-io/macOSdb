#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'strict-json'
require 'open3'
require 'optparse'
require 'uri'

module PublishRescan
  MAX_DIAGNOSTIC_BYTES = 256

  class PublicationError < StandardError; end

  module_function

  def api(operation, endpoint, payload = nil)
    command = ['gh', 'api', endpoint]
    command += ['--method', 'POST', '--input', '-'] unless payload.nil?
    stdout, _stderr, status = Open3.capture3(*command, stdin_data: payload.nil? ? '' : JSON.generate(payload))
    raise PublicationError, "#{operation}: GitHub API request failed" unless status.success?

    text = stdout.dup.force_encoding(Encoding::UTF_8)
    raise PublicationError, "#{operation}: GitHub API response is not valid UTF-8 JSON" unless text.valid_encoding?

    response = StrictJSON.parse(text)
    if response.is_a?(Hash) && response['errors'] && response['errors'] != [] && response['errors'] != {}
      raise PublicationError, "#{operation}: GitHub rejected the publication request"
    end
    response
  rescue JSON::ParserError
    raise PublicationError, "#{operation}: GitHub API response is not valid strict JSON"
  rescue SystemCallError, IOError
    raise PublicationError, "#{operation}: could not run GitHub API request"
  end

  def verify_commit(repository, head, base, tree)
    commit = api('verify commit', "repos/#{repository}/git/commits/#{head}")
    unless commit.fetch('parents').map { |parent| parent.fetch('sha') } == [base] &&
           commit.fetch('tree').fetch('sha') == tree && commit.fetch('verification').fetch('verified') == true
      raise PublicationError, 'publication commit must be signed and match the recorded base and verified tree'
    end
  end

  def publish(repository, branch, base, tree, title, commit_body, pr_body, additions)
    query = URI.encode_www_form('state' => 'all', 'head' => "#{repository.split('/').first}:#{branch}",
                                'base' => 'main', 'per_page' => 100)
    pull_requests = api('list pull requests', "repos/#{repository}/pulls?#{query}")
    raise PublicationError, 'multiple pull requests exist for this rescan run' if pull_requests.length > 1

    existing = pull_requests.first
    unless existing.nil?
      unless existing.fetch('head').fetch('repo').fetch('full_name') == repository &&
             existing.fetch('head').fetch('ref') == branch &&
             existing.fetch('base').fetch('repo').fetch('full_name') == repository &&
             existing.fetch('base').fetch('ref') == 'main'
        raise PublicationError, 'pull request identity does not match this rescan'
      end
      verify_commit(repository, existing.fetch('head').fetch('sha'), base, tree)
      return existing unless existing.fetch('merged_at').nil?
      unless existing.fetch('state') == 'open'
        raise PublicationError, 'rescan pull request was closed without merging; use a fresh dispatch'
      end
    end

    reference = "refs/heads/#{branch}"
    encoded_branch = branch.split('/').map { |part| URI.encode_uri_component(part) }.join('/')
    refs = api('read refs', "repos/#{repository}/git/matching-refs/heads/#{encoded_branch}")
    matches = refs.select { |ref| ref.fetch('ref') == reference }
    raise PublicationError, 'ambiguous publication branch' if matches.length > 1

    if matches.any?
      unless matches.first.fetch('object').fetch('type') == 'commit'
        raise PublicationError, 'publication branch does not refer to a commit'
      end
      head = matches.first.fetch('object').fetch('sha')
    else
      raise PublicationError, 'open rescan pull request has lost its branch' unless existing.nil?

      api('create branch', "repos/#{repository}/git/refs", { 'ref' => reference, 'sha' => base })
      head = base
    end
    if existing && existing.fetch('head').fetch('sha') != head
      raise PublicationError, 'publication branch no longer matches its pull request'
    end
    if head == base
      response = api('create signed commit', 'graphql', {
        'query' => 'mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }',
        'variables' => { 'input' => {
          'branch' => { 'repositoryNameWithOwner' => repository, 'branchName' => branch },
          'message' => { 'headline' => title, 'body' => commit_body },
          'fileChanges' => { 'additions' => additions }, 'expectedHeadOid' => base
        } }
      })
      head = response.fetch('data').fetch('createCommitOnBranch').fetch('commit').fetch('oid')
    end
    verify_commit(repository, head, base, tree)
    existing ||= api('open pull request', "repos/#{repository}/pulls", {
      'base' => 'main', 'head' => branch, 'title' => title, 'body' => pr_body
    })
    unless existing.fetch('head').fetch('sha') == head
      raise PublicationError, 'pull request head changed during publication'
    end

    existing
  end

  def diagnostic_message(error)
    bytes = error.message.to_s.b
    message = bytes.byteslice(0, MAX_DIAGNOSTIC_BYTES).dump[1...-1].gsub('##[', '## [')
    bytes.bytesize > MAX_DIAGNOSTIC_BYTES ? "#{message}..." : message
  end

  def main(argv = ARGV)
    args = {}
    names = %w[repository branch base tree title commit-body pr-body additions github-output]
    parser = OptionParser.new do |options|
      names.each { |name| options.on("--#{name} VALUE") { |value| args[name] = value } }
    end
    argv = argv.map { |argument| argument.dup.force_encoding(Encoding::UTF_8) }
    raise PublicationError, 'arguments must be valid UTF-8' unless argv.all?(&:valid_encoding?)

    parser.parse!(argv)
    names.each { |name| raise OptionParser::MissingArgument, "--#{name}" unless args.key?(name) }
    raise OptionParser::InvalidArgument, argv.join(' ') unless argv.empty?

    additions_text = File.read(args.fetch('additions'), encoding: 'utf-8')
    raise PublicationError, 'additions are not valid UTF-8 JSON' unless additions_text.valid_encoding?

    result = publish(
      args.fetch('repository'), args.fetch('branch'), args.fetch('base'), args.fetch('tree'), args.fetch('title'),
      args.fetch('commit-body'), args.fetch('pr-body'), StrictJSON.parse(additions_text)
    )
    number = result.fetch('number')
    unless number.is_a?(Integer) && number >= 1
      raise PublicationError, 'GitHub returned an invalid pull request number'
    end
    File.open(args.fetch('github-output'), 'a:utf-8') { |output| output.write("pr_number=#{number}\n") }
    if result.fetch('merged_at').nil?
      _stdout, _stderr, status = Open3.capture3('gh', 'pr', 'merge', number.to_s, '--repo', args.fetch('repository'),
                       '--squash', '--auto', '--match-head-commit', result.fetch('head').fetch('sha'),
                       '--delete-branch', '--body', args.fetch('commit-body'))
      raise PublicationError, 'could not enable pull request auto-merge' unless status.success?
    end
    puts "Rescan publication: #{result.fetch('html_url')}"
    0
  rescue PublicationError, SystemCallError, IOError, JSON::ParserError, KeyError, TypeError,
         NoMethodError, OptionParser::ParseError => error
    warn "::error::Could not publish rescan: #{diagnostic_message(error)}"
    1
  end
end

if $PROGRAM_NAME == __FILE__
  $stdout.set_encoding(Encoding::UTF_8)
  $stderr.set_encoding(Encoding::UTF_8)
  exit PublishRescan.main
end
