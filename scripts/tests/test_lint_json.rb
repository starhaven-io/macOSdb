# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "test_helper"
require_relative "../lint-json"

module LintJsonTests
  ROOT = Pathname(__dir__).join("../..").realpath
  VECTORS = ROOT.join("Tests/macOSdbCoreTests/Fixtures/ordering-vectors.json")

  class TestCase < Minitest::Test
    include WorkflowHelpers

    def setup
      LintJson.errors = 0
      LintJson.warnings = 0
    end

    def teardown
      LintJson.errors = 0
      LintJson.warnings = 0
    end

    def with_directory
      Dir.mktmpdir { |directory| yield Pathname(directory).realpath }
    end

    def macos_release
      JSON.parse(ROOT.join("data/macos/releases/15/macOS-15.0-24A335.json").read)
    end
  end

  class GoldenVectorTests < TestCase
    def test_os_version_vectors
      JSON.parse(VECTORS.read).fetch("osVersions").each do |vector|
        left = LintJson.parse_version(vector["lhs"])
        right = LintJson.parse_version(vector["rhs"])
        refute_nil left, vector["lhs"]
        refute_nil right, vector["rhs"]
        assert_equal({ "lt" => -1, "gt" => 1, "eq" => 0 }.fetch(vector["expected"]), left <=> right,
                     "#{vector['lhs']} vs #{vector['rhs']}")
      end
    end

    def test_build_vectors
      JSON.parse(VECTORS.read).fetch("builds").each do |vector|
        left = LintJson.parse_build(vector["lhs"])
        right = LintJson.parse_build(vector["rhs"])
        assert_equal({ "lt" => -1, "gt" => 1, "eq" => 0 }.fetch(vector["expected"]), left <=> right,
                     "#{vector['lhs']} vs #{vector['rhs']}")
      end
    end
  end

  class ParserTests < TestCase
    def test_parse_version_rejects_garbage
      ["abc", nil, "15.x"].each { |version| assert_nil LintJson.parse_version(version) }
    end

    def test_parse_build_matches_swift_shape
      assert_equal [24, "D", 2082, ""], LintJson.parse_build("24D2082")
      assert_equal [24, "A", 5331, "b"], LintJson.parse_build("24A5331b")
      assert_equal [24, "B", 0, ""], LintJson.parse_build("24B")
      assert_equal [0, "", 0, ""], LintJson.parse_build(nil)
    end

    def test_dates_use_the_proleptic_gregorian_calendar
      _, invalid = capture_io { LintJson.validate_date("1500-02-29", "releaseDate", "test") }
      assert_includes invalid, "not a valid date"
      _, valid = capture_io { LintJson.validate_date("1582-10-10", "releaseDate", "test") }
      refute_includes valid, "ERROR"
      assert_includes valid, "before 2001"
    end
  end

  class StrictJSONTests < TestCase
    def test_json_parser_without_duplicate_key_rejection_fails_closed
      with_directory do |root|
        path = root.join("fixture.json")
        path.write("{}")
        script = <<~'RUBY'
          require "json"
          parse = JSON.method(:parse)
          JSON.define_singleton_method(:parse) do |source, **options|
            parse.call(source, **options.merge(allow_duplicate_key: true))
          end
          require ARGV.shift
          begin
            LintJson.read_json(ARGV.shift, 1024)
            exit 2
          rescue JSON::ParserError => error
            warn error.message
            exit 1
          end
        RUBY
        _, output, status = Open3.capture3(RbConfig.ruby, "-e", script, ROOT.join("scripts/lint-json.rb").to_s, path.to_s)
        assert_equal 1, status.exitstatus
        assert_includes output, "must support rejection of duplicate object keys"
      end
    end

    def test_empty_catalog_file_reports_a_validation_error
      with_directory do |root|
        data_dir = root.join("releases")
        data_dir.mkdir
        data_dir.join("macOS-15.0-24A335.json").write("")
        root.join("releases.json").write("[]")
        product = LintJson::PRODUCTS[0].merge("data" => data_dir, "index" => root.join("releases.json"))
        _, output = capture_io { assert_equal 1, LintJson.main(products: [product]) }
        assert_includes output, "macOS-15.0-24A335.json: invalid JSON"
        refute_includes output, "NoMethodError"
      end
    end

    def test_json_byte_encodings_preserve_unicode
      with_directory do |root|
        path = root.join("fixture.json")
        object = { "field" => "日本語" }
        source = JSON.generate(object)
        [Encoding::UTF_8, Encoding::UTF_16LE, Encoding::UTF_16BE,
         Encoding::UTF_32LE, Encoding::UTF_32BE].each do |encoding|
          [source, "\ufeff#{source}"].each do |text|
            path.binwrite(text.encode(encoding))
            assert_equal object, LintJson.read_json(path, 1024)
          end
        end
        path.binwrite("{\"field\": \"\xff\"}".b)
        assert_raises(JSON::ParserError) { LintJson.read_json(path, 1024) }
      end
    end

    def test_duplicate_keys_and_nonfinite_numbers_are_rejected
      with_directory do |root|
        path = root.join("fixture.json")
        ['', '{"field": 1, "field": 2}', '{"nested": {"field": 1, "field": 2}}',
         '{"field": NaN}', '{"field": Infinity}', '{"field": -Infinity}'].each do |source|
          path.write(source)
          assert_raises(JSON::ParserError, source) { LintJson.read_json(path, 1024) }
        end
      end
    end

    def test_comments_and_lone_surrogates_report_validation_errors
      with_directory do |root|
        data_dir = root.join("releases")
        data_dir.mkdir
        release_path = data_dir.join("macOS-15.0-24A335.json")
        root.join("releases.json").write("[]")
        product = LintJson::PRODUCTS[0].merge("data" => data_dir, "index" => root.join("releases.json"))
        ['{/* comment */ "field": 1}', "{ // comment\n \"field\": 1}",
         '{"field": "\udc00"}', '{"\udc00": "field"}'].each do |source|
          release_path.write(source)
          assert_raises(JSON::ParserError) { LintJson.read_json(release_path, 1024) }
          _, output = capture_io { assert_equal 1, LintJson.main(products: [product]) }
          assert_includes output, "macOS-15.0-24A335.json: invalid JSON"
        end
        accepted = { "slashes" => "https://apple.com/*text*/", "escaped" => '" // \\ /*' }
        release_path.write(JSON.generate(accepted))
        assert_equal accepted, LintJson.read_json(release_path, 1024)
      end
    end

    def test_size_limit_is_enforced_before_parsing
      with_directory do |root|
        path = root.join("fixture.json")
        path.write('{"field": "too large"}')
        error = assert_raises(ArgumentError) { LintJson.read_json(path, 4) }
        assert_match(/size limit/, error.message)
      end
    end

    def test_regular_file_and_catalog_confinement
      with_directory do |root|
        source = root.join("release.json")
        source.write('{"valid": true}')
        assert_equal({ "valid" => true }, LintJson.read_json(source, 1024, root))
        link = root.join("linked.json")
        link.make_symlink(source)
        assert_raises(SystemCallError) { LintJson.read_json(link, 1024, root) }
        directory = root.join("directory.json")
        directory.mkdir
        error = assert_raises(ArgumentError) { LintJson.read_json(directory, 1024, root) }
        assert_match(/regular file/, error.message)
        nested = root.join("nested")
        nested.make_symlink(root)
        assert_raises(SystemCallError) { LintJson.read_json(nested.join("release.json"), 1024, root) }
        traversal = "#{root}/../release.json"
        assert_raises(ArgumentError) { LintJson.read_json(traversal, 1024, root) }
        assert_raises(ArgumentError) { LintJson.read_json(root, 1024, root) }
      end
    end

    def test_every_opened_parent_must_be_a_directory
      with_directory do |root|
        regular = root.join("regular")
        regular.write("{}")
        fifo = root.join("fifo")
        File.mkfifo(fifo)
        [regular, fifo].each do |parent|
          assert_raises(Errno::ENOTDIR) { LintJson.read_json(parent.join("release.json"), 1024, root) }
          assert_raises(Errno::ENOTDIR) { LintJson.read_json(parent.join("release.json"), 1024, parent) }
        end
      end
    end

    def test_cli_without_a_locale_handles_unicode_diagnostics
      with_directory do |root|
        LintJson::PRODUCTS.each do |product|
          root.join(product["data"]).mkpath
          root.join(product["index"]).write("[]")
        end
        release = macos_release.merge("releaseName" => "日本語")
        root.join("data/macos/releases/macOS-15.0-24A335.json").write(JSON.generate(release))
        result = c_locale_ruby(ROOT.join("scripts/lint-json.rb"), env: { "RUBYOPT" => nil }, chdir: root)
        assert_equal 1, result.returncode
        assert_includes result.stderr, "releaseName '日本語' should be 'Sequoia'"
        refute_includes result.stderr, "Encoding::"
      end
    end

    def test_unicode_controls_are_rejected_in_values_and_keys
      ["\u001b", "\u007f", "\u0085", "\u009f"].each do |control|
        _, output = capture_io { LintJson.reject_control_characters({ "key#{control}" => ["text#{control}"] }, "test") }
        assert_equal 2, output.scan("contains a control character").length
      end
      _, output = capture_io { LintJson.reject_control_characters({ "name" => "日本語 ✓" }, "test") }
      assert_empty output
    end
  end

  class CatalogShapeTests < TestCase
    def validate(data)
      with_directory do |root|
        product = LintJson::PRODUCTS[0].merge("data" => root)
        root.join("macOS-15.0-24A335.json").write(JSON.generate(data))
        capture_io { LintJson.validate_releases(product, {}) }.last
      end
    end

    def test_non_object_release_is_reported_without_a_traceback
      [nil, [], true, "text"].each do |value|
        assert_includes validate(value), "top-level value should be object"
      end
    end

    def test_prerelease_numbers_reject_booleans
      [["isBeta", "betaNumber"], ["isRC", "rcNumber"]].each do |flag, number|
        candidate = macos_release.merge("isBeta" => false, "isRC" => false, flag => true, number => true)
        assert_includes validate(candidate), "#{number} should be a positive integer"
      end
    end

    def test_components_kernels_sources_and_strings_are_strict
      release = macos_release
      curl = release["components"].index { |component| component["name"] == "curl" }
      cases = [
        [->(data) { data["components"][curl]["source"] = "dyldCache" }, "should come from 'filesystem'"],
        [->(data) { data["components"][curl]["path"] = "usr/bin/curl" }, "is not absolute"],
        [->(data) { data["kernels"][0]["darwinVersion"] = "" }, "darwinVersion is empty or not a string"],
        [->(data) { data["components"][curl]["version"] = "8.7.1\e[2J" }, "contains a control character"],
        [->(data) { data.merge!("ipswURL" => "https://updates.cdn-apple.com/2024/Restore.ipsw", "ipswFile" => "Restore.ipsw") },
         "ipswURL filename is not UniversalMac_"],
        [->(data) { data["ipswURL"] = "https://updates.cdn-apple.com/2024/other.ipsw#/#{data['ipswFile']}" },
         "ipswURL must not contain a query or fragment"],
        [->(data) { data["ipswURL"] = "https://updates.cdn-apple.com/2024/#{data['ipswFile']}?download=1" },
         "ipswURL must not contain a query or fragment"]
      ]
      refute_includes validate(release).downcase, "error"
      cases.each do |change, message|
        candidate = macos_release
        change.call(candidate)
        assert_includes validate(candidate), message
      end
    end

    def test_component_set_must_be_complete_without_duplicates_or_extras
      release = macos_release
      missing = release["components"].pop
      assert_includes validate(release), "missing tracked components: #{missing['name']}"
      release["components"] << release["components"].first
      assert_includes validate(release), "duplicate component name"
      release["components"] << missing.merge("name" => "unexpected")
      assert_includes validate(release), "unconfigured components: unexpected"
    end

    def test_device_identifiers_must_not_be_empty
      release = macos_release
      release["kernels"][0]["devices"] = ["Mac14,2", ""]
      assert_includes validate(release), "devices contains empty or non-string entries"
    end

    def test_optional_shapes_and_stray_catalog_files
      [nil, {}, [nil], [{ "device" => "Mac1,1", "chip" => "" }]].each do |value|
        candidate = macos_release
        candidate["kernels"][0]["deviceChips"] = value
        assert_includes validate(candidate), "deviceChips"
      end
      %w[betaNumber betaRevision rcNumber].each do |field|
        assert_includes validate(macos_release.merge(field => nil)), "instead of null"
      end
      with_directory do |root|
        root.join("stray.json").write("{}")
        _, output = capture_io { LintJson.validate_releases(LintJson::PRODUCTS[0].merge("data" => root), {}) }
        assert_includes output, "unexpected JSON file"
      end
    end

    def test_catalog_extension_matching_is_case_sensitive
      with_directory do |root|
        root.join("macOS-15.0-24A335.json").write(JSON.generate(macos_release))
        root.join("macOS-15.0-24A999.JSON").write("invalid JSON")
        root.join("macOS-15.0-24A998.Json").write("invalid JSON")
        catalog = {}
        _, output = capture_io { LintJson.validate_releases(LintJson::PRODUCTS[0].merge("data" => root), catalog) }
        assert_empty output
        assert_equal ["24A335"], catalog.keys
      end
    end

    def test_dot_json_is_an_unexpected_catalog_file
      with_directory do |root|
        data_dir = root.join("releases")
        data_dir.mkdir
        data_dir.join(".json").write("{}")
        root.join("releases.json").write("[]")
        product = LintJson::PRODUCTS[0].merge("data" => data_dir, "index" => root.join("releases.json"))
        _, output = capture_io { assert_equal 1, LintJson.main(products: [product]) }
        assert_includes output, ".json: unexpected JSON file in release catalog"
      end
    end

    def test_actual_control_character_filenames_cannot_inject_workflow_commands
      with_directory do |root|
        LintJson::PRODUCTS.each do |product|
          root.join(product["data"]).mkpath
          root.join(product["index"]).write("[]")
        end
        releases = root.join("data/macos/releases")
        releases.join("\n::warning::stray.json").write("{}")
        releases.join("##[error]legacy.json").write("{}")
        bidi_controls = [0x061c, 0x200e, 0x200f, *(0x202a..0x202e), *(0x2066..0x2069)].pack("U*")
        releases.join("bidi-#{bidi_controls}.json").write("{}")
        releases.join("macOS-15.0\n::warning::duplicate-24A335.json").write(JSON.generate(macos_release))
        releases.join("macOS-15.0-24A335.json").write(JSON.generate(macos_release))
        releases.join("\u001f" * 250 + ".json").write("{}")
        result = c_locale_ruby(ROOT.join("scripts/lint-json.rb"), env: { "RUBYOPT" => nil }, chdir: root)
        assert_equal 1, result.returncode
        refute_match(/^::warning::/, result.stderr)
        refute_includes result.stderr, "##["
        assert_includes result.stderr, "## [error]legacy.json: unexpected JSON file"
        bidi_controls.each_char do |character|
          refute_includes result.stderr, character
          assert_includes result.stderr, character.dump[1...-1]
        end
        diagnostics = result.stderr.lines.grep(/^  ERROR: /)
        assert_operator diagnostics.length, :>=, 4
        assert diagnostics.all? { |line| line.bytesize <= LintJson::MAX_DIAGNOSTIC_BYTES + 10 }
        assert diagnostics.any? { |line| line.end_with?("...\n") }
        assert_includes result.stderr, '\n::warning::stray.json: unexpected JSON file'
        assert_includes result.stderr, 'already defined in macOS-15.0\n::warning::duplicate-24A335.json'
        refute_includes result.stderr, "\u001f"
      end
    end

    def test_diagnostics_preserve_readable_unicode_and_escape_nested_paths
      ordinary = "macOS-15.0-24A335.json: releaseName '日本語' should be 'Sequoia'"
      assert_equal ordinary, LintJson.diagnostic(ordinary)
      legacy_markers = "##[error]" * 200
      neutralized = LintJson.diagnostic(legacy_markers)
      refute_includes neutralized, "##["
      assert_operator neutralized.bytesize, :<=, LintJson::MAX_DIAGNOSTIC_BYTES
      _, output = capture_io do
        LintJson.error(Errno::EACCES.new("releases/nested\n::warning::path/release.json").message)
        LintJson.warn("releases/nested\r::warning::path/release.json: warning")
      end
      assert_equal 2, output.lines.length
      assert_includes output, 'nested\n::warning::path'
      assert_includes output, 'nested\r::warning::path'
      refute_match(/^::warning::/, output)
    end

    def test_invalid_utf8_catalog_names_have_bounded_diagnostics_in_a_c_locale
      with_directory do |root|
        LintJson::PRODUCTS.each do |product|
          root.join(product["data"]).mkpath
          root.join(product["index"]).write("[]")
        end
        fixture = root.join("invalid-filenames.rb")
        fixture.write(<<~'RUBY')
          glob = Dir.method(:glob)
          Dir.define_singleton_method(:glob) do |*arguments, **options|
            paths = glob.call(*arguments, **options)
            if options[:base] == "data/macos/releases"
              paths += ["bad-\xFF.json", "bad-\xFF/valid.json", "bad-\xFF.JSON",
                        "line\n::warning::spoof-\xFF.json", "x" * 2000 + "\xFF.json"]
            end
            paths
          end
          $PROGRAM_NAME = ARGV.shift
          load $PROGRAM_NAME
        RUBY
        result = c_locale_ruby(fixture, ROOT.join("scripts/lint-json.rb"), env: { "RUBYOPT" => nil }, chdir: root)
        assert_equal 1, result.returncode
        diagnostics = result.stderr.lines.grep(/release catalog path contains invalid UTF-8:/)
        assert_equal 4, diagnostics.length
        assert diagnostics.all? { |line| line.ascii_only? && line.bytesize < 600 }
        assert_includes result.stderr, 'bad-\xFF.json'
        assert_includes result.stderr, 'bad-\xFF/valid.json'
        assert_includes result.stderr, 'line\n::warning::spoof-\xFF.json'
        assert diagnostics.any? { |line| line.end_with?("\"...\n") }
        refute_match(/^::warning::/, result.stderr)
        refute_includes result.stderr, "ArgumentError"
      end
    end

    if RUBY_PLATFORM.include?("linux")
      def test_linux_catalog_with_an_invalid_utf8_filename_fails_without_a_traceback
        with_directory do |root|
          LintJson::PRODUCTS.each do |product|
            root.join(product["data"]).mkpath
            root.join(product["index"]).write("[]")
          end
          File.binwrite(root.join("data/macos/releases").to_s.b + "/bad-\xFF.json".b, "{}")
          result = c_locale_ruby(ROOT.join("scripts/lint-json.rb"), env: { "RUBYOPT" => nil }, chdir: root)
          assert_equal 1, result.returncode
          assert_includes result.stderr, 'release catalog path contains invalid UTF-8: "bad-\xFF.json"'
          refute_includes result.stderr, "ArgumentError"
        end
      end
    end

    def test_missing_required_catalog_fails_the_gate
      with_directory do |root|
        product = LintJson::PRODUCTS[0].merge("data" => root.join("missing"))
        capture_io { assert_equal 1, LintJson.main(products: [product]) }
      end
    end
  end

  class IndexOrderTests < TestCase
    def sorted_builds(entries)
      LintJson.sorted_releases(entries).map { |entry| entry["buildNumber"] }
    end

    def test_newest_version_first_and_ga_over_prerelease
      entries = [
        { "osVersion" => "15.1", "buildNumber" => "24B83", "isBeta" => false, "isRC" => false },
        { "osVersion" => "15.1.1", "buildNumber" => "24B91", "isBeta" => false, "isRC" => false },
        { "osVersion" => "15.1", "buildNumber" => "24B5077d", "isBeta" => true, "isRC" => false },
        { "osVersion" => "15.1", "buildNumber" => "24B82", "isBeta" => false, "isRC" => true }
      ]
      assert_equal %w[24B91 24B83 24B82 24B5077d], sorted_builds(entries)
    end

    def test_rerelease_build_orders_numerically
      entries = [
        { "osVersion" => "15.1", "buildNumber" => "24B83", "isBeta" => false, "isRC" => false },
        { "osVersion" => "15.1", "buildNumber" => "24B2083", "isBeta" => false, "isRC" => false }
      ]
      assert_equal %w[24B2083 24B83], sorted_builds(entries)
    end

    def test_equal_sort_keys_retain_input_order
      entries = (0...64).map do |index|
        { "osVersion" => "15.0", "buildNumber" => "24A#{'0' * index}1", "isBeta" => false, "isRC" => false }
      end.shuffle(random: Random.new(127))
      newer = { "osVersion" => "15.1", "buildNumber" => "24B83", "isBeta" => false, "isRC" => false }
      input = entries.dup.insert(31, newer)
      assert_equal [newer] + entries, LintJson.sorted_releases(input)
    end
  end

  class DownloadURLTests < TestCase
    def errors_for(url)
      LintJson.errors = 0
      capture_io { LintJson.validate_download_url(url, "ipswURL", "test") }
      LintJson.errors
    end

    def test_apple_https_hosts_pass
      assert_equal 0, errors_for("https://updates.cdn-apple.com/a/b.ipsw")
      assert_equal 0, errors_for("https://download.developer.apple.com/a.xip")
    end

    def test_non_apple_or_non_https_fail
      ["http://updates.cdn-apple.com/a.ipsw", "javascript:alert(1)",
       "https://evil.example.com/a.ipsw", "https://apple.com.evil.example/a.ipsw"].each do |url|
        assert_equal 1, errors_for(url)
      end
      assert_equal 1, errors_for("https://user:password@apple.com/archive.xip")
    end

    def test_wrapper_url_parsing_preserves_path_and_percent_encoding
      assert_equal "Xcode_26_beta.xip", LintJson.download_filename(
        "https://developer.apple.com/services-account/download?" \
        "path=%2FDeveloper%20Tools%2FXcode_26_beta.xip", query_parameter: "path"
      )
      assert_equal "Xcode_26_beta.xip", LintJson.download_filename(
        "https://developer.apple.com/Developer Tools/Xcode_26_beta.xip;download=1"
      )
      assert_equal 0, errors_for(" HTTPS://APPLE.COM/archive.xip")
      assert_equal 0, errors_for("https://apple.com:invalid-port/archive.xip")
    end

    def test_download_filenames_are_parsed_from_paths_and_wrapper_queries
      assert_equal "UniversalMac_26.1_25B78_Restore.ipsw", LintJson.download_filename(
        "https://updates.cdn-apple.com/a/UniversalMac_26.1_25B78_Restore.ipsw?token=one"
      )
      assert_equal "Xcode_26.1_Release_Candidate.xip", LintJson.download_filename(
        "https://developer.apple.com/services-account/download?" \
        "path=/Developer_Tools/Xcode_26.1/Xcode_26.1_Release_Candidate.xip", query_parameter: "path"
      )
    end

    def test_identifier_regexes_use_ascii_digits
      refute_match LintJson::VERSION_RE, "٢٦.١"
      refute_match LintJson::BUILD_IDENTIFIER_RE, "٢٥B78"
    end

    def test_major_only_xcode_archive_versions_normalize_to_dot_zero
      assert_equal "26.0", LintJson.xcode_file_version("Xcode_26_Universal.xip")
      assert_equal "26.1", LintJson.xcode_file_version("Xcode_26.1_beta.xip")
      assert_nil LintJson.xcode_file_version("not-xcode.xip")
    end

    def test_xcode_archive_labels_are_whole_suffix_tokens
      [
        ["Xcode_27.xip", nil], ["Xcode_26_Universal.xip", nil], ["Xcode_26.2_Apple_silicon.xip", nil],
        ["Xcode_27_beta.xip", "beta"], ["Xcode_27_beta_2.xip", "beta"], ["Xcode_13_beta3.xip", "beta"],
        ["Xcode_26.4_beta_Apple_silicon.xip", "beta"], ["Xcode_12_for_macOS_Universal_Apps_beta.xip", "beta"],
        ["Xcode_27_Release_Candidate.xip", "Release_Candidate"],
        ["Xcode_26.6_Release_Candidate_2_Apple_silicon.xip", "Release_Candidate"],
        ["Xcode_27_betamax.xip", nil], ["Xcode_27_Release_Candidates.xip", nil], ["not-xcode.xip", nil], [nil, nil]
      ].each do |name, label|
        label.nil? ? assert_nil(LintJson.xcode_file_label(name)) : assert_equal(label, LintJson.xcode_file_label(name))
      end
    end
  end

  class XcodeArchiveLabelTests < TestCase
    def setup
      super
      source = ROOT.join("data/xcode/releases").glob("**/*.json").sort.first
      @release = JSON.parse(source.read)
      %w[betaNumber betaRevision rcNumber].each { |field| @release.delete(field) }
      @name = source.basename
      @release.merge!("isBeta" => false, "isRC" => false)
    end

    def validate(xip_file, flags = {})
      stem = xip_file.delete_suffix(".xip")
      data = @release.merge(flags).merge(
        "xipFile" => xip_file,
        "xipURL" => "https://developer.apple.com/services-account/download?path=/Developer_Tools/#{stem}/#{xip_file}"
      )
      with_directory do |root|
        root.join(@name).write(JSON.generate(data))
        capture_io { LintJson.validate_releases(LintJson::PRODUCTS[1].merge("data" => root), {}) }.last
      end
    end

    def test_duplicate_sdk_versions_are_rejected
      sdk = @release["sdks"][0]
      assert_includes validate("Xcode_13.xip", "sdks" => [sdk, sdk]), "duplicate SDK version"
    end

    def test_stable_release_rejects_prerelease_archive
      %w[Release_Candidate Release_Candidate_2_Apple_silicon beta beta_3_Universal].each do |suffix|
        assert_includes validate("Xcode_#{@release['osVersion']}_#{suffix}.xip"), "archive but isBeta=False, isRC=False"
      end
    end

    def test_prerelease_flags_require_matching_archive_label
      version = @release["osVersion"]
      [
        ["Xcode_#{version}.xip", { "isRC" => true }],
        ["Xcode_#{version}_beta.xip", { "isRC" => true }],
        ["Xcode_#{version}.xip", { "isBeta" => true, "betaNumber" => 1 }],
        ["Xcode_#{version}_Release_Candidate.xip", { "isBeta" => true, "betaNumber" => 1 }]
      ].each do |file, flags|
        assert_includes validate(file, flags), "xipFile '#{file}' is a"
      end
    end

    def test_matching_labels_pass
      version = @release["osVersion"]
      [
        ["Xcode_#{version}.xip", {}], ["Xcode_#{version}_Apple_silicon.xip", {}],
        ["Xcode_#{version}_Release_Candidate.xip", { "isRC" => true }],
        ["Xcode_#{version}_Release_Candidate_2_Universal.xip", { "isRC" => true, "rcNumber" => 2 }],
        ["Xcode_#{version}_beta.xip", { "isBeta" => true, "betaNumber" => 1 }],
        ["Xcode_#{version}_beta_2_Apple_silicon.xip", { "isBeta" => true, "betaNumber" => 2 }]
      ].each do |file, flags|
        assert_equal "", validate(file, flags)
      end
    end
  end

  class IndexPointerTests < TestCase
    def product(root)
      LintJson::PRODUCTS[0].merge("data" => root.join("releases"), "index" => root.join("releases.json"))
    end

    def entry(data_file)
      {
        "buildNumber" => "24A335", "osVersion" => "15.0", "releaseName" => "Sequoia",
        "releaseDate" => "2024-09-16", "isBeta" => false, "isRC" => false,
        "isDeviceSpecific" => false, "productType" => "macOS", "dataFile" => data_file
      }
    end

    def with_catalog
      with_directory do |root|
        expected = root.join("releases/15/macOS-15.0-24A335.json")
        expected.parent.mkpath
        yield root, expected, "releases/15/macOS-15.0-24A335.json"
      end
    end

    def test_index_rejects_swapped_or_traversing_data_file
      with_catalog do |root, expected, _pointer|
        expected.write("{}")
        catalog = { "24A335" => { "path" => expected, "data" => entry("unused") } }
        ["releases/15/macOS-15.1-24B83.json", "../outside.json"].each do |pointer|
          root.join("releases.json").write(JSON.generate([entry(pointer)]))
          LintJson.errors = 0
          capture_io { LintJson.validate_index(product(root), catalog) }
          assert_operator LintJson.errors, :>, 0, pointer
        end
      end
    end

    def test_index_accepts_canonical_data_file
      with_catalog do |root, expected, pointer|
        release = entry("unused")
        expected.write(JSON.generate(release))
        root.join("releases.json").write(JSON.generate([entry(pointer)]))
        catalog = { "24A335" => { "path" => expected, "data" => release } }
        capture_io { LintJson.validate_index(product(root), catalog) }
        assert_equal 0, LintJson.errors
      end
    end

    def test_index_path_failures_produce_diagnostics
      %i[not_directory symlink_loop permission_denied].each do |failure|
        next if failure == :permission_denied && Process.euid.zero?

        with_directory do |root|
          root.join("releases").mkdir
          directory = root.join("releases/15")
          case failure
          when :not_directory
            directory.write("not a directory")
          when :symlink_loop
            directory.make_symlink("15")
          when :permission_denied
            directory.mkdir
            directory.chmod(0)
          end
          pointer = "releases/15/macOS-15.0-24A335.json"
          root.join("releases.json").write(JSON.generate([entry(pointer)]))
          _, output = capture_io { LintJson.validate_index(product(root), {}) }
          assert_includes output, "dataFile '#{pointer}' cannot be resolved", failure.to_s
        ensure
          directory.chmod(0o700) if failure == :permission_denied && directory
        end
      end
    end

    def test_index_rejects_unknown_fields_and_invalid_optional_integers
      with_catalog do |root, expected, pointer|
        [
          ["unexpected", "value", "unexpected fields: unexpected"],
          ["betaNumber", nil, "betaNumber must be a valid integer when present"],
          ["betaNumber", true, "betaNumber must be a valid integer when present"],
          ["betaRevision", 1, "betaRevision must be a valid integer when present"],
          ["rcNumber", 0, "rcNumber must be a valid integer when present"]
        ].each do |field, value, diagnostic|
          candidate = entry(pointer).merge(field => value)
          expected.write(JSON.generate(candidate))
          root.join("releases.json").write(JSON.generate([candidate]))
          catalog = { "24A335" => { "path" => expected, "data" => candidate } }
          _, output = capture_io { LintJson.validate_index(product(root), catalog) }
          assert_includes output, diagnostic
        end
      end
    end

    def test_index_prerelease_numbers_match_the_detail_type
      with_catalog do |root, expected, pointer|
        release = entry("unused").merge("isBeta" => true, "betaNumber" => 1)
        expected.write(JSON.generate(release))
        catalog = { "24A335" => { "path" => expected, "data" => release } }
        [true, 1.0].each do |value|
          candidate = entry(pointer).merge("isBeta" => true, "betaNumber" => value)
          root.join("releases.json").write(JSON.generate([candidate]))
          _, output = capture_io { LintJson.validate_index(product(root), catalog) }
          assert_includes output, "betaNumber mismatch"
        end
      end
    end
  end
end
