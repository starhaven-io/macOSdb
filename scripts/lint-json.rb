#!/usr/bin/env ruby
# frozen_string_literal: true

# Validate release schema, catalog completeness, file/URL parity and index order.
require "date"
require "fiddle/import"
require "json"
require "pathname"
require "set"
require "uri"
require_relative "strict-json"

Encoding.default_external = Encoding::UTF_8

module LintJson
  SHARED_REQUIRED = %w[buildNumber osVersion releaseDate releaseName isBeta isRC productType components].freeze
  MACOS_REQUIRED = (SHARED_REQUIRED + %w[isDeviceSpecific ipswFile ipswURL kernels]).freeze
  XCODE_REQUIRED = (SHARED_REQUIRED + %w[xipFile xipURL minimumOSVersion sdks]).freeze
  MACOS_ALLOWED = (MACOS_REQUIRED + %w[betaNumber betaRevision rcNumber]).to_set.freeze
  XCODE_ALLOWED = (XCODE_REQUIRED + %w[betaNumber betaRevision rcNumber]).to_set.freeze
  INDEX_SHARED_REQUIRED = %w[buildNumber osVersion releaseDate releaseName isBeta isRC productType dataFile].freeze
  MACOS_INDEX_REQUIRED = (INDEX_SHARED_REQUIRED + %w[isDeviceSpecific]).freeze
  XCODE_INDEX_REQUIRED = INDEX_SHARED_REQUIRED
  PARITY_FIELDS = %w[osVersion releaseDate releaseName isBeta isRC productType betaNumber betaRevision rcNumber].freeze
  MACOS_PARITY_FIELDS = (PARITY_FIELDS + %w[isDeviceSpecific]).freeze
  MACOS_BOOL_FIELDS = %w[isBeta isRC isDeviceSpecific].freeze
  XCODE_BOOL_FIELDS = %w[isBeta isRC].freeze
  COMPONENT_REQUIRED = %w[name version path source].freeze
  MACOS_COMPONENT_SOURCES = {
    **%w[curl httpd LibreSSL OpenSSH Ruby SQLite sudo vim zsh].to_h { |name| [name, "filesystem"] },
    **["libbz2 (bzip2)", "libcurl", "libexpat", "libncurses", "libpcap", "libsqlite3",
       "libssl (LibreSSL)", "libxml2"].to_h { |name| [name, "dyldCache"] }
  }.freeze
  XCODE_COMPONENT_SOURCES = {
    **["Apple Clang", "cctools", "Git", "ld", "lldb", "Python", "Swift"].to_h { |name| [name, "filesystem"] },
    **%w[bzip2 expat libcurl libexslt libffi libxml2 libxslt ncurses sqlite3 zlib].to_h { |name| [name, "sdk"] }
  }.freeze
  MACOS_EXPECTED_COMPONENTS = MACOS_COMPONENT_SOURCES.keys.to_set.freeze
  XCODE_EXPECTED_COMPONENTS = XCODE_COMPONENT_SOURCES.keys.to_set.freeze
  IPSW_FILE_RE = /\AUniversalMac_([0-9]+(?:\.[0-9]+){1,2})_([0-9]+[A-Z][0-9]+[a-z]?)_Restore\.ipsw\z/
  XCODE_FILE_RE = /\AXcode_([0-9]+(?:\.[0-9]+)*)(?:_([A-Za-z0-9._~%+\-]+))?\.xip\z/
  # Archive suffixes use whole underscore-delimited tokens; Xcode 13 used beta3.
  XCODE_BETA_LABEL_RE = /(?:\A|_)beta[0-9]*(?=_|\z)/
  XCODE_RC_LABEL_RE = /(?:\A|_)Release_Candidate(?=_|\z)/
  VERSION_RE = /\A[0-9]+\.[0-9]+(?:\.[0-9]+)?\z/
  BUILD_IDENTIFIER_RE = /\A[0-9]+[A-Z][0-9]+[a-z]?\z/
  DATE_RE = /\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/
  CONTROL_CHARACTER_RE = /[\u0000-\u001f\u007f-\u009f]/
  TODAY = Date.today
  MAX_INDEX_BYTES = 4 * 1024 * 1024
  MAX_RELEASE_BYTES = 16 * 1024 * 1024
  MACOS_RELEASE_NAMES = {
    "11" => "Big Sur", "12" => "Monterey", "13" => "Ventura", "14" => "Sonoma",
    "15" => "Sequoia", "26" => "Tahoe", "27" => "Golden Gate"
  }.freeze
  APPLE_DOWNLOAD_HOST_SUFFIXES = %w[.apple.com .cdn-apple.com].freeze
  PRODUCTS = [
    {
      "name" => "macOS", "prefix" => "macOS",
      "data" => Pathname("data/macos/releases"), "index" => Pathname("data/macos/releases.json"),
      "required" => MACOS_REQUIRED, "allowed" => MACOS_ALLOWED,
      "index_required" => MACOS_INDEX_REQUIRED, "parity_fields" => MACOS_PARITY_FIELDS,
      "bool_fields" => MACOS_BOOL_FIELDS, "component_sources" => %w[filesystem dyldCache].to_set,
      "expected_components" => MACOS_EXPECTED_COMPONENTS,
      "expected_component_sources" => MACOS_COMPONENT_SOURCES, "expect_kernels" => true
    },
    {
      "name" => "Xcode", "prefix" => "Xcode",
      "data" => Pathname("data/xcode/releases"), "index" => Pathname("data/xcode/releases.json"),
      "required" => XCODE_REQUIRED, "allowed" => XCODE_ALLOWED,
      "index_required" => XCODE_INDEX_REQUIRED, "parity_fields" => PARITY_FIELDS,
      "bool_fields" => XCODE_BOOL_FIELDS, "component_sources" => %w[filesystem sdk].to_set,
      "expected_components" => XCODE_EXPECTED_COMPONENTS,
      "expected_component_sources" => XCODE_COMPONENT_SOURCES, "expect_kernels" => false
    }
  ].freeze

  # Ruby has no descriptor-relative File.open. openat retains the checked parent
  # descriptor when untrusted catalog directories are renamed during traversal.
  module Native
    extend Fiddle::Importer
    dlload Fiddle.dlopen(nil)
    extern "int openat(int, const char*, int)"
    O_CLOEXEC = if File.const_defined?(:CLOEXEC)
      File::CLOEXEC
    elsif RUBY_PLATFORM.include?("darwin")
      0x1000000
    elsif RUBY_PLATFORM.include?("linux")
      0x80000
    else
      raise NotImplementedError, "catalog reads require macOS or Linux openat flags"
    end
  end

  class << self
    attr_accessor :errors, :warnings
  end
  self.errors = 0
  self.warnings = 0
  module_function

  MAX_DIAGNOSTIC_BYTES = 1024
  DIAGNOSTIC_CONTROL_RE = /[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u2028-\u202e\u2066-\u2069]/

  def diagnostic(message)
    bytes = message.to_s.b
    truncated = bytes.bytesize > MAX_DIAGNOSTIC_BYTES
    text = bytes.byteslice(0, MAX_DIAGNOSTIC_BYTES).force_encoding(Encoding::UTF_8).scrub do |invalid|
      invalid.bytes.map { |byte| format("\\x%02X", byte) }.join
    end
    text = text.gsub("##[", "## [")
    output = +""
    text.each_char do |character|
      escaped = DIAGNOSTIC_CONTROL_RE.match?(character) ? character.dump[1...-1] : character
      if output.bytesize + escaped.bytesize > MAX_DIAGNOSTIC_BYTES - 3
        truncated = true
        break
      end
      output << escaped
    end
    output << "..." if truncated
    output
  end

  def error(message)
    self.errors += 1
    $stderr.puts "  ERROR: #{diagnostic(message)}"
  end

  def warn(message)
    self.warnings += 1
    $stderr.puts "  WARNING: #{diagnostic(message)}"
  end

  def open_relative(directory, name, flags)
    descriptor = Native.openat(directory.fileno, name, flags)
    raise SystemCallError.new(name, Fiddle.last_error) if descriptor.negative?

    IO.for_fd(descriptor, "rb", autoclose: true)
  end

  def require_directory(descriptor, name)
    raise Errno::ENOTDIR, name.to_s unless descriptor.stat.directory?

    descriptor
  rescue StandardError
    descriptor.close
    raise
  end

  def read_json(path, max_bytes, root = nil)
    path = Pathname(path)
    root = Pathname(root || path.parent)
    path_parts = Pathname(path.absolute? ? path.to_s : File.join(Dir.pwd, path.to_s)).each_filename.to_a
    root_parts = Pathname(root.absolute? ? root.to_s : File.join(Dir.pwd, root.to_s)).each_filename.to_a
    relative = path_parts.drop(root_parts.length)
    unless path_parts.take(root_parts.length) == root_parts && !relative.empty? && !relative.include?("..")
      raise ArgumentError, "file must be inside the catalog directory"
    end

    flags = File::RDONLY | File::NOFOLLOW | File::NONBLOCK | Native::O_CLOEXEC
    directory = require_directory(File.open(root, flags), root)
    begin
      relative[0...-1].each do |part|
        child = require_directory(open_relative(directory, part, flags), part)
        directory.close
        directory = child
      end
      source = open_relative(directory, relative.last, flags)
    ensure
      directory.close
    end
    begin
      before = source.stat
      raise ArgumentError, "file must be a regular file" unless before.file?
      raise ArgumentError, "file exceeds the #{max_bytes}-byte size limit" if before.size > max_bytes

      data = source.read(max_bytes + 1) || "".b
      after = source.stat
    ensure
      source.close
    end
    raise ArgumentError, "file exceeds the #{max_bytes}-byte size limit" if data.bytesize > max_bytes
    unless [before.size, before.mtime, before.ctime] == [after.size, after.mtime, after.ctime]
      raise ArgumentError, "file changed while being read"
    end

    StrictJSON.parse(data)
  end

  def boolean?(value)
    value.equal?(true) || value.equal?(false)
  end

  def string?(value)
    value.is_a?(String) && !value.empty?
  end

  def type_name(value)
    case value
    when NilClass then "NoneType"
    when TrueClass, FalseClass then "bool"
    when String then "str"
    when Integer then "int"
    when Float then "float"
    when Array then "list"
    when Hash then "dict"
    else value.class.name
    end
  end

  def representation(value)
    case value
    when nil then "None"
    when true then "True"
    when false then "False"
    else value.inspect
    end
  end

  def validate_date(value, field, build)
    unless string?(value)
      error("#{build}: #{field} is empty or not a string")
      return
    end
    unless DATE_RE.match?(value)
      error("#{build}: #{field} '#{value}' is not ISO 8601 (YYYY-MM-DD)")
      return
    end
    begin
      date = Date.strptime(value, "%Y-%m-%d", Date::GREGORIAN)
      raise Date::Error if date.year.zero?
    rescue Date::Error
      error("#{build}: #{field} '#{value}' is not a valid date")
      return
    end
    warn("#{build}: #{field} #{value} is in the future") if date > TODAY
    warn("#{build}: #{field} #{value} is before 2001") if date.year < 2001
  end

  ParsedURL = Data.define(:scheme, :hostname, :userinfo, :path, :query)
  def parsed_url(url)
    # Split like urllib.parse.urlparse, including its treatment of wrapper paths,
    # rather than changing catalog policy through URI.parse's stricter syntax.
    remaining = url.delete("\t\r\n").sub(/\A[\u0000-\u0020]+/, "")
    scheme_match = /\A([A-Za-z][A-Za-z0-9+.\-]*):/.match(remaining)
    scheme = scheme_match ? scheme_match[1].downcase : ""
    remaining = remaining[scheme_match[0].length..] if scheme_match
    authority = ""
    if remaining.start_with?("//")
      authority = remaining[2..].split(/[\/?#]/, 2).first || ""
      remaining = remaining[(authority.length + 2)..]
    end
    remaining = remaining.split("#", 2).first || ""
    path, separator, query = remaining.partition("?")
    query = "" if separator.empty?
    # A semicolon on the final path segment denotes URL parameters.
    if %w[http https ftp hdl prospero rtsp rtsps rtspu sip sips mms sftp tel].include?(scheme) || scheme.empty?
      directory, slash, basename = path.rpartition("/")
      path = directory + slash + basename.split(";", 2).first.to_s
    end
    credentials, at, host_port = authority.rpartition("@")
    hostname = if host_port.start_with?("[")
      URI.parse("https://#{host_port}").hostname
    else
      host_port.split(":", 2).first.to_s
    end
    normalized = authority.delete("@:#?").unicode_normalize(:nfkc)
    return nil if normalized.match?(/[\/?#@:]/)

    ParsedURL.new(scheme, hostname.downcase, at.empty? ? nil : credentials, path, query)
  rescue URI::InvalidURIError, ArgumentError
    nil
  end

  def validate_download_url(url, field, name)
    unless string?(url)
      error("#{name}: #{field} is empty or not a string")
      return
    end
    parsed = parsed_url(url)
    unless parsed&.scheme&.downcase == "https"
      error("#{name}: #{field} must use https, got '#{parsed&.scheme || url[0, 16]}'")
      return
    end
    host = (parsed.hostname || "").downcase
    error("#{name}: #{field} must not contain URL credentials") if parsed.userinfo
    unless host == "apple.com" || APPLE_DOWNLOAD_HOST_SUFFIXES.any? { |suffix| host.end_with?(suffix) }
      error("#{name}: #{field} host '#{host}' is not an Apple download domain")
    end
  end

  def unquote(value)
    URI::DEFAULT_PARSER.unescape(value).force_encoding(Encoding::UTF_8).scrub
  end

  def download_filename(url, query_parameter: nil)
    return "" unless url.is_a?(String)

    parsed = parsed_url(url)
    return "" unless parsed

    source_path = parsed.path || ""
    if query_parameter
      (parsed.query || "").split("&").each do |field|
        key, separator, value = field.partition("=")
        next unless !separator.empty? && unquote(key) == query_parameter

        source_path = unquote(value)
        break
      end
    end
    unquote(source_path.split("/", -1).last || "")
  end

  def xcode_file_version(filename)
    match = XCODE_FILE_RE.match(filename) if filename.is_a?(String)
    return nil unless match

    match[1].include?(".") ? match[1] : "#{match[1]}.0"
  end

  def xcode_file_label(filename)
    match = XCODE_FILE_RE.match(filename) if filename.is_a?(String)
    return nil unless match

    suffix = match[2] || ""
    return "beta" if XCODE_BETA_LABEL_RE.match?(suffix)
    return "Release_Candidate" if XCODE_RC_LABEL_RE.match?(suffix)

    nil
  end

  def parse_version(version)
    return nil unless version.is_a?(String)

    parts = version.split(".", -1)
    [Integer(parts[0], 10), parts.length > 1 ? Integer(parts[1], 10) : 0,
     parts.length > 2 ? Integer(parts[2], 10) : 0]
  rescue ArgumentError, TypeError
    nil
  end

  BUILD_RE = /\A([0-9]*)([A-Za-z]*)([0-9]*)(.*)/
  def parse_build(build)
    return [0, "", 0, ""] unless build.is_a?(String)

    match = BUILD_RE.match(build)
    [match[1].to_i, match[2], match[3].to_i, match[4]]
  end

  def release_sort_key_desc(entry)
    version = parse_version(entry.fetch("osVersion", "0.0")) || [0, 0, 0]
    rank = entry["isBeta"].equal?(true) ? 0 : entry["isRC"].equal?(true) ? 1 : 2
    [-version[0], -version[1], -version[2], -rank, parse_build(entry.fetch("buildNumber", ""))]
  end

  def desc_build_cmp(lhs, rhs)
    left = release_sort_key_desc(lhs)
    right = release_sort_key_desc(rhs)
    comparison = left.take(4) <=> right.take(4)
    comparison.zero? ? right[4] <=> left[4] : comparison
  end

  def sorted_releases(entries)
    entries.each_with_index.sort do |(left, left_index), (right, right_index)|
      comparison = desc_build_cmp(left, right)
      comparison.zero? ? left_index <=> right_index : comparison
    end.map(&:first)
  end

  def require_string(object, field, context)
    value = object[field]
    unless string?(value)
      error("#{context}: #{field} is empty or not a string")
      return nil
    end
    value
  end

  def reject_control_characters(value, context, path = "$")
    case value
    when String
      error("#{context}: #{path} contains a control character") if CONTROL_CHARACTER_RE.match?(value)
    when Hash
      value.each do |key, item|
        reject_control_characters(key, context, "#{path} key")
        reject_control_characters(item, context, "#{path}[#{JSON.generate(key)}]")
      end
    when Array
      value.each_with_index { |item, index| reject_control_characters(item, context, "#{path}[#{index}]") }
    end
  end

  def validate_product_type(value, expected, context)
    error("#{context}: productType '#{value}' should be '#{expected}'") if !value.nil? && value != expected
  end

  def catalog_files(data_dir)
    paths = Dir.glob("**/*.json", File::FNM_DOTMATCH, base: data_dir.to_s, sort: false)
    paths.select { |path| path.b.end_with?(".json".b) }.sort_by(&:b).filter_map do |path|
      relative = path.dup.force_encoding(Encoding::UTF_8)
      unless relative.valid_encoding?
        # Filesystem names are bytes on Linux; bound and escape them before logging.
        label = path.b.byteslice(0, 128).inspect
        label += "..." if path.bytesize > 128
        error("release catalog path contains invalid UTF-8: #{label}")
        next
      end
      data_dir.join(relative)
    end
  end

  def validate_releases(product, catalog)
    data_dir = Pathname(product["data"])
    prefix = product["prefix"]
    all_component_names = Hash.new(0)
    catalog_files(data_dir).each do |file|
      name = file.basename.to_s
      parts = file.basename(".json").to_s.split("-")
      if parts.length < 3 || parts[0] != prefix
        error("#{name}: unexpected JSON file in release catalog")
        next
      end
      build = parts[-1]
      filename_version = parts[1...-1].join("-")
      begin
        data = read_json(file, MAX_RELEASE_BYTES, data_dir.parent)
      rescue SystemCallError, ArgumentError, EncodingError, JSON::ParserError => e
        error("#{name}: invalid JSON — #{e.message}")
        next
      end
      unless data.is_a?(Hash)
        error("#{name}: top-level value should be object, got #{type_name(data)}")
        next
      end
      reject_control_characters(data, name)
      if catalog.key?(build)
        error("#{name}: duplicate buildNumber '#{build}' (already defined in #{catalog[build]['path'].basename})")
      end
      catalog[build] = { "path" => file, "data" => data }
      missing = product["required"].reject { |field| data.key?(field) }
      unless missing.empty?
        error("#{name}: missing fields: #{missing.join(', ')}")
        next
      end
      unexpected = data.keys.to_set - product["allowed"]
      error("#{name}: unexpected fields: #{unexpected.sort.join(', ')}") unless unexpected.empty?
      build_number = require_string(data, "buildNumber", name)
      os_version = require_string(data, "osVersion", name)
      release_date = require_string(data, "releaseDate", name)
      release_name = require_string(data, "releaseName", name)
      product_type = require_string(data, "productType", name)
      validate_product_type(product_type, product["name"], name)
      if build_number && build_number != build
        error("#{name}: buildNumber '#{build_number}' doesn't match filename '#{build}'")
      end
      if build_number && !BUILD_IDENTIFIER_RE.match?(build_number)
        error("#{name}: buildNumber '#{build_number}' is not a canonical Apple build identifier")
      end
      if os_version && !VERSION_RE.match?(os_version)
        error("#{name}: osVersion '#{os_version}' is not a valid version (X.Y or X.Y.Z)")
      end
      if os_version && os_version != filename_version
        error("#{name}: osVersion '#{os_version}' doesn't match filename '#{filename_version}'")
      end
      if os_version && release_name
        major = os_version.split(".", 2)[0]
        expected_name = prefix == "Xcode" ? "Xcode #{os_version}" : MACOS_RELEASE_NAMES.fetch(major, "macOS #{major}")
        error("#{name}: releaseName '#{release_name}' should be '#{expected_name}'") if release_name != expected_name
      end
      product["bool_fields"].each do |field|
        error("#{name}: #{field} should be bool, got #{type_name(data[field])}") unless boolean?(data[field])
      end
      %w[betaNumber betaRevision rcNumber].each do |field|
        error("#{name}: #{field} must be omitted instead of null") if data.key?(field) && data[field].nil?
      end
      is_beta = data["isBeta"]
      is_rc = data["isRC"]
      if boolean?(is_beta) && boolean?(is_rc)
        error("#{name}: isBeta and isRC are both true") if is_beta && is_rc
        if is_beta
          number = data["betaNumber"]
          if number.nil?
            warn("#{name}: isBeta is true but betaNumber is missing")
          elsif !number.is_a?(Integer) || number < 1
            error("#{name}: betaNumber should be a positive integer, got #{representation(number)}")
          end
          revision = data["betaRevision"]
          unless revision.nil?
            error("#{name}: betaRevision requires betaNumber") if number.nil?
            unless revision.is_a?(Integer) && revision >= 2
              error("#{name}: betaRevision should be an integer of 2 or greater, got #{representation(revision)}")
            end
          end
        elsif !data["betaNumber"].nil?
          error("#{name}: betaNumber set but isBeta is false")
        elsif !data["betaRevision"].nil?
          error("#{name}: betaRevision set but isBeta is false")
        end
        if is_rc
          number = data["rcNumber"]
          if !number.nil? && (!number.is_a?(Integer) || number < 1)
            error("#{name}: rcNumber should be a positive integer, got #{representation(number)}")
          end
        elsif !data["rcNumber"].nil?
          error("#{name}: rcNumber set but isRC is false")
        end
      end
      validate_date(release_date, "releaseDate", build) if release_date
      validate_ipsw(data, name, build, os_version) if prefix == "macOS"
      validate_xip(data, name, os_version, is_beta, is_rc) if prefix == "Xcode"
      validate_components(data, name, product, all_component_names)
      validate_kernels(data, name, build) if product["expect_kernels"]
    end
    if catalog.length > 10
      all_component_names.sort.each do |name, count|
        warn("#{prefix}: component '#{name}' only appears in #{count} release(s) — possible typo") if count < 3
      end
    end
  end

  def validate_ipsw(data, name, build, os_version)
    url = data["ipswURL"]
    ipsw_file = data["ipswFile"]
    validate_download_url(url, "ipswURL", name)
    if url.is_a?(String) && parsed_url(url)&.hostname&.downcase != "updates.cdn-apple.com"
      error("#{name}: ipswURL must use updates.cdn-apple.com")
    end
    if url.is_a?(String) && (url.include?("?") || url.include?("#"))
      error("#{name}: ipswURL must not contain a query or fragment")
    end
    error("#{name}: ipswFile is empty or not a string") unless string?(ipsw_file)
    if string?(url) && string?(ipsw_file)
      url_file = download_filename(url)
      error("#{name}: ipswFile '#{ipsw_file}' doesn't match URL filename '#{url_file}'") if ipsw_file != url_file
    end
    return unless string?(url)

    match = IPSW_FILE_RE.match(download_filename(url))
    unless match
      error("#{name}: ipswURL filename is not UniversalMac_<version>_<build>_Restore.ipsw")
      return
    end
    error("#{name}: build in ipswURL '#{match[2]}' doesn't match '#{build}'") if match[2] != build
    if os_version && match[1] != os_version
      error("#{name}: version in ipswURL '#{match[1]}' doesn't match '#{os_version}'")
    end
  end

  def validate_xip(data, name, os_version, is_beta, is_rc)
    xip_file = data.fetch("xipFile", "")
    error("#{name}: xipFile is empty or not a string") unless string?(xip_file)
    xip_url = data.fetch("xipURL", "")
    validate_download_url(xip_url, "xipURL", name)
    if xip_url.is_a?(String) && parsed_url(xip_url)&.hostname&.downcase != "developer.apple.com"
      error("#{name}: xipURL must use developer.apple.com")
    end
    if string?(xip_url) && string?(xip_file)
      url_file = download_filename(xip_url, query_parameter: "path")
      error("#{name}: xipFile '#{xip_file}' doesn't match URL filename '#{url_file}'") if xip_file != url_file
    end
    file_version = xcode_file_version(xip_file)
    if file_version.nil?
      error("#{name}: xipFile '#{xip_file}' is not canonical")
    else
      if os_version && file_version != os_version
        error("#{name}: version in xipFile '#{file_version}' doesn't match '#{os_version}'")
      end
      if boolean?(is_beta) && boolean?(is_rc) && !(is_beta && is_rc)
        label = xcode_file_label(xip_file)
        expected_label = is_beta ? "beta" : is_rc ? "Release_Candidate" : nil
        if label != expected_label
          error("#{name}: xipFile '#{xip_file}' is a #{label || 'stable'} archive " \
                "but isBeta=#{representation(is_beta)}, isRC=#{representation(is_rc)}")
        end
      end
    end
    error("#{name}: minimumOSVersion is empty or not a string") unless string?(data["minimumOSVersion"])
    sdks = data.fetch("sdks", [])
    unless sdks.is_a?(Array) && !sdks.empty?
      error("#{name}: sdks array is empty")
      return
    end
    seen = Set.new
    sdks.each_with_index do |sdk, index|
      unless sdk.is_a?(Hash)
        error("#{name}: sdks[#{index}] should be object, got #{type_name(sdk)}")
        next
      end
      version = require_string(sdk, "sdkVersion", "#{name}: sdks[#{index}]")
      if version
        error("#{name}: duplicate SDK version #{version.inspect}") if seen.include?(version)
        seen.add(version)
      end
      require_string(sdk, "buildVersion", "#{name}: sdks[#{index}]")
    end
  end

  def validate_components(data, filename, product, all_component_names)
    components = data["components"]
    unless components.is_a?(Array) && !components.empty?
      error("#{filename}: components array is empty")
      return
    end
    seen_names = Set.new
    components.each_with_index do |component, index|
      unless component.is_a?(Hash)
        error("#{filename}: components[#{index}] should be object, got #{type_name(component)}")
        next
      end
      COMPONENT_REQUIRED.each do |field|
        error("#{filename}: components[#{index}] missing field '#{field}'") unless component.key?(field)
      end
      name = component.fetch("name", "")
      if !string?(name)
        error("#{filename}: components[#{index}] has empty or non-string name")
      elsif seen_names.include?(name)
        error("#{filename}: duplicate component name '#{name}'")
      else
        seen_names.add(name)
        all_component_names[name] += 1
      end
      unless string?(component["version"])
        error("#{filename}: component '#{name}' has empty or non-string version")
      end
      path = component.fetch("path", "")
      if !string?(path)
        error("#{filename}: component '#{name}' has empty or non-string path")
      elsif !path.start_with?("/")
        error("#{filename}: component '#{name}' path '#{path}' is not absolute")
      end
      source = component.fetch("source", "")
      valid_sources = product["component_sources"]
      expected_sources = product["expected_component_sources"]
      if !source.is_a?(String) || !valid_sources.include?(source)
        error("#{filename}: component '#{name}' has invalid source '#{source}' " \
              "(expected: #{valid_sources.sort.join(', ')})")
      elsif name.is_a?(String) && expected_sources.key?(name) && source != expected_sources[name]
        error("#{filename}: component '#{name}' should come from '#{expected_sources[name]}', not '#{source}'")
      end
    end
    missing = product["expected_components"] - seen_names
    unexpected = seen_names - product["expected_components"]
    error("#{filename}: missing tracked components: #{missing.sort.join(', ')}") unless missing.empty?
    error("#{filename}: unconfigured components: #{unexpected.sort.join(', ')}") unless unexpected.empty?
  end

  def validate_kernels(data, name, build)
    kernels = data.fetch("kernels", [])
    unless kernels.is_a?(Array) && !kernels.empty?
      error("#{name}: kernels array is empty")
      return
    end
    kernels.each_with_index do |kernel, index|
      unless kernel.is_a?(Hash)
        error("#{name}: kernels[#{index}] should be object, got #{type_name(kernel)}")
        next
      end
      %w[arch chip darwinVersion xnuVersion file devices].each do |field|
        error("#{name}: kernels[#{index}] missing field '#{field}'") unless kernel.key?(field)
      end
      %w[arch chip file darwinVersion xnuVersion].each do |field|
        error("#{name}: kernels[#{index}] #{field} is empty or not a string") unless string?(kernel[field])
      end
      if kernel.key?("deviceChips")
        pairs = kernel["deviceChips"]
        unless pairs.is_a?(Array)
          error("#{name}: kernels[#{index}] deviceChips should be an array")
        else
          pairs.each_with_index do |pair, pair_index|
            context = "#{name}: kernels[#{index}] deviceChips[#{pair_index}]"
            unless pair.is_a?(Hash)
              error("#{context} should be an object")
              next
            end
            require_string(pair, "device", context)
            require_string(pair, "chip", context)
          end
        end
      end
      devices = kernel.fetch("devices", [])
      chip = kernel.fetch("chip", "")
      is_dtk = chip == "A12Z (DTK)"
      is_early_vm = chip == "Virtual Mac" && %w[21A5268h 21A5284e 21A5294g].include?(build)
      if !devices.is_a?(Array) || devices.empty?
        error("#{name}: kernels[#{index}] devices is empty") unless is_dtk || is_early_vm
      elsif !devices.all? { |device| string?(device) }
        error("#{name}: kernels[#{index}] devices contains empty or non-string entries")
      end
    end
  end

  def resolved_path(path)
    Pathname(path).realpath
  rescue Errno::ENOENT
    path = Pathname(path).expand_path
    return path if path.root?

    resolved_path(path.parent).join(path.basename).cleanpath
  end

  def validate_index(product, catalog)
    index_path = Pathname(product["index"])
    prefix = product["prefix"]
    unless index_path.exist?
      error("#{index_path} not found")
      return
    end
    begin
      entries = read_json(index_path, MAX_INDEX_BYTES, Pathname(product["data"]).parent)
    rescue SystemCallError, ArgumentError, EncodingError, JSON::ParserError => e
      error("#{index_path.basename}: invalid JSON — #{e.message}")
      return
    end
    unless entries.is_a?(Array)
      error("#{index_path.basename}: top-level value should be array, got #{type_name(entries)}")
      return
    end
    reject_control_characters(entries, "#{prefix} #{index_path.basename}")
    index_builds = {}
    valid_entries = []
    entries.each_with_index do |entry, index|
      unless entry.is_a?(Hash)
        error("#{prefix} index[#{index}]: should be object, got #{type_name(entry)}")
        next
      end
      build_number = entry.fetch("buildNumber", "")
      build = string?(build_number) ? build_number : "entry #{index}"
      context = "#{prefix} index/#{build}"
      allowed = product["index_required"].to_set | %w[betaNumber betaRevision rcNumber].to_set
      unexpected = entry.keys.to_set - allowed
      error("#{context}: unexpected fields: #{unexpected.sort.join(', ')}") unless unexpected.empty?
      %w[betaNumber betaRevision rcNumber].each do |field|
        minimum = field == "betaRevision" ? 2 : 1
        if entry.key?(field) && (!entry[field].is_a?(Integer) || entry[field] < minimum)
          error("#{context}: #{field} must be a valid integer when present")
        end
      end
      missing = product["index_required"].reject { |field| entry.key?(field) }
      unless missing.empty?
        error("#{context}: missing fields: #{missing.join(', ')}")
        next
      end
      build_number = require_string(entry, "buildNumber", context)
      os_version = require_string(entry, "osVersion", context)
      release_date = require_string(entry, "releaseDate", context)
      require_string(entry, "releaseName", context)
      product_type = require_string(entry, "productType", context)
      data_file = require_string(entry, "dataFile", context)
      validate_product_type(product_type, product["name"], context)
      product["bool_fields"].each do |field|
        if entry.key?(field) && !boolean?(entry[field])
          error("#{context}: #{field} should be bool, got #{type_name(entry[field])}")
        end
      end
      if os_version && !VERSION_RE.match?(os_version)
        error("#{context}: osVersion '#{os_version}' is not a valid version (X.Y or X.Y.Z)")
      end
      validate_date(release_date, "releaseDate", context) if release_date
      next unless build_number

      unless BUILD_IDENTIFIER_RE.match?(build_number)
        error("#{context}: buildNumber '#{build_number}' is not a canonical Apple build identifier")
      end
      error("#{prefix} index: duplicate buildNumber '#{build}'") if index_builds.key?(build_number)
      index_builds[build_number] = entry
      valid_entries << entry
      next unless data_file && os_version

      major = os_version.split(".", 2)[0]
      expected_data_file = "releases/#{major}/#{prefix}-#{os_version}-#{build_number}.json"
      if data_file != expected_data_file
        error("#{context}: dataFile '#{data_file}' should be '#{expected_data_file}'")
      end
      begin
        product_root = resolved_path(Pathname(product["data"]).parent)
        candidate = resolved_path(product_root.join(data_file))
        relative = candidate.relative_path_from(product_root)
        if relative.each_filename.first == ".."
          error("#{context}: dataFile '#{data_file}' escapes #{product_root}")
        elsif !candidate.file?
          error("#{context}: dataFile '#{data_file}' does not exist")
        elsif catalog.key?(build_number) && candidate != resolved_path(catalog[build_number]["path"])
          error("#{context}: dataFile '#{data_file}' does not identify build '#{build_number}'")
        end
      rescue SystemCallError, ArgumentError => e
        error("#{context}: dataFile '#{data_file}' cannot be resolved — #{e.message}")
      end
    end
    catalog_builds = catalog.keys.to_set
    index_build_set = index_builds.keys.to_set
    (catalog_builds - index_build_set).sort.each do |build|
      error("#{build}: in #{product['data']} but missing from #{index_path.basename}")
    end
    (index_build_set - catalog_builds).sort.each do |build|
      error("#{build}: in #{index_path.basename} but no matching JSON file")
    end
    (catalog_builds & index_build_set).each do |build|
      release = catalog[build]["data"]
      entry = index_builds[build]
      product["parity_fields"].each do |field|
        # Ruby numeric equality also accepts 2.0 for 2; require identical types.
        next if entry[field].class == release[field].class && entry[field] == release[field]

        error("#{prefix} index/#{build}: #{field} mismatch — " \
              "index=#{representation(entry[field])}, file=#{representation(release[field])}")
      end
    end
    return unless valid_entries.length > 1

    expected_builds = sorted_releases(valid_entries).map { |entry| entry["buildNumber"] }
    actual_builds = valid_entries.map { |entry| entry["buildNumber"] }
    actual_builds.zip(expected_builds).each_with_index do |(actual, expected), index|
      next if actual == expected

      error("#{prefix} #{index_path.basename} sort order: position #{index} has #{actual}, expected #{expected}")
      break
    end
  end

  def main(products: PRODUCTS)
    results = []
    products.each do |product|
      unless Pathname(product["data"]).exist?
        error("required #{product['name']} catalog #{product['data']} not found")
        next
      end
      catalog = {}
      validate_releases(product, catalog)
      validate_index(product, catalog)
      results << [product["name"], catalog.length]
    end
    if errors.positive?
      summary = results.map { |name, count| "#{count} #{name}" }.join(", ")
      $stderr.puts "\n#{errors} error(s) in #{summary} release files"
      return 1
    end
    parts = results.map { |name, count| "#{count} #{name}" }
    puts "OK: #{parts.join(' + ')} release files validated"
    0
  end
end

exit LintJson.main if $PROGRAM_NAME == __FILE__
