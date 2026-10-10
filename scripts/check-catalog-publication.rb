#!/usr/bin/env ruby
# frozen_string_literal: true

Encoding.default_external = Encoding::UTF_8

require "json"
require "open3"
require "optparse"
require "timeout"
require_relative "strict-json"

module CatalogPublication
  module_function

  def pending_publications(pages, repository)
    raise ArgumentError, "missing pull-request pages" unless pages.is_a?(Array) && !pages.empty?

    pending = []
    pages.each do |page|
      raise ArgumentError, "invalid pull-request page" unless page.is_a?(Array)

      page.each do |pr|
        raise ArgumentError, "invalid pull-request record" unless pr.is_a?(Hash)

        state, base, author, branch = pr.fetch("state"), pr.fetch("base").fetch("ref"),
                                      pr.fetch("user").fetch("login"), pr.fetch("head").fetch("ref")
        unless [state, base, author, branch].all? { |value| value.is_a?(String) && !value.empty? }
          raise ArgumentError, "incomplete pull-request metadata"
        end
        next unless state == "open" && base == "main" && author == "starhaven-bot[bot]"
        next unless branch.start_with?("feat/data-", "fix/data-rescan-")

        head_repo = pr.fetch("head").fetch("repo").fetch("full_name")
        raise ArgumentError, "missing publication repository" unless head_repo.is_a?(String) && !head_repo.empty?
        next unless head_repo.casecmp?(repository)

        number = pr.fetch("number")
        raise ArgumentError, "invalid publication PR number" unless number.is_a?(Integer) && number.positive?

        pending << number
      end
    end
    pending.uniq.sort
  end

  def inventory(repository, timeout: 60)
    # Kill and reap a stalled GitHub CLI before returning a failed guard.
    Open3.popen3("gh", "api", "--paginate", "--slurp",
                 "repos/#{repository}/pulls?state=open&base=main&per_page=100", pgroup: true) do |stdin, stdout, stderr, wait|
      stdin.close
      out = Thread.new { stdout.read }
      err = Thread.new { stderr.read }
      begin
        Timeout.timeout(timeout) do
          status = wait.value
          raise "GitHub request failed" unless status.success?

          pending_publications(StrictJSON.parse(out.value), repository)
        end
      rescue Timeout::Error
        begin
          Process.kill("KILL", -wait.pid)
        rescue Errno::ESRCH
          # The process group may finish at the timeout boundary.
        end
        raise
      ensure
        if wait.alive?
          Process.kill("KILL", wait.pid)
          wait.join
        end
        out.join
        err.join
      end
    end
  end

  def main(argv)
    options = {}
    parser = OptionParser.new { |opts| opts.on("--repository OWNER/NAME") { |v| options[:repository] = v } }
    parser.parse!(argv)
    repository = options.fetch(:repository, "")
    raise OptionParser::InvalidArgument, "repository must be owner/name" unless /\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/.match?(repository) && argv.empty?

    begin
      pending = inventory(repository)
    rescue StandardError
      warn "::error::Could not verify pending catalog publications; refusing to scan."
      return 1
    end
    unless pending.empty?
      warn "::error::Catalog publication still open: #{pending.map { |number| "##{number}" }.join(', ')}. " \
           "Merge or close it, then start a fresh scanner dispatch."
      return 1
    end
    0
  rescue OptionParser::ParseError => e
    warn e.message
    1
  end
end

exit CatalogPublication.main(ARGV) if $PROGRAM_NAME == __FILE__
