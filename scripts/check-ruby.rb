#!/usr/bin/env ruby
# frozen_string_literal: true

Encoding.default_external = Encoding::UTF_8
require "rubygems/version"

module RubyRuntime
  module_function

  def compatible?(actual, required)
    current = Gem::Version.new(actual)
    minimum = Gem::Version.new(required)
    !current.prerelease? && current.segments.take(2) == minimum.segments.take(2) && current >= minimum
  end

  def main
    required = File.read(File.expand_path("../.ruby-version", __dir__), encoding: "utf-8").strip
    unless RUBY_ENGINE == "ruby" && compatible?(RUBY_VERSION, required)
      warn "::error::Ruby #{required} or a newer patch in its major.minor series is required; follow the scanner Ruby upgrade procedure in docs/operations.md."
      return 1
    end
    require "fiddle/import"
    require_relative "strict-json"
    StrictJSON.parse("{}")
    0
  rescue LoadError, StandardError => error
    warn "::error::Ruby runtime validation failed: #{error.message}"
    1
  end
end

exit RubyRuntime.main if $PROGRAM_NAME == __FILE__
