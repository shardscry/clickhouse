require "../errors"

class ClickHouse::Protocol::Writer
  getter io : IO

  def initialize(@io : IO)
  end

  def write(value : T) : Nil forall T
    @io.write_bytes(value, IO::ByteFormat::LittleEndian)
  end

  def var_uint(value : Int) : Nil
    raise ArgumentError.new("VarUInt cannot be negative") if value < 0
    remaining = value.to_u64
    while remaining >= 0x80
      write((remaining.to_u8! & 0x7f) | 0x80_u8)
      remaining >>= 7
    end
    write(remaining.to_u8)
  end

  def string(value : String) : Nil
    var_uint(value.bytesize)
    bytes(value.to_slice)
  end

  def bytes(value : Bytes) : Nil
    @io.write(value)
  end
end
