#!/usr/bin/env ruby
# frozen_string_literal: true

Encoding.default_external = Encoding::UTF_8

module ReleaseNotes
  SECTIONS = {
    "feat" => "What's New", "fix" => "Fixes", "perf" => "Performance",
    "refactor" => "Under the Hood", "docs" => "Documentation", "style" => "Style", "test" => "Testing"
  }.freeze
  SKIP_TYPES = %w[build ci chore].freeze
  # Preserve Python's splitlines, whitespace and alphanumeric author semantics.
  LINE_SEPARATOR_RE = /\r\n|[\n\r\v\f\x1c-\x1e\u0085\u2028\u2029]/
  WHITESPACE_RE = /[[:space:]\x1c-\x1f]/
  NON_WHITESPACE_RE = /[^[:space:]\x1c-\x1f]/
  STRIP_RE = /\A#{WHITESPACE_RE}+|#{WHITESPACE_RE}+\z/
  PR_RE = /\A\*#{WHITESPACE_RE}+(?:(?<type>[a-z]+)(?:\([^)]*\))?!?:#{WHITESPACE_RE}*)?(?<desc>.+?)(?:#{WHITESPACE_RE}+by#{WHITESPACE_RE}+@[\p{L}\p{N}_-]+)?(?:#{WHITESPACE_RE}+in#{WHITESPACE_RE}+https?:\/\/#{NON_WHITESPACE_RE}+)?#{WHITESPACE_RE}*\z/
  CHANGELOG_RE = /\A\*\*Full Changelog\*\*:#{WHITESPACE_RE}*(?<url>https?:\/\/#{NON_WHITESPACE_RE}+)/
  module_function

  def parse_notes(raw)
    sections = {}
    changelog_url = nil
    raw.split(LINE_SEPARATOR_RE).each do |line|
      line = line.gsub(STRIP_RE, "")
      if (match = CHANGELOG_RE.match(line))
        changelog_url = match[:url]
        next
      end
      match = PR_RE.match(line)
      next unless match
      next if SKIP_TYPES.include?(match[:type])

      section = SECTIONS.fetch(match[:type], "Other")
      (sections[section] ||= []) << match[:desc].gsub(STRIP_RE, "")
    end
    [sections, changelog_url]
  end

  def format_markdown(tag, sections, changelog_url)
    lines = ["## macOSdb #{tag}", ""]
    (SECTIONS.values.uniq + ["Other"]).each do |heading|
      entries = sections[heading]
      next if entries.nil? || entries.empty?

      lines << "### #{heading}"
      lines.concat(entries.map { |entry| "- #{entry}" })
      lines << ""
    end
    lines.concat(["---", "**Full Changelog**: #{changelog_url}", ""]) if changelog_url
    lines.join("\n")
  end
end

if $PROGRAM_NAME == __FILE__
  abort "Usage: #{$PROGRAM_NAME} <raw_notes_file> <tag>" if ARGV.length < 2
  $stdout.write(ReleaseNotes.format_markdown(ARGV[1], *ReleaseNotes.parse_notes(File.read(ARGV[0], encoding: "utf-8"))) + "\n")
end
