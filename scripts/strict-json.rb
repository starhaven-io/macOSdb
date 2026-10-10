# frozen_string_literal: true

require 'json'

module StrictJSON
  class Error < JSON::ParserError; end

  module_function

  def duplicate_keys_rejected?
    JSON.parse('{"key": 1, "key": 2}', allow_duplicate_key: false)
    false
  rescue JSON::ParserError
    true
  end

  DUPLICATE_KEYS_REJECTED = duplicate_keys_rejected?

  def parse(data, max_nesting: 1000)
    unless DUPLICATE_KEYS_REJECTED
      raise Error, 'the JSON parser must support rejection of duplicate object keys; update Ruby'
    end
    unless max_nesting.is_a?(Integer) && max_nesting.positive?
      raise ArgumentError, 'JSON nesting must have a positive bound'
    end

    text = decode(data)
    result = JSON.parse(text, allow_duplicate_key: false, allow_nan: true, max_nesting: max_nesting)
    reject_comments(text)
    validate_values(result)
    result
  rescue EncodingError => error
    raise Error, "invalid JSON Unicode: #{error.message}"
  end

  def decode(data)
    # Preserve the JSON reader's UTF-8/16/32 byte detection, including BOMs.
    bytes = data.b
    encoding, prefix = if bytes.start_with?("\x00\x00\xfe\xff".b)
      [Encoding::UTF_32BE, 4]
    elsif bytes.start_with?("\xff\xfe\x00\x00".b)
      [Encoding::UTF_32LE, 4]
    elsif bytes.start_with?("\xfe\xff".b)
      [Encoding::UTF_16BE, 2]
    elsif bytes.start_with?("\xff\xfe".b)
      [Encoding::UTF_16LE, 2]
    elsif bytes.start_with?("\xef\xbb\xbf".b)
      [Encoding::UTF_8, 3]
    elsif bytes.bytesize >= 4 && bytes.getbyte(0).zero?
      [bytes.getbyte(1).zero? ? Encoding::UTF_32BE : Encoding::UTF_16BE, 0]
    elsif bytes.bytesize >= 4 && bytes.getbyte(1).zero?
      [bytes.getbyte(2).zero? && bytes.getbyte(3).zero? ? Encoding::UTF_32LE : Encoding::UTF_16LE, 0]
    elsif bytes.bytesize == 2 && bytes.getbyte(0).zero?
      [Encoding::UTF_16BE, 0]
    elsif bytes.bytesize == 2 && bytes.getbyte(1).zero?
      [Encoding::UTF_16LE, 0]
    else
      [Encoding::UTF_8, 0]
    end
    text = bytes.byteslice(prefix..).force_encoding(encoding)
    raise Encoding::InvalidByteSequenceError, "invalid #{encoding} JSON data" unless text.valid_encoding?

    text.encode(Encoding::UTF_8)
  end

  def reject_comments(text)
    # Ruby's JSON parser accepts comments regardless of its parser options.
    quoted = false
    escaped = false
    text.each_byte do |byte|
      if quoted
        if escaped
          escaped = false
        elsif byte == 92
          escaped = true
        elsif byte == 34
          quoted = false
        end
      elsif byte == 34
        quoted = true
      elsif byte == 47
        raise Error, 'JSON comments are not allowed'
      end
    end
  end

  def validate_values(result)
    pending = [result]
    until pending.empty?
      value = pending.pop
      case value
      when String
        # The parser can emit invalid UTF-8 for an escaped lone low surrogate.
        raise Error, 'invalid JSON Unicode string' unless value.valid_encoding?
      when Float
        raise Error, "non-finite JSON number #{value}" unless value.finite?
      when Hash
        value.each { |key, child| pending << key << child }
      when Array
        pending.concat(value)
      end
    end
  end
end
