class ClickHouse::Codecs::ColumnCodec
  private def read_time(type : Types::Type, rows : Int32) : Array(Value)
    case type.name
    when "Date"
      Array(Value).new(rows) { Value.new(DateValue.new(reader.read(UInt16).to_i32)) }
    when "Date32"
      Array(Value).new(rows) { Value.new(DateValue.new(reader.read(Int32))) }
    when "DateTime"
      zone = type.parameters.first?
      Array(Value).new(rows) { Value.new(Timestamp.new(reader.read(UInt32).to_i64, 0, zone)) }
    when "DateTime64"
      precision = type.parameters[0].to_i
      zone = type.parameters[1]?
      Array(Value).new(rows) { Value.new(Timestamp.new(reader.read(Int64), precision, zone)) }
    else
      raise CodecError.new("unsupported time type #{type.name}")
    end
  end

  private def write_time(type : Types::Type, values : Array(Value)) : Nil
    case type.name
    when "Date"
      values.each { |value| writer.write(value.raw.as(DateValue).days.to_u16) }
    when "Date32"
      values.each { |value| writer.write(value.raw.as(DateValue).days) }
    when "DateTime"
      values.each do |value|
        timestamp = value.as_timestamp
        raise CodecError.new("DateTime needs precision zero") unless timestamp.precision == 0
        writer.write(timestamp.ticks.to_u32)
      end
    when "DateTime64"
      precision = type.parameters[0].to_i
      values.each do |value|
        timestamp = value.as_timestamp
        raise CodecError.new("timestamp precision differs from column") unless timestamp.precision == precision
        writer.write(timestamp.ticks)
      end
    else
      raise CodecError.new("unsupported time type #{type.name}")
    end
  end
end
