# frozen_string_literal: true

require 'fileutils'
require_relative 'test_helper'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative '../resolve-rescan'

class ResolveRescanTests < Minitest::Test
  include WorkflowHelpers
  REPO_ROOT = File.expand_path('../..', __dir__)

  def setup
    @root = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def publish(**overrides)
    detail = {
      'productType' => 'macOS', 'osVersion' => '12.3', 'buildNumber' => '21E230',
      'releaseDate' => '2022-03-14', 'isBeta' => false, 'isRC' => false, 'isDeviceSpecific' => false,
      'ipswURL' => 'https://updates.cdn-apple.com/2022/UniversalMac_12.3_21E230_Restore.ipsw'
    }.merge(overrides.transform_keys(&:to_s))
    release = File.join(@root, 'data/macos/releases/12/macOS-12.3-21E230.json')
    FileUtils.mkdir_p(File.dirname(release))
    File.write(release, JSON.generate(detail))
    entry = { 'osVersion' => '12.3', 'buildNumber' => '21E230', 'dataFile' => 'releases/12/macOS-12.3-21E230.json' }
    File.write(File.join(@root, 'data/macos/releases.json'), JSON.generate([entry]))
  end

  def test_published_metadata_becomes_rescan_inputs
    publish(isRC: true, rcNumber: 2)
    outputs = ResolveRescan.resolve(@root, 'macos', '12.3', '21E230')
    assert_equal('data/macos/releases/12/macOS-12.3-21E230.json', outputs.fetch('data_file'))
    assert_equal('macOS/12/macOS-12.3-21E230.ipsw', outputs.fetch('archive_path'))
    assert_equal('2022-03-14', outputs.fetch('release_date'))
    assert_equal(%w[true 2], outputs.values_at('is_rc', 'rc_number'))
    assert_equal(['false', ''], outputs.values_at('is_beta', 'beta_number'))
  end

  def test_rejects_inputs_that_are_not_one_canonical_published_release
    publish
    [['12.3', '21E231'], ['12.3/..', '21E230'], ['12.3', "21E230\n"]].each do |version, build|
      assert_raises(ResolveRescan::ResolutionError) { ResolveRescan.resolve(@root, 'macos', version, build) }
    end
  end

  def test_rejects_a_noncanonical_index_pointer
    publish
    entry = { 'osVersion' => '12.3', 'buildNumber' => '21E230', 'dataFile' => 'releases/12/alias.json' }
    File.write(File.join(@root, 'data/macos/releases.json'), JSON.generate([entry]))
    assert_raises(ResolveRescan::ResolutionError) { ResolveRescan.resolve(@root, 'macos', '12.3', '21E230') }
  end

  def test_rejects_releases_a_rescan_cannot_reproduce
    [
      { buildNumber: '21E231' }, { ipswURL: "https://updates.cdn-apple.com/x.ipsw\nnext=value" }, { isBeta: true }
    ].each do |overrides|
      publish(**overrides)
      assert_raises(ResolveRescan::ResolutionError) { ResolveRescan.resolve(@root, 'macos', '12.3', '21E230') }
    end
  end

  def test_rejects_noncanonical_dates_and_invalid_prerelease_numbers
    [{ releaseDate: '0000-01-01' }, { releaseDate: '2022-3-14' }, { releaseDate: '2022-02-30' }, { betaNumber: true }, { rcNumber: 0 }].each do |overrides|
      publish(**overrides)
      assert_raises(ResolveRescan::ResolutionError) { ResolveRescan.resolve(@root, 'macos', '12.3', '21E230') }
    end
  end

  def test_published_dates_use_the_proleptic_gregorian_calendar
    %w[0001-01-01 1582-10-10 1600-02-29 9999-12-31].each do |date|
      publish(releaseDate: date)
      assert_equal(date, ResolveRescan.resolve(@root, 'macos', '12.3', '21E230').fetch('release_date'))
    end
    %w[1500-02-29 0000-01-01 10000-01-01].each do |date|
      publish(releaseDate: date)
      assert_raises(ResolveRescan::ResolutionError) { ResolveRescan.resolve(@root, 'macos', '12.3', '21E230') }
    end
  end

  def test_rejects_invalid_utf8_and_embedded_url_nuls
    publish(ipswURL: "https://updates.cdn-apple.com/x.ipsw\u0000next=value")
    assert_raises(ResolveRescan::ResolutionError) { ResolveRescan.resolve(@root, 'macos', '12.3', '21E230') }
    path = File.join(@root, 'data/macos/releases.json')
    File.binwrite(path, "[\"\xff\"]".b)
    assert_raises(ResolveRescan::ResolutionError) { ResolveRescan.resolve(@root, 'macos', '12.3', '21E230') }
  end

  def test_rejects_symlink_release_files
    publish
    release = File.join(@root, 'data/macos/releases/12/macOS-12.3-21E230.json')
    File.rename(release, "#{release}.other")
    File.symlink("#{release}.other", release)
    assert_raises(ResolveRescan::ResolutionError) { ResolveRescan.resolve(@root, 'macos', '12.3', '21E230') }
  end

  def test_cli_accepts_utf8_paths_without_a_utf8_locale
    publish(releaseName: 'Monterey café')
    detail = File.join(@root, 'data/macos/releases/12/macOS-12.3-21E230.json')
    assert_includes(File.binread(detail), 'café'.b)
    output = File.join(@root, 'résultat.txt')
    run_cli = lambda do
      c_locale_ruby(
        File.expand_path('../resolve-rescan.rb', __dir__), '--product', 'macos',
        '--version', '12.3', '--build', '21E230', '--github-output', output, env: { 'RUBYOPT' => nil }, chdir: @root
      )
    end
    result = defined?(Bundler) ? Bundler.with_unbundled_env(&run_cli) : run_cli.call
    assert(result.success?, "#{result.stdout}\n#{result.stderr}")
    assert_empty(result.stderr)
    assert_includes(File.read(output, encoding: 'utf-8'), 'release_date=2022-03-14')
  end

  def test_every_published_release_resolves
    %w[macos xcode].each do |product|
      JSON.parse(File.read(File.join(REPO_ROOT, 'data', product, 'releases.json'))).each do |entry|
        result = ResolveRescan.resolve(REPO_ROOT, product, entry.fetch('osVersion'), entry.fetch('buildNumber'))
        assert_equal(entry.fetch('releaseDate'), result.fetch('release_date'), "#{product} #{entry.fetch('buildNumber')}")
      end
    end
  end
end
