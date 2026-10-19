class ClickHouse::Codecs::ColumnCodec
  private def read_enum(type : Types::Type, rows : Int32, nulls : Bytes? = nil) : Array(Value)
    labels = type.enum_values.invert
    Array(Value).new(rows) do |index|
      code = type.name == "Enum8" ? reader.read(Int8).to_i16 : reader.read(Int16)
      label = labels[code]?
      unless label
        raise CodecError.new("unknown #{type.name} code #{code}") unless nulls && nulls[index] != 0
        label = ""
      end
      Value.new(EnumValue.new(code, label))
    end
  end

  private def write_enum(type : Types::Type, values : Array(Value)) : Nil
    values.each do |value|
      raw = value.raw
      code = raw.is_a?(EnumValue) ? raw.code : type.enum_values[value.as_s]? || raise CodecError.new("unknown enum label")
      raise CodecError.new("unknown enum code") unless type.enum_values.has_value?(code)
      type.name == "Enum8" ? writer.write(code.to_i8) : writer.write(code)
    end
  end
end
