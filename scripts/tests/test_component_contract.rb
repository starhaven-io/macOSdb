# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lint-json"

class ComponentContractTests < Minitest::Test
  ROOT = Pathname(__dir__).join("../..").realpath

  def setup
    @source = ROOT.join("Sources/macOSdbCore/Scanner/ScannerConfig.swift").read
  end

  def names_between(start_marker, end_marker)
    section = @source.split(start_marker, 2).fetch(1).split(end_marker, 2).fetch(0)
    section.scan(/\bname:\s*"([^"]+)"/).flatten.to_set
  end

  def sources_of(component_sources)
    component_sources.each_with_object({}) do |(name, source), grouped|
      (grouped[source] ||= Set.new).add(name)
    end
  end

  def test_macos_linter_contract_matches_scanner_configuration
    filesystem = names_between("let filesystemComponents:", "// MARK: - dyld shared cache component definitions")
    dyld = names_between("let dyldCacheComponents:", "// MARK: - Toolchain component definitions")
    assert_equal filesystem | dyld, LintJson::MACOS_EXPECTED_COMPONENTS
    assert_equal({ "filesystem" => filesystem, "dyldCache" => dyld }, sources_of(LintJson::MACOS_COMPONENT_SOURCES))
  end

  def test_xcode_linter_contract_matches_scanner_configuration
    toolchain = names_between("let toolchainComponents:", "// MARK: - SDK component definitions")
    sdk = names_between("return [", "\n    ]\n}")
    assert_equal toolchain | sdk | Set["Python"], LintJson::XCODE_EXPECTED_COMPONENTS
    assert_equal({ "filesystem" => toolchain | Set["Python"], "sdk" => sdk }, sources_of(LintJson::XCODE_COMPONENT_SOURCES))
  end
end
