# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative '../verify-release-artifact'

module ReleaseArtifactFixture
  include WorkflowHelpers
  def setup
    @root = Dir.mktmpdir
    @previous_directory = Dir.pwd
    Dir.chdir(@root)
    FileUtils.mkdir_p("data/#{product}")
    @base_entry = {
      'productType' => prefix, 'osVersion' => '26.0', 'buildNumber' => product == 'macos' ? '25A354' : '17A1',
      'releaseName' => product == 'macos' ? 'Tahoe' : 'Xcode 26.0',
      'releaseDate' => product == 'macos' ? '2025-09-15' : '2025-09-01', 'isBeta' => false, 'isRC' => false,
      'dataFile' => "releases/26/#{prefix}-26.0-#{product == 'macos' ? '25A354' : '17A1'}.json"
    }
    @base_entry['isDeviceSpecific'] = false if product == 'macos'
    File.write(index_path, JSON.generate([@base_entry]))
  end

  def teardown
    Dir.chdir(@previous_directory)
    FileUtils.remove_entry(@root)
  end

  def prefix = product == 'macos' ? 'macOS' : 'Xcode'
  def build = product == 'macos' ? '25B78' : '17B54'
  def index_path = "data/#{product}/releases.json"
  def detail_path = "data/#{product}/releases/26/#{prefix}-26.1-#{build}.json"

  def source_url
    if product == 'macos'
      'https://updates.cdn-apple.com/2025FallFCS/fullrestores/UniversalMac_26.1_25B78_Restore.ipsw'
    else
      'https://developer.apple.com/services-account/download?path=/Developer_Tools/Xcode_26.1/Xcode_26.1.xip'
    end
  end

  def arguments(**overrides)
    {
      artifact: File.join(@root, 'release-json.tgz'), product: product, source_url: source_url,
      build_number: product == 'macos' ? '' : build, release_date: '2025-11-03',
      run_started_at: '2025-11-04T01:00:00Z', beta: 'false', beta_number: '', beta_revision: '',
      rc: 'false', rc_number: '', device_specific: 'false', github_output: nil, replace: false
    }.merge(overrides)
  end

  def write_artifact(release_overrides: {}, base_index: [@base_entry])
    detail = {
      'productType' => prefix, 'osVersion' => '26.1', 'buildNumber' => build,
      'releaseName' => product == 'macos' ? 'Tahoe' : 'Xcode 26.1', 'releaseDate' => '2025-11-03',
      'isBeta' => false, 'isRC' => false, 'components' => []
    }
    if product == 'macos'
      detail.merge!('isDeviceSpecific' => false, 'ipswFile' => 'UniversalMac_26.1_25B78_Restore.ipsw',
                    'ipswURL' => source_url, 'kernels' => [])
    else
      detail.merge!('xipFile' => 'Xcode_26.1.xip', 'xipURL' => source_url, 'sdks' => [], 'minimumOSVersion' => '15.6')
    end
    detail.merge!(release_overrides)
    fields = %w[productType osVersion buildNumber releaseName releaseDate isBeta betaNumber betaRevision isRC rcNumber isDeviceSpecific]
    entry = detail.select { |key, _| fields.include?(key) }
    entry['dataFile'] = "releases/26/#{prefix}-26.1-#{build}.json"
    members = { index_path => JSON.generate([entry, *base_index]), detail_path => JSON.generate(detail) }
    write_tar(members)
    members
  end

  def write_tar(members)
    Zlib::GzipWriter.open(arguments.fetch(:artifact)) do |gzip|
      Gem::Package::TarWriter.new(gzip) do |archive|
        members.each do |name, data|
          archive.add_file_simple(name, 0o644, data.bytesize) { |file| file.write(data) }
        end
      end
    end
  end

  def assert_verification_error(pattern)
    assert_match(pattern, assert_raises(VerifyReleaseArtifact::VerificationError) { yield }.message)
  end

  def fail_index_write
    original = VerifyReleaseArtifact.method(:atomic_write)
    target = index_path
    VerifyReleaseArtifact.define_singleton_method(:atomic_write) do |path, data|
      raise IOError, 'injected index write failure' if path == target

      original.call(path, data)
    end
    yield
  ensure
    VerifyReleaseArtifact.define_singleton_method(:atomic_write, original)
  end
end

class VerifyReleaseArtifactTests < Minitest::Test
  include ReleaseArtifactFixture

  def product = 'xcode'

  def test_exact_one_release_addition_is_overlaid
    write_artifact
    basename, source, date = VerifyReleaseArtifact.verify_and_overlay(arguments)
    assert_equal('Xcode-26.1-17B54', basename)
    assert_includes(source, 'Xcode_26.1.xip')
    assert_equal('2025-11-03', date)
    assert_path_exists(detail_path)
  end

  def test_artifact_cannot_replace_the_trusted_base_index
    write_artifact(base_index: [])
    assert_verification_error(/one-release addition/) { VerifyReleaseArtifact.verify_and_overlay(arguments) }
  end

  def test_detail_must_match_dispatch_prerelease_fields
    write_artifact(release_overrides: { 'isBeta' => true, 'betaNumber' => 2 })
    assert_verification_error(/isBeta/) { VerifyReleaseArtifact.verify_and_overlay(arguments) }
  end

  def test_dispatch_binding_preserves_json_scalar_types
    %w[isBeta isRC].each do |field|
      write_artifact(release_overrides: { field => 0 })
      assert_verification_error(/#{field}/) { VerifyReleaseArtifact.verify_and_overlay(arguments) }
      refute_path_exists(detail_path)
    end
  end

  def test_artifact_rejects_entries_beyond_the_exact_pair
    members = write_artifact
    write_tar(members.merge('unexpected.txt' => 'unexpected'))
    assert_verification_error(/exactly two entries/) { VerifyReleaseArtifact.verify_and_overlay(arguments) }
  end

  def test_default_date_is_bound_to_trusted_run_start
    assert_equal('2025-11-03', VerifyReleaseArtifact.resolve_release_date('', '2025-11-04T07:30:00Z'))
    assert_equal('2025-07-01', VerifyReleaseArtifact.resolve_release_date('', '2025-07-02T06:30:00Z'))
  end

  def test_rejects_noncanonical_or_invalid_dates
    %w[2025-1-01 2025-02-29 2025-11-03x 0000-01-01].each do |date|
      assert_verification_error(/release_date/) { VerifyReleaseArtifact.resolve_release_date(date, '') }
    end
    assert_verification_error(/run_started_at/) { VerifyReleaseArtifact.resolve_release_date('', 'not-a-date') }
  end

  def test_release_dates_use_the_proleptic_gregorian_calendar
    %w[0001-01-01 1582-10-10 1600-02-29 9999-12-31].each do |date|
      assert_equal(date, VerifyReleaseArtifact.resolve_release_date(date, ''))
    end
    %w[1500-02-29 0000-01-01 10000-01-01].each do |date|
      assert_verification_error(/release_date/) { VerifyReleaseArtifact.resolve_release_date(date, '') }
    end
  end

  def test_major_only_xcode_filenames_normalize_to_dot_zero
    source = VerifyReleaseArtifact.expected_source('xcode',
      'https://developer.apple.com/services-account/download?path=/Developer_Tools/Xcode_26/Xcode_26_Universal.xip', '17A324')
    assert_equal('26.0', source.fetch('version'))
  end

  def test_artifact_json_rejects_duplicate_keys_and_nonfinite_numbers
    assert_verification_error(/duplicate JSON key/) do
      VerifyReleaseArtifact.load_json_strict('{"field": 1, "field": 2}', 'fixture')
    end
    ['NaN', 'Infinity', '-Infinity'].each do |number|
      assert_verification_error(/non-finite JSON number/) do
        VerifyReleaseArtifact.load_json_strict("{\"field\": #{number}}", 'fixture')
      end
    end
    assert_verification_error(/duplicate JSON key/) do
      VerifyReleaseArtifact.load_json_strict('{"nested": {"x": 1, "x": 2}}', 'fixture')
    end
  end

  def test_artifact_json_rejects_invalid_utf8
    assert_verification_error(/JSON is malformed/) do
      VerifyReleaseArtifact.load_json_strict("{\"field\": \"\xFF\"}".b, 'fixture')
    end
  end

  def test_artifact_json_preserves_unicode_byte_encodings
    json = JSON.generate('field' => "café 😀\u0000")
    %w[UTF-8 UTF-16BE UTF-16LE UTF-32BE UTF-32LE].each do |encoding|
      bytes = json.encode(encoding).b
      assert_equal({ 'field' => "café 😀\u0000" }, VerifyReleaseArtifact.load_json_strict(bytes, 'fixture'), encoding)
      bom = "\uFEFF".encode(encoding).b
      assert_equal({ 'field' => "café 😀\u0000" }, VerifyReleaseArtifact.load_json_strict(bom + bytes, 'fixture'), encoding)
    end
    ["\0".b, "\xff\xfe{\0\xff".b, '{"field": "\ud800"}'].each do |bytes|
      assert_verification_error(/JSON is malformed/) { VerifyReleaseArtifact.load_json_strict(bytes, 'fixture') }
    end
  end

  def test_prerelease_inference_and_conflicts
    assert_equal(true, VerifyReleaseArtifact.expected_prerelease(arguments(product: 'macos'), '25A1a')['isBeta'])
    assert_equal(false, VerifyReleaseArtifact.expected_prerelease(arguments(product: 'macos', rc: 'true'), '25A1a')['isBeta'])
    assert_verification_error(/both beta and RC/) do
      VerifyReleaseArtifact.expected_prerelease(arguments(beta: 'true', rc: 'true'), build)
    end
    assert_verification_error(/requires beta_number/) do
      VerifyReleaseArtifact.expected_prerelease(arguments(beta_revision: '2'), build)
    end
    assert_verification_error(/at least 2/) do
      VerifyReleaseArtifact.expected_prerelease(arguments(beta_number: '1', beta_revision: '1'), build)
    end
  end

  def test_artifact_rejects_symlinks_duplicate_names_and_unsafe_paths
    Zlib::GzipWriter.open(arguments.fetch(:artifact)) do |gzip|
      Gem::Package::TarWriter.new(gzip) { |tar| tar.add_symlink(index_path, '/tmp/outside', 0o644) }
    end
    assert_verification_error(/not a regular file/) { VerifyReleaseArtifact.verify_and_overlay(arguments) }
    write_tar([[index_path, '[]'], [index_path, '[]']])
    assert_verification_error(/duplicate artifact entry/) { VerifyReleaseArtifact.verify_and_overlay(arguments) }
    write_tar([['../outside', 'bad']])
    assert_verification_error(/unsafe artifact path/) { VerifyReleaseArtifact.verify_and_overlay(arguments) }
  end

  def test_artifact_rejects_bad_header_checksums_and_truncated_members
    write_artifact
    tar = Zlib::GzipReader.open(arguments.fetch(:artifact), &:read)
    tar.setbyte(0, tar.getbyte(0) ^ 1)
    Zlib::GzipWriter.open(arguments.fetch(:artifact)) { |gzip| gzip.write(tar) }
    assert_verification_error(/checksum/) { VerifyReleaseArtifact.verify_and_overlay(arguments) }
    write_artifact
    tar = Zlib::GzipReader.open(arguments.fetch(:artifact), &:read)
    Zlib::GzipWriter.open(arguments.fetch(:artifact)) { |gzip| gzip.write(tar.byteslice(0, 520)) }
    assert_verification_error(/size changed/) { VerifyReleaseArtifact.verify_and_overlay(arguments) }
  end

  def write_raw_tar(members)
    Zlib::GzipWriter.open(arguments.fetch(:artifact)) do |gzip|
      members.each do |name, type, payload, size|
        header = Gem::Package::TarHeader.new(name: name, prefix: '', typeflag: type,
                                             size: size || payload.bytesize, mode: 0o644)
        gzip.write(header.to_s)
        gzip.write(payload)
        gzip.write("\0" * ((512 - payload.bytesize % 512) % 512))
      end
      gzip.write("\0" * 1024)
    end
  end

  def pax_record(key, value)
    body = " #{key}=#{value}\n"
    size = body.bytesize + 1
    size = body.bytesize + size.to_s.bytesize until size == body.bytesize + size.to_s.bytesize
    "#{size}#{body}"
  end

  def test_pax_metadata_keeps_exact_logical_entry_identity
    members = write_artifact
    write_raw_tar([
      ['PaxHeader', 'x', pax_record('path', index_path)],
      ['placeholder', '0', members.fetch(index_path)],
      [detail_path, '0', members.fetch(detail_path)]
    ])
    assert_equal(members.values, VerifyReleaseArtifact.read_artifact(arguments.fetch(:artifact), index_path, detail_path))
    write_raw_tar([
      ['PaxHeader', 'x', pax_record('path', '../escape')], ['placeholder', '0', '[]']
    ])
    assert_verification_error(/unsafe artifact path/) { VerifyReleaseArtifact.verify_and_overlay(arguments) }
  end

  def test_artifact_checks_declared_member_and_metadata_sizes_before_reading
    write_raw_tar([[index_path, '0', '', VerifyReleaseArtifact::MAX_MEMBER_SIZE + 1]])
    assert_verification_error(/entry is too large/) { VerifyReleaseArtifact.verify_and_overlay(arguments) }
    write_raw_tar([['PaxHeader', 'x', '', VerifyReleaseArtifact::MAX_METADATA_SIZE + 1]])
    assert_verification_error(/metadata is too large/) { VerifyReleaseArtifact.verify_and_overlay(arguments) }
  end

  def gzip_bytes(bytes)
    stream = StringIO.new(''.b)
    gzip = Zlib::GzipWriter.new(stream)
    gzip.write(bytes)
    gzip.finish
    stream.string
  end

  def test_artifact_rejects_entries_hidden_in_a_second_gzip_member
    members = write_artifact
    original_gzip = File.binread(arguments.fetch(:artifact))
    tar = Zlib::GzipReader.open(arguments.fetch(:artifact), &:read)
    pair_size = members.values.sum { |data| 512 + ((data.bytesize + 511) / 512) * 512 }
    write_tar('unexpected.txt' => 'unexpected')
    extra_gzip = File.binread(arguments.fetch(:artifact))
    [gzip_bytes(tar.byteslice(0, pair_size)), original_gzip].each do |prefix|
      File.binwrite(arguments.fetch(:artifact), prefix + extra_gzip)
      assert_verification_error(/concatenated gzip/) { VerifyReleaseArtifact.verify_and_overlay(arguments) }
      refute_path_exists(detail_path)
    end
  end

  class GzipBoundaryIO < StringIO
    def initialize(data, boundary)
      super(data)
      @boundary = boundary
    end

    def readpartial(length, buffer = nil)
      length = [length, @boundary - pos].min if pos < @boundary
      super(length, buffer)
    end
  end

  def test_gzip_rejects_unread_bytes_when_unused_buffer_is_empty
    write_artifact
    first_member = File.binread(arguments.fetch(:artifact))
    raw = GzipBoundaryIO.new(first_member + gzip_bytes('extra member'), first_member.bytesize)
    archive = Zlib::GzipReader.new(raw)
    archive.read
    assert_nil(archive.unused)
    assert_equal(first_member.bytesize, raw.pos)
    refute(raw.eof?)
    assert_verification_error(/trailing compressed data/) { VerifyReleaseArtifact.verify_gzip_end(archive) }
  ensure
    archive&.finish
  end

  def test_artifact_rejects_trailing_compressed_and_uncompressed_data
    write_artifact
    original_gzip = File.binread(arguments.fetch(:artifact))
    tar = Zlib::GzipReader.open(arguments.fetch(:artifact), &:read)
    File.binwrite(arguments.fetch(:artifact), original_gzip + 'trailing bytes')
    assert_verification_error(/trailing compressed data/) { VerifyReleaseArtifact.verify_and_overlay(arguments) }
    File.binwrite(arguments.fetch(:artifact), gzip_bytes(tar + 'trailing bytes'))
    assert_verification_error(/trailing tar data/) { VerifyReleaseArtifact.verify_and_overlay(arguments) }
  end

  def test_artifact_validates_gzip_crc_and_bounds_trailing_padding
    write_artifact
    compressed = File.binread(arguments.fetch(:artifact))
    compressed.setbyte(compressed.bytesize - 8, compressed.getbyte(compressed.bytesize - 8) ^ 1)
    File.binwrite(arguments.fetch(:artifact), compressed)
    assert_verification_error(/malformed/) { VerifyReleaseArtifact.verify_and_overlay(arguments) }
    write_artifact
    tar = Zlib::GzipReader.open(arguments.fetch(:artifact), &:read)
    File.binwrite(arguments.fetch(:artifact), gzip_bytes(tar + "\0" * VerifyReleaseArtifact::MAX_TAR_PADDING))
    assert_verification_error(/trailing tar data/) { VerifyReleaseArtifact.verify_and_overlay(arguments) }
  end

  def test_artifact_rejects_comments_before_any_overlay
    members = write_artifact
    ['/* injected */ ', "// injected\n"].each do |comment|
      write_tar(members.merge(detail_path => comment + members.fetch(detail_path)))
      assert_verification_error(/comments/) { VerifyReleaseArtifact.verify_and_overlay(arguments) }
      refute_path_exists(detail_path)
    end
  end

  def test_reports_unsupported_duplicate_key_parser_explicitly
    supported = StrictJSON::DUPLICATE_KEYS_REJECTED
    StrictJSON.send(:remove_const, :DUPLICATE_KEYS_REJECTED)
    StrictJSON.const_set(:DUPLICATE_KEYS_REJECTED, false)
    error = assert_raises(VerifyReleaseArtifact::VerificationError) do
      VerifyReleaseArtifact.load_json_strict('{}', 'release detail')
    end
    assert_equal('Ruby JSON parser cannot reject duplicate keys; update Ruby', error.message)
  ensure
    StrictJSON.send(:remove_const, :DUPLICATE_KEYS_REJECTED)
    StrictJSON.const_set(:DUPLICATE_KEYS_REJECTED, supported)
  end

  def assert_safe_tar_diagnostic(error)
    assert_equal(1, error.message.lines.length)
    assert_operator(error.message.bytesize, :<, 600)
    assert(error.message.ascii_only?)
    refute_includes(error.message, "\n::warning::")
    refute_includes(error.message, '##[')
  end

  def test_tar_entry_names_are_escaped_and_bounded_in_diagnostics
    name = "entry##[error]forged legacy annotation\n::warning::forged annotation\r\e[31m"
    [[name, '0'], ["../#{name}", '0'], [name, '2']].each do |entry, type|
      write_raw_tar([[entry, type, '{}']])
      error = assert_raises(VerifyReleaseArtifact::VerificationError) do
        VerifyReleaseArtifact.verify_and_overlay(arguments)
      end
      assert_safe_tar_diagnostic(error)
      assert_includes(error.message, '\n::warning::')
      assert_includes(error.message, '## [error]')
    end
    long_name = "#{name}#{'x' * 4096}"
    write_raw_tar([['PaxHeader', 'x', pax_record('path', long_name)], ['placeholder', '0', '{}']])
    error = assert_raises(VerifyReleaseArtifact::VerificationError) do
      VerifyReleaseArtifact.verify_and_overlay(arguments)
    end
    assert_safe_tar_diagnostic(error)
    assert(error.message.end_with?('...'))
  end

  def test_tar_payload_diagnostics_escape_untrusted_metadata_names
    ['', 'a'].each do |payload|
      error = assert_raises(VerifyReleaseArtifact::VerificationError) do
        VerifyReleaseArtifact.read_tar_payload(StringIO.new(payload), 1, "metadata\n::warning::forged")
      end
      assert_safe_tar_diagnostic(error)
      assert_includes(error.message, '\n::warning::')
    end
  end

  def test_tar_header_parser_diagnostic_is_fixed
    header = Gem::Package::TarHeader.new(name: index_path, prefix: '', size: 0, mode: 0o644).to_s
    header[100, 8] = "bad\nmode"
    File.binwrite(arguments.fetch(:artifact), gzip_bytes(header + "\0" * 1024))
    error = assert_raises(VerifyReleaseArtifact::VerificationError) do
      VerifyReleaseArtifact.verify_and_overlay(arguments)
    end
    assert_equal('artifact tar is malformed', error.message)
  end

  def test_newline_tar_entry_cannot_emit_a_workflow_warning
    write_raw_tar([["unexpected##[error]forged legacy annotation\n::warning::forged annotation", '0', '{}']])
    original_artifact = File.binread(arguments.fetch(:artifact))
    script = File.expand_path('../verify-release-artifact.rb', __dir__)
    stdout, stderr, status = Open3.capture3(
      { 'RUBYOPT' => nil }, RbConfig.ruby, script, '--artifact', arguments.fetch(:artifact),
      '--product', product, '--source-url', source_url, '--build-number', build,
      '--release-date', '2025-11-03', '--beta', 'false', '--rc', 'false', chdir: @root
    )
    refute(status.success?)
    assert_empty(stdout)
    annotation_lines = stderr.lines.grep(/^::/)
    assert_equal(1, annotation_lines.length)
    assert(annotation_lines.first.start_with?('::error::unexpected or duplicate artifact entry: '))
    assert_includes(annotation_lines.first, '\n::warning::')
    assert_includes(annotation_lines.first, '## [error]')
    refute_includes(stderr, '##[')
    assert_equal(original_artifact, File.binread(arguments.fetch(:artifact)))
    refute_path_exists(detail_path)
  end

  def test_json_error_diagnostics_do_not_echo_untrusted_input
    dangerous = "\n::warning::forged annotation\n" + ('x' * 128 * 1024)
    malformed = '{"field": ' + dangerous
    huge_key = JSON.generate(dangerous)
    duplicate = "{#{huge_key}:1,#{huge_key}:2}"
    [[malformed, 'input JSON is malformed'], [duplicate, 'input contains duplicate JSON keys']].each do |source, expected|
      error = assert_raises(VerifyReleaseArtifact::VerificationError) do
        VerifyReleaseArtifact.load_json_strict(source, dangerous)
      end
      assert_equal(expected, error.message)
      assert_equal(1, error.message.lines.length)
      assert_operator(error.message.bytesize, :<, 100)
    end
  end

  def test_malformed_artifact_cli_emits_one_fixed_error_line
    members = write_artifact
    source = "{\n::warning::forged annotation\n" + 'x' * (128 * 1024)
    write_tar(members.merge(detail_path => source))
    script = File.expand_path('../verify-release-artifact.rb', __dir__)
    stdout, stderr, status = Open3.capture3(
      { 'RUBYOPT' => nil }, RbConfig.ruby, script, '--artifact', arguments.fetch(:artifact),
      '--product', product, '--source-url', source_url, '--build-number', build,
      '--release-date', '2025-11-03', '--beta', 'false', '--rc', 'false', chdir: @root
    )
    refute(status.success?)
    assert_empty(stdout)
    assert_equal(["::error::release detail JSON is malformed\n"], stderr.lines.grep(/^::/))
    refute_includes(stderr, 'forged annotation')
    assert_operator(stderr.bytesize, :<, 4096)
    refute_path_exists(detail_path)
  end

  def test_cli_accepts_utf8_paths_without_a_utf8_locale
    write_artifact
    artifact = File.join(@root, 'café.tgz')
    output = File.join(@root, 'résultat.txt')
    File.rename(arguments.fetch(:artifact), artifact)
    script = File.expand_path('../verify-release-artifact.rb', __dir__)
    result = c_locale_ruby(
      script, '--artifact', artifact, '--product', product, '--source-url', source_url,
      '--build-number', build, '--release-date', '2025-11-03', '--beta', 'false', '--rc', 'false',
      '--github-output', output, chdir: @root
    )
    assert(result.success?, "#{result.stdout}\n#{result.stderr}")
    assert_includes(File.read(output, encoding: 'utf-8'), 'basename=Xcode-26.1-17B54')
  end

  def test_artifact_accepts_the_scanner_tar_command
    members = write_artifact
    members.each do |name, data|
      FileUtils.mkdir_p(File.dirname(name))
      File.binwrite(name, data)
    end
    command = ['/usr/bin/tar']
    command.concat(%w[--no-mac-metadata --no-xattrs]) if RUBY_PLATFORM.include?('darwin')
    assert(system(*command, '-czf', arguments.fetch(:artifact), *members.keys))
    assert_equal(members.values, VerifyReleaseArtifact.read_artifact(arguments.fetch(:artifact), index_path, detail_path))
  end
end

class VerifyMacOSReleaseArtifactTests < Minitest::Test
  include ReleaseArtifactFixture

  def product = 'macos'

  def test_exact_macos_addition_is_bound_and_overlaid
    write_artifact
    assert_equal(['macOS-26.1-25B78', source_url, '2025-11-03'], VerifyReleaseArtifact.verify_and_overlay(arguments))
  end

  def test_ipsw_source_rejects_a_trailing_path_separator
    assert_equal('UniversalMac_26.1_25B78_Restore.ipsw', VerifyReleaseArtifact.expected_source('macos', source_url, '').fetch('file'))
    ['/', '//', '/?download=1', '/#fragment'].each do |suffix|
      assert_verification_error(/filename is not canonical/) do
        VerifyReleaseArtifact.expected_source('macos', source_url + suffix, '')
      end
    end
  end

  def verify_source_url_cli(url)
    script = File.expand_path('../verify-release-artifact.rb', __dir__)
    invoke = lambda do
      c_locale_ruby(
        script, '--artifact', arguments.fetch(:artifact), '--product', product,
        '--source-url', url, '--release-date', '2025-11-03', '--beta', 'false', '--rc', 'false',
        env: { 'RUBYOPT' => nil }, chdir: @root
      )
    end
    defined?(Bundler) ? Bundler.with_unbundled_env(&invoke) : invoke.call
  end

  def assert_source_url_cli_rejection(url, message)
    write_artifact(release_overrides: { 'ipswURL' => url })
    original_index = File.binread(index_path)
    original_artifact = File.binread(arguments.fetch(:artifact))
    result = verify_source_url_cli(url)
    assert_equal(1, result.returncode, url)
    assert_empty(result.stdout, url)
    assert_equal("::error::#{message}\n", result.stderr, url)
    assert_equal(original_index, File.binread(index_path))
    assert_equal(original_artifact, File.binread(arguments.fetch(:artifact)))
    refute_path_exists(detail_path)
    error = assert_raises(VerifyReleaseArtifact::VerificationError) do
      VerifyReleaseArtifact.expected_source('macos', url, '')
    end
    assert_equal(message, error.message)
  end

  def test_ipsw_source_cli_rejects_malformed_percent_decoded_filenames
    %w[%FF %80 %C0%AF %C3 %ED%A0%80 %F4%90%80%80].each do |bytes|
      url = source_url.sub('UniversalMac_', "#{bytes}UniversalMac_")
      assert_source_url_cli_rejection(url, 'IPSW source filename is not canonical')
    end
  end

  def test_ipsw_source_cli_rejects_empty_and_nonempty_userinfo
    ['', 'user', 'user:password', ':', ':password', 'user:', '%75ser', '%40'].each do |userinfo|
      url = source_url.sub('https://', "https://#{userinfo}@")
      assert_source_url_cli_rejection(url, 'IPSW source must be an updates.cdn-apple.com HTTPS URL')
    end
  end

  def test_ipsw_source_preserves_valid_canonical_filename_urls
    urls = [
      source_url,
      source_url.sub('https://updates.cdn-apple.com', 'HTTPS://UPDATES.CDN-APPLE.COM:443'),
      source_url.sub('/2025FallFCS/', '/@2025FallFCS/'),
      source_url + '?name=user@example.com#fragment@value',
      source_url.sub('UniversalMac_', '%55niversalMac_')
    ]
    urls.each do |url|
      assert_equal({ 'version' => '26.1', 'build' => build, 'file' => 'UniversalMac_26.1_25B78_Restore.ipsw',
                     'url' => url }, VerifyReleaseArtifact.expected_source('macos', url, ''), url)
    end
  end

  def test_ipsw_source_cli_accepts_the_canonical_url
    write_artifact
    result = verify_source_url_cli(source_url)
    assert(result.success?, result.stderr)
    assert_empty(result.stderr)
    assert_equal("Verified macOS-26.1-25B78 as an exact one-release addition to trusted main.\n", result.stdout)
    assert_path_exists(detail_path)
  end

  def test_macos_source_and_device_flag_must_match_dispatch
    write_artifact(release_overrides: { 'ipswURL' => "#{source_url}?changed=true" })
    assert_verification_error(/ipswURL/) { VerifyReleaseArtifact.verify_and_overlay(arguments) }
    write_artifact(release_overrides: { 'isDeviceSpecific' => true })
    assert_verification_error(/isDeviceSpecific/) { VerifyReleaseArtifact.verify_and_overlay(arguments) }
  end

  def test_published_release_is_replaced_only_in_replace_mode
    write_artifact
    VerifyReleaseArtifact.verify_and_overlay(arguments)
    rescanned = [{ 'name' => 'curl', 'version' => '8.7.1', 'path' => '/usr/bin/curl', 'source' => 'filesystem' }]
    write_artifact(release_overrides: { 'components' => rescanned })
    assert_verification_error(/already exists/) { VerifyReleaseArtifact.verify_and_overlay(arguments) }
    VerifyReleaseArtifact.verify_and_overlay(arguments(replace: true))
    assert_equal(rescanned, JSON.parse(File.read(detail_path)).fetch('components'))
  end

  def test_failed_index_write_restores_the_original_detail_bytes
    write_artifact
    VerifyReleaseArtifact.verify_and_overlay(arguments)
    original_detail = "\n#{File.binread(detail_path)}\n"
    File.binwrite(detail_path, original_detail)
    original_index = File.binread(index_path)
    write_artifact(release_overrides: { 'components' => [{ 'name' => 'changed' }] })
    fail_index_write do
      assert_match(/injected index write failure/, assert_raises(IOError) do
        VerifyReleaseArtifact.verify_and_overlay(arguments(replace: true))
      end.message)
    end
    assert_equal(original_detail, File.binread(detail_path))
    assert_equal(original_index, File.binread(index_path))
  end

  def test_failed_addition_removes_only_the_new_detail
    write_artifact
    original_index = File.binread(index_path)
    fail_index_write do
      assert_match(/injected index write failure/, assert_raises(IOError) do
        VerifyReleaseArtifact.verify_and_overlay(arguments)
      end.message)
    end
    refute_path_exists(detail_path)
    assert_equal(original_index, File.binread(index_path))
  end

  def test_replace_requires_a_published_release
    write_artifact
    assert_verification_error(/missing from the trusted base/) do
      VerifyReleaseArtifact.verify_and_overlay(arguments(replace: true))
    end
  end

  def test_replace_cannot_change_other_releases
    write_artifact
    VerifyReleaseArtifact.verify_and_overlay(arguments)
    @base_entry['releaseDate'] = '2025-09-16'
    write_artifact
    assert_verification_error(/one-release replacement/) do
      VerifyReleaseArtifact.verify_and_overlay(arguments(replace: true))
    end
  end

  def test_macos_release_name_is_derived_from_the_dispatched_version
    write_artifact(release_overrides: { 'releaseName' => 'Not Tahoe' })
    assert_verification_error(/release name/) { VerifyReleaseArtifact.verify_and_overlay(arguments) }
  end
end
