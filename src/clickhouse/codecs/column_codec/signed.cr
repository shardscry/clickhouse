class ClickHouse::Codecs::ColumnCodec
  private def read_signed(type : Types::Type, rows : Int32) : Array(Value)
    case type.name
    when "Int8"
      Array(Value).new(rows) { Value.new(reader.read(Int8)) }
    when "Int16"
      Array(Value).new(rows) { Value.new(reader.read(Int16)) }
    when "Int32"
      Array(Value).new(rows) { Value.new(reader.read(Int32)) }
    when "Int64"
      Array(Value).new(rows) { Value.new(reader.read(Int64)) }
    when "Int128"
      Array(Value).new(rows) { Value.new(reader.read(Int128)) }
    else
      raise CodecError.new("unsupported signed type #{type.name}")
    end
  end

  private def write_signed(type : Types::Type, values : Array(Value)) : Nil
    case type.name
    when "Int8"
      values.each { |value| writer.write(value.as_i128.to_i8) }
    when "Int16"
      values.each { |value| writer.write(value.as_i128.to_i16) }
    when "Int32"
      values.each { |value| writer.write(value.as_i128.to_i32) }
    when "Int64"
      values.each { |value| writer.write(value.as_i128.to_i64) }
    when "Int128"
      values.each { |value| writer.write(value.as_i128.to_i128) }
    else
      raise CodecError.new("unsupported signed type #{type.name}")
    end
  end
end
