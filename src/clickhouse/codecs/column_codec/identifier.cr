class ClickHouse::Codecs::ColumnCodec
  private def read_identifier(type : Types::Type, rows : Int32) : Array(Value)
    case type.name
    when "UUID"
      Array(Value).new(rows) do
        bytes = reader.bytes(16)
        canonical = StaticArray(UInt8, 16).new { |index| bytes[(index // 8) * 8 + 7 - index % 8] }
        Value.new(UUID.new(canonical))
      end
    when "IPv4"
      Array(Value).new(rows) { Value.new(IPv4.new(reader.read(UInt32))) }
    when "IPv6"
      Array(Value).new(rows) do
        bytes = reader.bytes(16)
        Value.new(IPv6.new(StaticArray(UInt8, 16).new { |index| bytes[index] }))
      end
    else
      raise CodecError.new("unsupported identifier type #{type.name}")
    end
  end

  private def write_identifier(type : Types::Type, values : Array(Value)) : Nil
    case type.name
    when "UUID"
      values.each do |value|
        bytes = value.as_uuid.bytes
        writer.bytes(Bytes.new(16) { |index| bytes[(index // 8) * 8 + 7 - index % 8] })
      end
    when "IPv4"
      values.each { |value| writer.write(value.raw.as(IPv4).address) }
    when "IPv6"
      values.each { |value| writer.bytes(value.raw.as(IPv6).bytes.to_slice) }
    else
      raise CodecError.new("unsupported identifier type #{type.name}")
    end
  end
end
