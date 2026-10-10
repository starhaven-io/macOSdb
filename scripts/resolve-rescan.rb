#!/usr/bin/env ruby
# frozen_string_literal: true

require 'date'
require_relative 'strict-json'
require 'optparse'

module ResolveRescan
  VERSION_RE = /\A[0-9]+\.[0-9]+(?:\.[0-9]+)?\z/
  BUILD_RE = /\A[0-9]+[A-Z][0-9]+[a-z]?\z/
  PREFIXES = { 'macos' => %w[macOS ipsw ipswURL], 'xcode' => %w[Xcode xip xipURL] }.freeze

  class ResolutionError < StandardError; end

  module_function

  def read_json(path)
    raise ResolutionError, "#{path} is not a regular file" unless File.lstat(path).file?

    text = File.read(path, encoding: 'utf-8')
    raise ResolutionError, "#{path} is not valid UTF-8 JSON" unless text.valid_encoding?

    StrictJSON.parse(text)
  end

  def optional_number(release, field)
    value = release[field]
    return '' if value.nil?
    unless value.is_a?(Integer) && value >= 1
      raise ResolutionError, "published #{field} is not a positive integer"
    end

    value.to_s
  end

  def resolve(root, product, version, build)
    raise ResolutionError, 'product must be macos or xcode' unless PREFIXES.key?(product)
    unless VERSION_RE.match?(version) && BUILD_RE.match?(build)
      raise ResolutionError, 'version or build number is not canonical'
    end
    prefix, extension, url_field = PREFIXES.fetch(product)
    major = version.split('.').first
    data_file = "releases/#{major}/#{prefix}-#{version}-#{build}.json"
    index = read_json(File.join(root, 'data', product, 'releases.json'))
    raise ResolutionError, 'trusted release index is not an array' unless index.is_a?(Array)

    matches = index.select do |entry|
      entry.is_a?(Hash) && entry['osVersion'] == version && entry['buildNumber'] == build
    end
    unless matches.length == 1 && matches.first['dataFile'] == data_file
      raise ResolutionError, "trusted main does not index exactly one #{prefix} #{version} (#{build})"
    end
    release = read_json(File.join(root, 'data', product, data_file))
    unless release.is_a?(Hash) && release.values_at('productType', 'osVersion', 'buildNumber') == [prefix, version, build]
      raise ResolutionError, 'published detail identity does not match its index entry'
    end

    release_date = release['releaseDate']
    source_url = release[url_field]
    begin
      parsed_date = Date.iso8601(release_date, Date::GREGORIAN) if release_date.is_a?(String)
      unless parsed_date && parsed_date.year.between?(1, 9999) && parsed_date.iso8601 == release_date
        raise ResolutionError, 'published releaseDate is not a canonical date'
      end
    rescue Date::Error
      raise ResolutionError, 'published releaseDate is not a canonical date'
    end
    unless source_url.is_a?(String) && %r{\Ahttps://[\x21-\x7e]+\z}.match?(source_url)
      raise ResolutionError, "published #{url_field} is not a single-line HTTPS URL"
    end
    is_beta = release['isBeta'] == true
    is_rc = release['isRC'] == true
    # The scanner cannot unset the beta inferred from a lowercase macOS build suffix.
    if product == 'macos' && !is_rc && is_beta != /[a-z]\z/.match?(build)
      raise ResolutionError, 'published beta flag differs from what a rescan would infer'
    end

    {
      'data_file' => "data/#{product}/#{data_file}",
      'archive_path' => "#{prefix}/#{major}/#{prefix}-#{version}-#{build}.#{extension}",
      'major' => major, 'release_date' => release_date, 'source_url' => source_url,
      'is_beta' => is_beta.to_s, 'beta_number' => optional_number(release, 'betaNumber'),
      'beta_revision' => optional_number(release, 'betaRevision'), 'is_rc' => is_rc.to_s,
      'rc_number' => optional_number(release, 'rcNumber'),
      'device_specific' => (release['isDeviceSpecific'] == true).to_s
    }
  end

  def main(argv = ARGV)
    args = {}
    parser = OptionParser.new do |options|
      %w[product version build github-output].each do |name|
        options.on("--#{name} VALUE") { |value| args[name.tr('-', '_').to_sym] = value }
      end
    end
    argv = argv.map { |argument| argument.dup.force_encoding(Encoding::UTF_8) }
    raise ResolutionError, 'arguments must be valid UTF-8' unless argv.all?(&:valid_encoding?)

    parser.parse!(argv)
    %i[product version build github_output].each do |key|
      raise OptionParser::MissingArgument, "--#{key.to_s.tr('_', '-')}" unless args.key?(key)
    end
    raise OptionParser::InvalidArgument, argv.join(' ') unless argv.empty?

    outputs = resolve(Dir.pwd, args.fetch(:product), args.fetch(:version), args.fetch(:build))
    File.open(args.fetch(:github_output), 'a:utf-8') do |output|
      outputs.each { |key, value| output.write("#{key}=#{value}\n") }
    end
    0
  rescue SystemCallError, IOError, JSON::ParserError, ResolutionError, OptionParser::ParseError => error
    warn "::error::#{error}"
    1
  end
end

if $PROGRAM_NAME == __FILE__
  $stdout.set_encoding(Encoding::UTF_8)
  $stderr.set_encoding(Encoding::UTF_8)
  exit ResolveRescan.main
end
