class ClickHouse::Codecs::ColumnCodec
  private def read_decimal(type : Types::Type, rows : Int32) : Array(Value)
    precision, scale = decimal_parameters(type)
    Array(Value).new(rows) do
      raw = precision <= 9 ? reader.read(Int32).to_i128 : precision <= 18 ? reader.read(Int64).to_i128 : reader.read(Int128)
      Value.new(Decimal.new(raw, scale))
    end
  end

  private def write_decimal(type : Types::Type, values : Array(Value)) : Nil
    precision, scale = decimal_parameters(type)
    limit = 10_i128 ** precision
    values.each do |value|
      decimal = value.as_decimal
      raise CodecError.new("decimal scale differs from column") unless decimal.scale == scale
      raise CodecError.new("decimal exceeds column precision") unless -limit < decimal.unscaled < limit
      if precision <= 9
        writer.write(decimal.unscaled.to_i32)
      elsif precision <= 18
        writer.write(decimal.unscaled.to_i64)
      else
        writer.write(decimal.unscaled)
      end
    end
  end
end
