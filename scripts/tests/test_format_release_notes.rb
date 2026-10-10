# frozen_string_literal: true

require_relative "test_helper"
require_relative "../format-release-notes"

class ReleaseNoteTests < Minitest::Test
  include WorkflowHelpers

  HEADER = "## macOSdb v1.2.3\n\n"
  CLI_BYTE_CASES = (
    [
      ["empty notes", "", HEADER],
      ["only skipped notes", "* chore: maintenance by @dev\n", HEADER],
      ["changelog only", "**Full Changelog**: https://example.test/compare\n",
       HEADER + "---\n**Full Changelog**: https://example.test/compare\n\n"],
      ["NUL is not strip whitespace", "\0* feat: hidden\0", HEADER],
      ["NUL stays inside a description", "* feat: \0retained\0", HEADER + "### What's New\n- \0retained\0\n\n"],
      ["changelog Unicode whitespace", "**Full Changelog**:\u00a0https://example.test/compare\u00a0ignored",
       HEADER + "---\n**Full Changelog**: https://example.test/compare\n\n"]
    ] +
    ["", "\n", "\r\n", "\n\n"].map do |ending|
      ["input trailing newline #{ending.inspect}", "* feat: ordinary by @dev in https://example.test/1#{ending}",
       HEADER + "### What's New\n- ordinary\n\n"]
    end +
    ["\n", "\r\n", "\r", "\v", "\f", "\x1c", "\x1d", "\x1e", "\u0085", "\u2028", "\u2029"].map do |separator|
      ["splitlines #{separator.inspect}", "* feat: first#{separator}* fix: second#{separator}",
       HEADER + "### What's New\n- first\n\n### Fixes\n- second\n\n"]
    end +
    ["\t", " ", "\x1f", "\u00a0", "\u1680", *(0x2000..0x200a).map { |codepoint| codepoint.chr(Encoding::UTF_8) },
     "\u202f", "\u205f", "\u3000"].map do |space|
      raw = "#{space}*#{space}feat:#{space}spaced#{space}by#{space}@dev#{space}in#{space}https://example.test/1#{space}"
      ["Unicode whitespace #{space.inspect}", raw, HEADER + "### What's New\n- spaced\n\n"]
    end +
    %w[José 東京 Ⅷ ² user_name user-name José_東京Ⅷ²].map do |author|
      ["Unicode author #{author}", "* feat: Unicode author by @#{author} in https://example.test/1\n",
       HEADER + "### What's New\n- Unicode author\n\n"]
    end +
    ["cafe\u0301", "user\u203fname"].map do |author|
      ["non-alphanumeric author #{author}", "* feat: retained author by @#{author} in https://example.test/1\n",
       HEADER + "### What's New\n- retained author by @#{author}\n\n"]
    end
  ).freeze

  def test_cli_preserves_python_byte_output
    Dir.mktmpdir do |directory|
      input = Pathname.new(directory).join("notes-é.md")
      CLI_BYTE_CASES.each do |label, raw, expected|
        input.binwrite(raw)
        result = c_locale_ruby(ROOT.join("scripts/format-release-notes.rb"), input, "v1.2.3")
        assert result.success?, "#{label}: #{result.stderr}"
        assert_equal expected.b, result.stdout.b, label
      end
    end
  end

  def test_cli_formats_unicode_notes_without_a_utf8_locale
    Dir.mktmpdir do |directory|
      input = Pathname.new(directory).join("notes-é.md")
      input.write("* feat: café by @dev in https://example.test/1\n")
      result = c_locale_ruby(ROOT.join("scripts/format-release-notes.rb"), input, "1.0.0")
      assert result.success?, result.stderr
      assert_includes result.stdout, "- café"
    end
  end

  def test_breaking_conventional_commits_keep_their_section
    parsed, = ReleaseNotes.parse_notes(
      "* feat!: add a new schema by @dev in https://example.test/1\n" \
      "* fix(scanner)!: reject malformed input by @dev in https://example.test/2"
    )
    assert_equal ["add a new schema"], parsed["What's New"]
    assert_equal ["reject malformed input"], parsed["Fixes"]
  end

  def test_skipped_types_and_changelog
    parsed, changelog = ReleaseNotes.parse_notes(
      "* chore!: internal maintenance by @dev in https://example.test/1\n" \
      "**Full Changelog**: https://example.test/compare"
    )
    assert_empty parsed
    assert_equal "https://example.test/compare", changelog
  end
end
