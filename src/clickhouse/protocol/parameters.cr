require "../value"

module ClickHouse::Protocol::Parameters
  def self.encode(values) : Hash(String, String)
    result = {} of String => String
    values.each do |key, value|
      name = key.to_s
      raise ArgumentError.new("invalid parameter name #{name}") unless /\A[a-zA-Z_][a-zA-Z_0-9]*\z/.matches?(name)
      result[name] = quote(text(value))
    end
    result
  end

  def self.text(value : ClickHouse::Value) : String
    text(value.raw)
  end

  def self.text(value : Nil) : String
    "\\N"
  end

  def self.text(value : String) : String
    escape(value, false)
  end

  def self.text(value : Bytes) : String
    text(String.new(value))
  end

  def self.text(value : Bool) : String
    value ? "1" : "0"
  end

  def self.text(value : Int | Float) : String
    value.to_s
  end

  def self.text(value : UUID | ClickHouse::IPv4 | ClickHouse::IPv6) : String
    value.to_s
  end

  def self.text(value : ClickHouse::EnumValue) : String
    text(value.label)
  end

  def self.text(value : ClickHouse::Decimal) : String
    scaled(value.unscaled, value.scale)
  end

  def self.text(value : ClickHouse::Timestamp) : String
    temporal_text(value.ticks.to_i128, value.precision)
  end

  def self.text(value : ClickHouse::DateValue) : String
    value.to_time.to_s("%F")
  end

  def self.text(value : Time) : String
    precision = if value.nanosecond == 0
                  0
                elsif value.nanosecond % 1_000_000 == 0
                  3
                elsif value.nanosecond % 1000 == 0
                  6
                else
                  9
                end
    divisor = 10_i128 ** precision
    ticks = value.to_unix.to_i128 * divisor + value.nanosecond // (1_000_000_000_i128 // divisor)
    temporal_text(ticks, precision)
  end

  def self.text(value : Array) : String
    "[" + value.map { |item| nested(item) }.join(",") + "]"
  end

  def self.text(value : Tuple) : String
    "(" + value.to_a.map { |item| nested(item) }.join(",") + ")"
  end

  def self.text(value : ClickHouse::TupleValue) : String
    "(" + value.values.map { |item| nested(item) }.join(",") + ")"
  end

  def self.text(value : Hash) : String
    "{" + value.map { |key, item| "#{nested(key)}:#{nested(item)}" }.join(",") + "}"
  end

  def self.text(value : ClickHouse::MapValue) : String
    "{" + value.entries.map { |pair| "#{nested(pair[0])}:#{nested(pair[1])}" }.join(",") + "}"
  end

  private def self.nested(value : ClickHouse::Value) : String
    nested(value.raw)
  end

  private def self.nested(value : Nil) : String
    "NULL"
  end

  private def self.nested(value : ClickHouse::EnumValue) : String
    nested(value.label)
  end

  private def self.nested(value : ClickHouse::DateValue) : String
    quote(text(value))
  end

  private def self.nested(value : String | Bytes | UUID | ClickHouse::IPv4 | ClickHouse::IPv6) : String
    raw = value.is_a?(Bytes) ? String.new(value) : value.to_s
    quote(raw)
  end

  private def self.nested(value) : String
    text(value)
  end

  private def self.scaled(value : Int128, scale : Int32) : String
    return value.to_s if scale == 0
    digits = value.to_s
    negative = digits.starts_with?('-')
    digits = digits[1..] if negative
    digits = digits.rjust(scale + 1, '0')
    "#{negative ? "-" : ""}#{digits[0...-scale]}.#{digits[-scale..]}"
  end

  private def self.temporal_text(ticks : Int128, precision : Int32) : String
    if ticks < 0 && ticks > -(10_i128 ** precision)
      raise ArgumentError.new("ClickHouse misparses DateTime64 parameters between -1 and 0 seconds; pass Int64 ticks with fromUnixTimestamp64Nano/Micro/Milli")
    end
    scaled(ticks, precision)
  end

  private def self.quote(value : String) : String
    "'" + escape(value, true) + "'"
  end

  private def self.escape(value : String, quoted : Bool) : String
    String.build do |io|
      value.each_byte do |byte|
        case byte
        when 0x5c then io << "\\\\"
        when 0x09 then io << "\\t"
        when 0x0a then io << "\\n"
        when 0x0d then io << "\\r"
        when 0x00 then io << "\\0"
        when 0x08 then io << "\\b"
        when 0x0c then io << "\\f"
        when 0x27
          io << '\\' if quoted
          io.write_byte(byte)
        else
          io.write_byte(byte)
        end
      end
    end
  end
end
