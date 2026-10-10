#!/usr/bin/env ruby
# frozen_string_literal: true

require 'date'
require 'fileutils'
require_relative 'strict-json'
require 'optparse'
require 'rubygems/package'
require 'stringio'
require 'tempfile'
require 'time'
require 'uri'
require 'zlib'

module VerifyReleaseArtifact
  MAX_MEMBER_SIZE = 32 * 1024 * 1024
  MAX_TOTAL_SIZE = 64 * 1024 * 1024
  MAX_METADATA_SIZE = 64 * 1024
  MAX_HEADERS = 16
  MAX_TAR_PADDING = 64 * 1024
  MAX_DIAGNOSTIC_BYTES = 120
  XCODE_PATH_RE = %r{\A/[A-Za-z0-9._~%/+-]+\.xip\z}
  XCODE_FILE_RE = /\AXcode_([0-9]+(?:\.[0-9]+)*)(?:_[A-Za-z0-9._~%+-]+)?\.xip\z/
  IPSW_FILE_RE = /\AUniversalMac_([0-9]+(?:\.[0-9]+){1,2})_([0-9]+[A-Z][0-9]+[a-z]?)_Restore\.ipsw\z/
  MACOS_RELEASE_NAMES = {
    '11' => 'Big Sur', '12' => 'Monterey', '13' => 'Ventura', '14' => 'Sonoma',
    '15' => 'Sequoia', '26' => 'Tahoe', '27' => 'Golden Gate'
  }.freeze
  DATE_ZONE_LOCK = Mutex.new

  class VerificationError < StandardError; end

  module_function

  def load_json_strict(data, label)
    StrictJSON.parse(data)
  rescue JSON::ParserError => error
    if error.message == 'the JSON parser must support rejection of duplicate object keys; update Ruby'
      raise VerificationError, 'Ruby JSON parser cannot reject duplicate keys; update Ruby'
    end
    label = 'input' unless ['artifact index', 'release detail', 'trusted index'].include?(label)
    if error.message.start_with?('duplicate key ')
      raise VerificationError, "#{label} contains duplicate JSON keys"
    end
    if error.message.start_with?('non-finite JSON number ')
      raise VerificationError, "#{label} contains a non-finite JSON number"
    end
    if error.message == 'JSON comments are not allowed'
      raise VerificationError, "#{label} JSON contains comments"
    end
    raise VerificationError, "#{label} JSON is malformed"
  end

  def parse_bool(value, name)
    raise VerificationError, "#{name} must be true or false" unless %w[true false].include?(value)

    value == 'true'
  end

  def parse_optional_int(value, name, minimum: 1)
    return nil if value == ''
    unless /\A[0-9]+\z/.match?(value) && value.to_i >= minimum
      raise VerificationError, "#{name} must be an integer of at least #{minimum}"
    end

    value.to_i
  end

  def resolve_release_date(input_date, run_started_at)
    unless input_date.empty?
      begin
        parsed = Date.strptime(input_date, '%Y-%m-%d', Date::GREGORIAN)
      rescue Date::Error
        raise VerificationError, 'release_date must be a real YYYY-MM-DD date'
      end
      unless parsed.year.between?(1, 9999) && parsed.strftime('%Y-%m-%d') == input_date
        raise VerificationError, 'release_date must use canonical YYYY-MM-DD syntax'
      end
      return input_date
    end

    begin
      started = Time.iso8601(run_started_at)
    rescue ArgumentError
      raise VerificationError, 'run_started_at is not an ISO-8601 timestamp'
    end
    DATE_ZONE_LOCK.synchronize do
      previous_zone = ENV['TZ']
      begin
        ENV['TZ'] = 'America/Los_Angeles'
        started.getlocal.strftime('%Y-%m-%d')
      ensure
        ENV['TZ'] = previous_zone
      end
    end
  end

  def expected_source(product, supplied_url, build_number)
    raise VerificationError, 'source URL contains a line break' if /[\r\n]/.match?(supplied_url)

    if product == 'xcode'
      matches = supplied_url.scan(/[?&]path=([^&]*)/)
      xip_path = matches.empty? ? supplied_url : matches.last.first
      unless XCODE_PATH_RE.match?(xip_path)
        raise VerificationError, 'Xcode source does not contain a clean absolute .xip path'
      end
      if xip_path.include?('//') || xip_path.split('/').any? { |part| %w[. ..].include?(part) }
        raise VerificationError, 'Xcode source path contains an ambiguous path segment'
      end
      if /%(?:00|0a|0d|2f|5c)/i.match?(xip_path)
        raise VerificationError, 'Xcode source path contains an encoded separator'
      end
      encoded_name = xip_path.split('/').last
      match = XCODE_FILE_RE.match(encoded_name)
      raise VerificationError, 'Xcode source filename is not canonical' unless match
      unless /\A[0-9]+[A-Z][0-9]+[a-z]?\z/.match?(build_number)
        raise VerificationError, 'Xcode build number is not canonical'
      end
      version = match[1]
      version += '.0' unless version.include?('.')
      return {
        'version' => version, 'build' => build_number,
        'file' => URI::DEFAULT_PARSER.unescape(encoded_name),
        'url' => "https://developer.apple.com/services-account/download?path=#{xip_path}"
      }
    end

    begin
      parsed = URI.parse(supplied_url)
    rescue URI::InvalidURIError
      raise VerificationError, 'IPSW source must be an updates.cdn-apple.com HTTPS URL'
    end
    raw_authority = supplied_url[%r{\Ahttps://([^/?#]*)}i, 1]
    unless parsed.scheme == 'https' && parsed.hostname&.downcase == 'updates.cdn-apple.com' &&
           raw_authority && !raw_authority.include?('@')
      raise VerificationError, 'IPSW source must be an updates.cdn-apple.com HTTPS URL'
    end
    filename = URI::DEFAULT_PARSER.unescape(parsed.path.split('/', -1).last.to_s)
    match = IPSW_FILE_RE.match(filename) if filename.valid_encoding?
    raise VerificationError, 'IPSW source filename is not canonical' unless match

    { 'version' => match[1], 'build' => match[2], 'file' => filename, 'url' => supplied_url }
  end

  def expected_prerelease(args, build)
    beta = parse_bool(args.fetch(:beta), 'beta')
    rc = parse_bool(args.fetch(:rc), 'rc')
    beta_number = parse_optional_int(args.fetch(:beta_number), 'beta_number')
    beta_revision = parse_optional_int(args.fetch(:beta_revision), 'beta_revision', minimum: 2)
    rc_number = parse_optional_int(args.fetch(:rc_number), 'rc_number')
    if beta_revision && !beta_number
      raise VerificationError, 'beta_revision requires beta_number'
    end
    if (beta || beta_number) && (rc || rc_number)
      raise VerificationError, 'a release cannot be both beta and RC'
    end

    is_rc = rc || !rc_number.nil?
    explicit_beta = beta || !beta_number.nil?
    is_beta = !is_rc && explicit_beta
    if args.fetch(:product) == 'macos' && !is_rc && !explicit_beta
      is_beta = /\A[0-9]+[A-Z][0-9]+[a-z]\z/.match?(build)
    end
    {
      'isBeta' => is_beta, 'betaNumber' => is_beta ? beta_number : nil,
      'betaRevision' => is_beta ? beta_revision : nil, 'isRC' => is_rc,
      'rcNumber' => is_rc ? rc_number : nil
    }
  end

  def diagnostic_name(value)
    bytes = value.to_s.b
    suffix = bytes.bytesize > MAX_DIAGNOSTIC_BYTES ? '...' : ''
    "#{bytes.byteslice(0, MAX_DIAGNOSTIC_BYTES).dump.gsub('##[', '## [')}#{suffix}"
  end

  def read_tar_payload(archive, size, name)
    data = archive.read(size)
    unless data && data.bytesize == size
      raise VerificationError, "artifact entry size changed while reading: #{diagnostic_name(name)}"
    end
    padding = (512 - size % 512) % 512
    if padding.positive? && archive.read(padding)&.bytesize != padding
      raise VerificationError, "artifact entry padding is truncated: #{diagnostic_name(name)}"
    end
    data
  end

  def parse_pax(data)
    values = {}
    until data.empty?
      match = /\A([0-9]+) /.match(data)
      raise VerificationError, 'artifact PAX metadata is malformed' unless match

      length = match[1].to_i
      record = data.byteslice(0, length)
      unless length > match[0].bytesize + 2 && record&.bytesize == length && record.end_with?("\n")
        raise VerificationError, 'artifact PAX metadata is malformed'
      end
      key, value = record.byteslice(match[0].bytesize, length - match[0].bytesize - 1).split('=', 2)
      if value.nil? || key.empty? || key.start_with?('GNU.sparse')
        raise VerificationError, 'artifact PAX metadata is unsupported'
      end
      values[key] = value
      data = data.byteslice(length..)
    end
    values
  end

  def verify_gzip_end(archive)
    padding_size = 0
    while (padding = archive.read(16 * 1024))
      padding_size += padding.bytesize
      if padding_size > MAX_TAR_PADDING || padding.bytes.any?(&:nonzero?)
        raise VerificationError, 'artifact has invalid trailing tar data'
      end
    end
    if (archive.unused && !archive.unused.empty?) || !archive.to_io.eof?
      raise VerificationError, 'artifact has concatenated gzip members or trailing compressed data'
    end
  end

  def read_artifact(artifact, expected_index, expected_release)
    raise VerificationError, "missing release artifact at #{diagnostic_name(artifact)}" unless File.file?(artifact)

    contents = {}
    total_size = 0
    header_count = 0
    global_metadata = {}
    pending_metadata = {}
    Zlib::GzipReader.open(artifact) do |archive|
      loop do
        raw_header = archive.read(512)
        break if raw_header.nil? || raw_header.empty? || raw_header == "\0" * 512
        raise VerificationError, 'artifact tar header is truncated' unless raw_header.bytesize == 512

        header_count += 1
        raise VerificationError, 'artifact contains too many metadata headers' if header_count > MAX_HEADERS

        header = Gem::Package::TarHeader.from(StringIO.new(raw_header))
        checksum_header = raw_header.dup
        checksum_header[148, 8] = ' ' * 8
        unless checksum_header.bytes.sum == header.checksum
          raise VerificationError, 'artifact tar header checksum does not match'
        end
        name = [header.prefix, header.name].reject(&:empty?).join('/')
        # PAX and GNU metadata describe the next logical file, not extra artifact files.
        if %w[x g L K].include?(header.typeflag)
          if header.size > MAX_METADATA_SIZE
            raise VerificationError, 'artifact tar metadata is too large'
          end
          payload = read_tar_payload(archive, header.size, name)
          case header.typeflag
          when 'g' then global_metadata.merge!(parse_pax(payload))
          when 'x' then pending_metadata.merge!(parse_pax(payload))
          when 'L' then pending_metadata['path'] = payload.split("\0", 2).first.to_s
          when 'K' then pending_metadata['linkpath'] = payload.split("\0", 2).first.to_s
          end
          next
        end
        metadata = global_metadata.merge(pending_metadata)
        pending_metadata = {}
        name = metadata.fetch('path', name)
        size = header.size
        if metadata.key?('size')
          unless /\A[0-9]+\z/.match?(metadata.fetch('size'))
            raise VerificationError, 'artifact PAX size is malformed'
          end
          size = metadata.fetch('size').to_i
        end
        raise VerificationError, 'artifact must contain exactly two entries' if contents.length >= 2
        if name.start_with?('/') || name.split('/').include?('..')
          raise VerificationError, "unsafe artifact path: #{diagnostic_name(name)}"
        end
        unless %w[0 7].include?(header.typeflag)
          raise VerificationError, "artifact entry is not a regular file: #{diagnostic_name(name)}"
        end
        unless [expected_index, expected_release].include?(name) && !contents.key?(name)
          raise VerificationError, "unexpected or duplicate artifact entry: #{diagnostic_name(name)}"
        end
        raise VerificationError, "artifact entry is too large: #{diagnostic_name(name)}" if size > MAX_MEMBER_SIZE

        total_size += size
        raise VerificationError, 'artifact expands beyond the allowed size' if total_size > MAX_TOTAL_SIZE

        contents[name] = read_tar_payload(archive, size, name)
      end
      verify_gzip_end(archive)
    end
    unless pending_metadata.empty? && contents.keys.sort == [expected_index, expected_release].sort
      raise VerificationError, 'artifact must contain exactly one index and one expected release'
    end

    [contents.fetch(expected_index), contents.fetch(expected_release)]
  rescue Zlib::Error, Gem::Package::TarInvalidError, ArgumentError
    raise VerificationError, 'artifact tar is malformed'
  end

  def atomic_write(path, data)
    FileUtils.mkdir_p(File.dirname(path))
    Tempfile.create([".#{File.basename(path)}.", ''], File.dirname(path)) do |destination|
      destination.binmode
      destination.write(data)
      destination.flush
      destination.fsync
      File.rename(destination.path, path)
    end
  end

  def verify_and_overlay(args)
    source = expected_source(args.fetch(:product), args.fetch(:source_url), args.fetch(:build_number))
    release_date = resolve_release_date(args.fetch(:release_date), args.fetch(:run_started_at))
    prerelease = expected_prerelease(args, source.fetch('build'))
    prefix = args.fetch(:product) == 'xcode' ? 'Xcode' : 'macOS'
    major = source.fetch('version').split('.').first
    data_file = "releases/#{major}/#{prefix}-#{source.fetch('version')}-#{source.fetch('build')}.json"
    index_name = "data/#{args.fetch(:product)}/releases.json"
    release_name = "data/#{args.fetch(:product)}/#{data_file}"
    index_bytes, release_bytes = read_artifact(args.fetch(:artifact), index_name, release_name)
    artifact_index = load_json_strict(index_bytes, 'artifact index')
    release = load_json_strict(release_bytes, 'release detail')
    unless artifact_index.is_a?(Array) && release.is_a?(Hash)
      raise VerificationError, 'artifact JSON has an invalid top-level type'
    end

    expected_fields = {
      'productType' => prefix, 'osVersion' => source.fetch('version'), 'buildNumber' => source.fetch('build'),
      'releaseDate' => release_date
    }.merge(prerelease)
    if args.fetch(:product) == 'xcode'
      expected_fields.merge!('xipFile' => source.fetch('file'), 'xipURL' => source.fetch('url'))
      unless release['releaseName'] == "Xcode #{source.fetch('version')}"
        raise VerificationError, 'Xcode release name does not match the dispatched version'
      end
    else
      expected_fields.merge!(
        'ipswFile' => source.fetch('file'), 'ipswURL' => source.fetch('url'),
        'isDeviceSpecific' => parse_bool(args.fetch(:device_specific), 'device_specific')
      )
      unless release['releaseName'] == MACOS_RELEASE_NAMES.fetch(major, "macOS #{major}")
        raise VerificationError, 'macOS release name does not match the dispatched version'
      end
    end
    expected_fields.each do |field, expected|
      actual = release[field]
      unless actual.class == expected.class && actual == expected
        raise VerificationError, "release field #{field} is not bound to the dispatch input"
      end
    end

    if File.exist?(release_name) && !args[:replace]
      raise VerificationError, "release already exists on the trusted base: #{release_name}"
    end
    if args[:replace] && !File.file?(release_name)
      raise VerificationError, "release to replace is missing from the trusted base: #{release_name}"
    end
    begin
      current_index = load_json_strict(File.binread(index_name), 'trusted index')
    rescue SystemCallError, IOError
      raise VerificationError, "could not read trusted index #{index_name}"
    end
    raise VerificationError, 'trusted release index is not an array' unless current_index.is_a?(Array)

    same_release = lambda do |entry|
      entry.is_a?(Hash) && entry['osVersion'] == source.fetch('version') && entry['buildNumber'] == source.fetch('build')
    end
    matches = artifact_index.select(&same_release)
    unless matches.length == 1
      raise VerificationError, 'artifact index must contain exactly one dispatched release'
    end
    fields = %w[productType osVersion buildNumber releaseName releaseDate isBeta betaNumber betaRevision isRC rcNumber]
    fields << 'isDeviceSpecific' if args.fetch(:product) == 'macos'
    expected_entry = release.select { |field, _value| fields.include?(field) }.merge('dataFile' => data_file)
    unless matches.first == expected_entry
      raise VerificationError, 'artifact index metadata does not exactly match its release detail'
    end
    trusted_others = current_index
    if args[:replace]
      trusted_others = current_index.reject(&same_release)
      unless trusted_others.length == current_index.length - 1
        raise VerificationError, 'trusted main index must contain exactly the release being replaced'
      end
    end
    without_release = artifact_index.reject { |entry| entry.equal?(matches.first) }
    unless without_release == trusted_others
      change = args[:replace] ? 'replacement of' : 'addition to'
      raise VerificationError, "artifact index is not a one-release #{change} the trusted main index"
    end

    original_release = File.binread(release_name) if args[:replace]
    atomic_write(release_name, release_bytes)
    begin
      atomic_write(index_name, index_bytes)
    rescue StandardError
      original_release.nil? ? FileUtils.rm_f(release_name) : atomic_write(release_name, original_release)
      raise
    end
    ["#{prefix}-#{source.fetch('version')}-#{source.fetch('build')}", source.fetch('url'), release_date]
  end

  def main(argv = ARGV)
    args = { build_number: '', release_date: '', run_started_at: '', beta_number: '', beta_revision: '',
             rc_number: '', device_specific: 'false', replace: false }
    parser = OptionParser.new do |options|
      %w[artifact product source-url build-number release-date run-started-at beta beta-number beta-revision rc rc-number device-specific github-output].each do |name|
        options.on("--#{name} VALUE") { |value| args[name.tr('-', '_').to_sym] = value }
      end
      options.on('--replace') { args[:replace] = true }
    end
    argv = argv.map { |argument| argument.dup.force_encoding(Encoding::UTF_8) }
    raise VerificationError, 'arguments must be valid UTF-8' unless argv.all?(&:valid_encoding?)

    parser.parse!(argv)
    %i[artifact product source_url beta rc].each do |key|
      raise OptionParser::MissingArgument, "--#{key.to_s.tr('_', '-')}" unless args.key?(key)
    end
    raise VerificationError, 'product must be macos or xcode' unless %w[macos xcode].include?(args[:product])
    raise OptionParser::InvalidArgument, argv.join(' ') unless argv.empty?

    basename, source_url, release_date = verify_and_overlay(args)
    if args[:github_output]
      File.open(args[:github_output], 'a:utf-8') do |output|
        output.write("basename=#{basename}\nsource_url=#{source_url}\nrelease_date=#{release_date}\n")
      end
    end
    change = args[:replace] ? 'replacement in' : 'addition to'
    puts "Verified #{basename} as an exact one-release #{change} trusted main."
    0
  rescue SystemCallError, IOError, VerificationError, OptionParser::ParseError => error
    warn "::error::#{error}"
    1
  end
end

if $PROGRAM_NAME == __FILE__
  $stdout.set_encoding(Encoding::UTF_8)
  $stderr.set_encoding(Encoding::UTF_8)
  exit VerifyReleaseArtifact.main
end
