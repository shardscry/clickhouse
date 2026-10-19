require "./error"

# Raw LZ4 blocks, without LZ4 file framing or dictionaries.
module ClickHouse::Compression::LZ4
  extend self

  def compress(input : Bytes) : Bytes
    output = IO::Memory.new
    positions = Array(Int32).new(65_536, -1)
    cursor = anchor = 0
    # Preserve LZ4's last-five-literals and last-match-start restrictions.
    while cursor <= input.size - 12
      sequence = IO::ByteFormat::LittleEndian.decode(UInt32, input[cursor, 4])
      slot = ((sequence &* 2_654_435_761_u32) >> 16).to_i
      previous = positions[slot]
      positions[slot] = cursor
      if previous < 0 || cursor - previous > UInt16::MAX || input[previous, 4] != input[cursor, 4]
        cursor += 1
        next
      end

      length = 4
      while cursor + length < input.size - 5 && input[previous + length] == input[cursor + length]
        length += 1
      end
      write_sequence(output, input[anchor, cursor - anchor], cursor - previous, length)
      cursor += length
      anchor = cursor
    end
    write_literals(output, input[anchor, input.size - anchor])
    output.to_slice.dup
  end

  def decompress(input : Bytes, expected_size : Int32) : Bytes
    raise Error.new("negative LZ4 output size") if expected_size < 0
    output = Bytes.new(expected_size)
    source = target = 0
    complete = false
    last_match_start = -1
    while source < input.size
      token = input[source]
      source += 1
      literal_size, source = length(input, source, (token >> 4).to_i, expected_size)
      if literal_size > input.size - source || literal_size > output.size - target
        raise Error.new("LZ4 literal exceeds block bounds")
      end
      output[target, literal_size].copy_from(input[source, literal_size])
      source += literal_size
      target += literal_size
      if source == input.size
        validate_final_sequence(last_match_start, literal_size, expected_size)
        complete = true
        break
      end

      raise Error.new("truncated LZ4 offset") if input.size - source < 2
      distance = IO::ByteFormat::LittleEndian.decode(UInt16, input[source, 2]).to_i
      source += 2
      raise Error.new("invalid LZ4 match offset") if distance == 0 || distance > target
      match_size, source = length(input, source, (token & 15).to_i, expected_size)
      match_size += 4
      raise Error.new("LZ4 match exceeds output bounds") if match_size > output.size - target
      last_match_start = target
      # Matches can overlap: later bytes must see earlier copied bytes.
      match_size.times do
        output[target] = output[target - distance]
        target += 1
      end
    end
    raise Error.new("missing LZ4 final sequence") unless complete
    raise Error.new("LZ4 output size differs from frame size") unless target == expected_size
    output
  end

  private def validate_final_sequence(last_match_start : Int32, literal_size : Int32, expected_size : Int32) : Nil
    return if last_match_start < 0
    if literal_size < 5 || last_match_start > expected_size - 12
      raise Error.new("invalid LZ4 final sequence")
    end
  end

  private def length(input : Bytes, cursor : Int32, initial : Int32, limit : Int32) : Tuple(Int32, Int32)
    value = initial
    if initial == 15
      loop do
        raise Error.new("truncated LZ4 length") if cursor == input.size
        part = input[cursor].to_i
        cursor += 1
        raise Error.new("LZ4 length exceeds output bounds") if part > limit - value
        value += part
        break if part != 255
      end
    end
    {value, cursor}
  end

  private def write_sequence(output : IO, literals : Bytes, distance : Int32, match_size : Int32) : Nil
    match_length = match_size - 4
    token = (Math.min(literals.size, 15) << 4) | Math.min(match_length, 15)
    output.write_byte(token.to_u8)
    write_length(output, literals.size - 15) if literals.size >= 15
    output.write(literals)
    output.write_bytes(distance.to_u16, IO::ByteFormat::LittleEndian)
    write_length(output, match_length - 15) if match_length >= 15
  end

  private def write_literals(output : IO, literals : Bytes) : Nil
    output.write_byte((Math.min(literals.size, 15) << 4).to_u8)
    write_length(output, literals.size - 15) if literals.size >= 15
    output.write(literals)
  end

  private def write_length(output : IO, size : Int32) : Nil
    while size >= 255
      output.write_byte(255_u8)
      size -= 255
    end
    output.write_byte(size.to_u8)
  end
end
