class ClickHouse::Codecs::ColumnCodec
  private def read_simple(type : Types::Type, rows : Int32) : Array(Value)
    case type.name
    when "Bool"
      Array(Value).new(rows) { Value.new(reader.read(UInt8) != 0) }
    when "String"
      Array(Value).new(rows) { Value.new(read_string) }
    when "FixedString"
      width = type.parameters[0].to_i
      byte_count = width.to_i64 * rows
      raise CodecError.new("FixedString exceeds block byte budget") if byte_count > @remaining_bytes
      @remaining_bytes -= byte_count.to_i32
      Array(Value).new(rows) { Value.new(reader.bytes(width)) }
    when "Nothing"
      reader.bytes(rows)
      Array(Value).new(rows) { Value.new(nil) }
    else
      raise CodecError.new("unsupported simple type #{type.name}")
    end
  end

  private def write_simple(type : Types::Type, values : Array(Value)) : Nil
    case type.name
    when "Bool"
      values.each { |value| writer.write(value.as_bool ? 1_u8 : 0_u8) }
    when "String"
      values.each { |value| write_string(value.as_bytes) }
    when "FixedString"
      width = type.parameters[0].to_i
      values.each do |value|
        bytes = value.as_bytes
        raise CodecError.new("FixedString value exceeds width") if bytes.size > width
        consume_bytes(width)
        writer.bytes(bytes)
        writer.bytes(Bytes.new(width - bytes.size, 0))
      end
    when "Nothing"
      values.each { |value| raise CodecError.new("Nothing can only encode null") unless value.null? }
      writer.bytes(Bytes.new(values.size, '0'.ord.to_u8))
    else
      raise CodecError.new("unsupported simple type #{type.name}")
    end
  end
end
