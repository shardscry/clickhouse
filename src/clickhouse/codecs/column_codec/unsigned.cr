class ClickHouse::Codecs::ColumnCodec
  private def read_unsigned(type : Types::Type, rows : Int32) : Array(Value)
    case type.name
    when "UInt8"
      Array(Value).new(rows) { Value.new(reader.read(UInt8)) }
    when "UInt16"
      Array(Value).new(rows) { Value.new(reader.read(UInt16)) }
    when "UInt32"
      Array(Value).new(rows) { Value.new(reader.read(UInt32)) }
    when "UInt64"
      Array(Value).new(rows) { Value.new(reader.read(UInt64)) }
    when "UInt128"
      Array(Value).new(rows) { Value.new(reader.read(UInt128)) }
    else
      raise CodecError.new("unsupported unsigned type #{type.name}")
    end
  end

  private def write_unsigned(type : Types::Type, values : Array(Value)) : Nil
    case type.name
    when "UInt8"
      values.each { |value| writer.write(value.as_u128.to_u8) }
    when "UInt16"
      values.each { |value| writer.write(value.as_u128.to_u16) }
    when "UInt32"
      values.each { |value| writer.write(value.as_u128.to_u32) }
    when "UInt64"
      values.each { |value| writer.write(value.as_u128.to_u64) }
    when "UInt128"
      values.each { |value| writer.write(value.as_u128.to_u128) }
    else
      raise CodecError.new("unsupported unsigned type #{type.name}")
    end
  end
end
