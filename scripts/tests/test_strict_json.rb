# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../strict-json'

class StrictJSONTests < Minitest::Test
  def test_rejects_comments_at_every_json_boundary
    [
      '/* before */ {"ok":true}', "// before\n{\"ok\":true}",
      '{/* member */ "ok":true}', '{"ok":/* value */true}',
      "{\"ok\":true// after value\n}", '{"ok":true} /* after */',
      '[1, /* hidden finding */ 2]', '{"url":"https://example.test",/* "\\\" // */"ok":true}'
    ].each do |source|
      assert_raises(JSON::ParserError, source) { StrictJSON.parse(source) }
    end
  end

  def test_rejects_comments_after_an_escape_in_a_closed_string
    %w[b f n r t u0061].each do |escape|
      source = %({"value":"a\\#{escape}"})
      [' /* hidden */', " // hidden\n"].each do |comment|
        assert_raises(JSON::ParserError, source + comment) { StrictJSON.parse(source + comment) }
      end
    end
    escaped_quote = JSON.generate('value' => 'a"')
    assert_raises(JSON::ParserError) { StrictJSON.parse(escaped_quote + ' /* hidden */') }
    escaped_backslash = JSON.generate('value' => 'a\\')
    assert_raises(JSON::ParserError) { StrictJSON.parse(escaped_backslash + ' /* hidden */') }
  end

  def test_rejects_comments_late_in_large_documents
    prefix = JSON.generate('padding' => 'x' * (128 * 1024), 'url' => 'https://example.test')
    [' /* late hidden */', " // late hidden\n"].each do |comment|
      assert_raises(JSON::ParserError) { StrictJSON.parse(prefix + comment) }
    end
  end

  def test_rejects_comments_after_nested_strings
    [
      '{"outer":{"inner":"value" /* hidden */}}',
      "{\"outer\":{\"inner\":\"value\" // hidden\n}}",
      '[{"inner":["value" /* hidden */]}]'
    ].each do |source|
      assert_raises(JSON::ParserError, source) { StrictJSON.parse(source) }
    end
  end

  def test_scans_decoded_utf16_for_comments
    source = JSON.generate('value' => "\u0122") + ' /* hidden */'
    %w[UTF-16LE UTF-16BE].each do |encoding|
      bytes = source.encode(encoding).b
      [bytes, "\uFEFF".encode(encoding).b + bytes].each do |encoded|
        assert_raises(JSON::ParserError, encoding) { StrictJSON.parse(encoded) }
      end
    end
  end

  def test_slashes_inside_strings_and_escaped_quotes_are_valid
    values = [
      'https://example.test/path?q=x/y#part', '// this is a string', '/* this too */',
      '\\" // escaped quote', '\\\\" /* escaped slash', "quote: \"; slash: /; backslash: \\"
    ]
    values.each do |value|
      assert_equal({ 'value' => value }, StrictJSON.parse(JSON.generate('value' => value)))
    end
    assert_equal({ 'value' => '" / \\ /*' }, StrictJSON.parse('{"value":"\u0022 / \u005c /*"}'))
    assert_equal({ 'value' => '/' }, StrictJSON.parse('{"value":"\/"}'))
  end

  def test_rejects_unpaired_surrogates_in_values_and_keys
    ['{"field":"\udc00"}', '{"\udc00":1}', '["\udfff"]', '{"nested":{"field":"\ud800"}}'].each do |source|
      assert_raises(JSON::ParserError, source) { StrictJSON.parse(source) }
    end
    assert_equal({ 'field' => '😀' }, StrictJSON.parse('{"field":"\ud83d\ude00"}'))
  end

  def test_preserves_json_control_escapes_for_schema_validation
    assert_equal({ 'field' => "\u0000\n\t" }, StrictJSON.parse('{"field":"\u0000\n\t"}'))
  end

  def test_rejects_duplicate_keys_and_nonfinite_numbers
    ['{"x":1,"x":2}', '{"x":1,"\u0078":2}', 'NaN', '[Infinity]', '{"x":-Infinity}', '{"x":1e9999}'].each do |source|
      assert_raises(JSON::ParserError, source) { StrictJSON.parse(source) }
    end
  end

  def test_fails_closed_when_duplicate_key_option_is_unsupported
    supported = StrictJSON::DUPLICATE_KEYS_REJECTED
    StrictJSON.send(:remove_const, :DUPLICATE_KEYS_REJECTED)
    StrictJSON.const_set(:DUPLICATE_KEYS_REJECTED, false)
    assert_raises(StrictJSON::Error) { StrictJSON.parse('{}') }
  ensure
    StrictJSON.send(:remove_const, :DUPLICATE_KEYS_REJECTED)
    StrictJSON.const_set(:DUPLICATE_KEYS_REJECTED, supported)
  end

  def test_preserves_supported_byte_encodings_and_rejects_malformed_ones
    json = JSON.generate('field' => 'café 😀')
    %w[UTF-8 UTF-16BE UTF-16LE UTF-32BE UTF-32LE].each do |encoding|
      encoded = json.encode(encoding).b
      bom = "\uFEFF".encode(encoding).b
      [encoded, bom + encoded].each { |bytes| assert_equal({ 'field' => 'café 😀' }, StrictJSON.parse(bytes)) }
    end
    ["\x00".b, "\xff\xfe{\0\xff".b, "{\"field\":\"\xff\"}".b].each do |bytes|
      assert_raises(JSON::ParserError) { StrictJSON.parse(bytes) }
    end
  end

  def test_bounds_nesting_and_validates_deep_values_without_ruby_recursion
    value = StrictJSON.parse('[' * 999 + '0' + ']' * 999)
    999.times { value = value.first }
    assert_equal(0, value)
    assert_raises(JSON::ParserError) { StrictJSON.parse('[' * 1001 + '0' + ']' * 1001) }
    assert_raises(ArgumentError) { StrictJSON.parse('{}', max_nesting: false) }
  end
end
