require "../errors"

class ClickHouse::Protocol::Reader
  getter io : IO
  getter bytes_read : UInt64 = 0_u64

  def initialize(@io : IO, @max_string_bytes : Int32 = 64 * 1024 * 1024)
    raise ArgumentError.new("max_string_bytes must be positive") unless @max_string_bytes > 0
  end

  def read(type : T.class) : T forall T
    value = @io.read_bytes(type, IO::ByteFormat::LittleEndian)
    @bytes_read += sizeof(T)
    value
  end

  def var_uint : UInt64
    value = 0_u64
    10.times do |index|
      byte = read(UInt8)
      if index == 9 && byte > 1
        raise ClickHouse::ProtocolError.new("VarUInt exceeds UInt64")
      end
      value |= (byte & 0x7f).to_u64 << (index * 7)
      return value if byte < 0x80
    end
    raise ClickHouse::ProtocolError.new("unterminated VarUInt")
  end

  def bytes(size : Int) : Bytes
    unless 0 <= size <= @max_string_bytes
      raise ClickHouse::ProtocolError.new("byte string exceeds configured limit")
    end
    result = Bytes.new(size.to_i)
    @io.read_fully(result)
    @bytes_read += size
    result
  end

  def string : String
    size = var_uint
    raise ClickHouse::ProtocolError.new("string exceeds configured limit") if size > @max_string_bytes
    String.new(bytes(size.to_i))
  end

  def bool : Bool
    value = read(UInt8)
    raise ClickHouse::ProtocolError.new("invalid boolean byte #{value}") if value > 1
    value == 1
  end
end
