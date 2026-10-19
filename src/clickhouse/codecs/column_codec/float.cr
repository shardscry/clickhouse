class ClickHouse::Codecs::ColumnCodec
  private def read_float(type : Types::Type, rows : Int32) : Array(Value)
    case type.name
    when "Float32"
      Array(Value).new(rows) { Value.new(reader.read(Float32)) }
    when "Float64"
      Array(Value).new(rows) { Value.new(reader.read(Float64)) }
    else
      raise CodecError.new("unsupported float type #{type.name}")
    end
  end

  private def write_float(type : Types::Type, values : Array(Value)) : Nil
    case type.name
    when "Float32"
      values.each { |value| writer.write(value.as_f64.to_f32) }
    when "Float64"
      values.each { |value| writer.write(value.as_f64) }
    else
      raise CodecError.new("unsupported float type #{type.name}")
    end
  end
end
