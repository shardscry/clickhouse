require "uuid"
require "socket"
require "./errors"

class ClickHouse::CodecError < ClickHouse::Error
end

record ClickHouse::Decimal, unscaled : Int128, scale : Int32 do
  def initialize(@unscaled : Int128, @scale : Int32)
    raise ArgumentError.new("decimal scale must be between 0 and 38") unless (0..38).includes?(@scale)
  end
end

record ClickHouse::Timestamp, ticks : Int64, precision : Int32, timezone : String? = nil do
  def initialize(@ticks : Int64, @precision : Int32, @timezone : String? = nil)
    raise ArgumentError.new("timestamp precision must be between 0 and 9") unless (0..9).includes?(@precision)
  end

  def to_time : Time
    divisor = 10_i64 ** precision
    seconds = ticks // divisor
    nanos = (ticks % divisor) * (1_000_000_000_i64 // divisor)
    Time.unix(seconds) + nanos.nanoseconds
  end
end

record ClickHouse::DateValue, days : Int32 do
  def to_time : Time
    Time.unix(days.to_i64 * 86_400)
  end
end

record ClickHouse::IPv4, address : UInt32 do
  def to_s(io : IO) : Nil
    io << ((address >> 24) & 255) << '.' << ((address >> 16) & 255) << '.'
    io << ((address >> 8) & 255) << '.' << (address & 255)
  end
end

record ClickHouse::IPv6, bytes : StaticArray(UInt8, 16) do
  def to_s(io : IO) : Nil
    8.times do |index|
      io << ':' unless index == 0
      io << ((bytes[index * 2].to_u16 << 8) | bytes[index * 2 + 1]).to_s(16)
    end
  end
end

record ClickHouse::EnumValue, code : Int16, label : String
record ClickHouse::TupleValue, values : Array(ClickHouse::Value), names : Array(String?) = [] of String?
record ClickHouse::MapValue, entries : Array(Tuple(ClickHouse::Value, ClickHouse::Value))

class ClickHouse::Value
  alias Integer = Int8 | Int16 | Int32 | Int64 | Int128 | UInt8 | UInt16 | UInt32 | UInt64 | UInt128
  alias Data = (Bool | Integer | Float32 | Float64 | String | Bytes | UUID | Decimal | Timestamp | DateValue | IPv4 | IPv6 | EnumValue | Array(Value) | TupleValue | MapValue)?

  getter raw : Data

  def initialize(value : Data)
    @raw = value.is_a?(Bytes) ? value.dup : value
  end

  def self.wrap(value : Value) : Value
    value
  end

  def self.wrap(value : Data) : Value
    new(value)
  end

  def self.wrap(value : Array(T)) : Value forall T
    new(value.map { |item| wrap(item) })
  end

  def self.wrap(value : Tuple) : Value
    new(TupleValue.new(value.to_a.map { |item| wrap(item) }))
  end

  def self.wrap(value : Hash(K, V)) : Value forall K, V
    new(MapValue.new(value.map { |key, item| {wrap(key), wrap(item)} }))
  end

  def null? : Bool
    @raw.nil?
  end

  def as_u128 : UInt128
    value = @raw
    raise CodecError.new("expected an integer, got #{value.class}") unless value.is_a?(Integer)
    value.to_u128
  end

  def as_i128 : Int128
    value = @raw
    raise CodecError.new("expected an integer, got #{value.class}") unless value.is_a?(Integer)
    value.to_i128
  end

  def as_u64 : UInt64
    as_u128.to_u64
  end

  def as_i64 : Int64
    as_i128.to_i64
  end

  def as_f64 : Float64
    value = @raw
    raise CodecError.new("expected a floating-point value") unless value.is_a?(Float32 | Float64)
    value.to_f64
  end

  def as_s : String
    value = @raw
    case value
    when String    then value
    when Bytes     then String.new(value)
    when EnumValue then value.label
    else                raise CodecError.new("expected a string, got #{value.class}")
    end
  end

  def as_bytes : Bytes
    value = @raw
    case value
    when Bytes  then value.dup
    when String then value.to_slice.dup
    else             raise CodecError.new("expected binary string data")
    end
  end

  def as_bool : Bool
    @raw.as(Bool)
  end

  def as_array : Array(Value)
    @raw.as(Array(Value))
  end

  def as_tuple : TupleValue
    @raw.as(TupleValue)
  end

  def as_map : MapValue
    @raw.as(MapValue)
  end

  def as_decimal : Decimal
    @raw.as(Decimal)
  end

  def as_timestamp : Timestamp
    @raw.as(Timestamp)
  end

  def as_uuid : UUID
    @raw.as(UUID)
  end

  def ==(other : Value) : Bool
    @raw == other.raw
  end

  def hash(hasher)
    @raw.hash(hasher)
  end
end
