require "../types/parser"
require "../protocol/reader"
require "../protocol/writer"

class ClickHouse::Codecs::ColumnCodec
  MAX_VALUES = 1_000_000
  MAX_BYTES  = 64 * 1024 * 1024

  def initialize(@reader : Protocol::Reader? = nil, @writer : Protocol::Writer? = nil)
    @remaining_values = MAX_VALUES
    @remaining_bytes = MAX_BYTES
  end

  def read_string(maximum : Int32 = MAX_BYTES) : String
    length = reader.var_uint
    raise CodecError.new("string exceeds block byte budget") if length > maximum || length > @remaining_bytes
    @remaining_bytes -= length.to_i32
    String.new(reader.bytes(length.to_i32))
  end

  def read(type : Types::Type, rows : Int32) : Array(Value)
    validate(type)
    read_state(type) if rows > 0
    read_data(type, rows)
  end

  def write(type : Types::Type, values : Array(Value)) : Nil
    validate(type)
    write_state(type) unless values.empty?
    write_data(type, values)
  end

  def validate(type : Types::Type) : Nil
    case type.name
    when "UInt8", "UInt16", "UInt32", "UInt64", "UInt128", "Int8", "Int16", "Int32", "Int64", "Int128",
         "Float32", "Float64", "Bool", "String", "Nothing", "Date", "Date32", "UUID", "IPv4", "IPv6"
      expect_arguments(type, 0, 0)
    when "FixedString"
      validate_fixed_string(type)
    when "DateTime", "DateTime64"
      validate_time(type)
    when "Decimal", "Decimal32", "Decimal64", "Decimal128"
      validate_decimal(type)
    when "Enum8", "Enum16"
      validate_enum(type)
    when "Array", "Nullable", "LowCardinality"
      expect_arguments(type, 1, 0)
    when "Map"
      expect_arguments(type, 2, 0)
    when "Tuple"
      raise CodecError.new("invalid Tuple arguments") unless type.parameters.empty?
    else
      raise CodecError.new("unsupported ClickHouse type #{type.name}")
    end
    type.children.each { |child| validate(child) }
  rescue ex : ArgumentError | OverflowError
    raise CodecError.new("invalid type parameter: #{ex.message}")
  end

  private def validate_fixed_string(type : Types::Type) : Nil
    expect_arguments(type, 0, 1)
    size = type.parameters[0].to_i
    raise CodecError.new("invalid FixedString width") unless (1..MAX_BYTES).includes?(size)
  end

  private def validate_time(type : Types::Type) : Nil
    raise CodecError.new("invalid timestamp arguments") unless type.children.empty?
    if type.name == "DateTime"
      raise CodecError.new("invalid DateTime arguments") if type.parameters.size > 1
    else
      raise CodecError.new("invalid DateTime64 arguments") unless (1..2).includes?(type.parameters.size)
      raise CodecError.new("invalid DateTime64 precision") unless (0..9).includes?(type.parameters[0].to_i)
    end
  end

  private def validate_decimal(type : Types::Type) : Nil
    precision, scale = decimal_parameters(type)
    raise CodecError.new("unsupported decimal precision/scale") unless (1..38).includes?(precision) && (0..precision).includes?(scale)
  end

  private def validate_enum(type : Types::Type) : Nil
    raise CodecError.new("invalid enum arguments") unless type.children.empty? && type.parameters.empty?
    raise CodecError.new("enum has no values") if type.enum_values.empty?
    if type.name == "Enum8" && type.enum_values.values.any? { |value| value < Int8::MIN || value > Int8::MAX }
      raise CodecError.new("Enum8 code is outside Int8 range")
    end
  end

  private def expect_arguments(type : Types::Type, children : Int32, parameters : Int32) : Nil
    unless type.children.size == children && type.parameters.size == parameters
      raise CodecError.new("invalid #{type.name} arguments")
    end
  end

  private def reader : Protocol::Reader
    @reader || raise CodecError.new("codec has no reader")
  end

  private def writer : Protocol::Writer
    @writer || raise CodecError.new("codec has no writer")
  end

  private def reserve(rows : Int32) : Nil
    raise CodecError.new("column exceeds block value budget") if rows < 0 || rows > @remaining_values
    @remaining_values -= rows
  end

  private def read_state(type : Types::Type) : Nil
    if type.name == "LowCardinality"
      version = reader.read(Int64)
      raise CodecError.new("unsupported LowCardinality serialization version #{version}") unless version == 1
    end
    type.children.each { |child| read_state(child) }
  end

  private def write_state(type : Types::Type) : Nil
    writer.write(1_i64) if type.name == "LowCardinality"
    type.children.each { |child| write_state(child) }
  end

  private def read_data(type : Types::Type, rows : Int32, nulls : Bytes? = nil) : Array(Value)
    reserve(rows)
    return [] of Value if rows == 0
    case type.name
    when "UInt8", "UInt16", "UInt32", "UInt64", "UInt128", "Int8", "Int16", "Int32", "Int64", "Int128", "Float32", "Float64"
      read_numeric(type, rows)
    when "Bool", "String", "FixedString", "Nothing"
      read_simple(type, rows)
    when "Nullable", "Array", "Tuple", "Map"
      read_composite(type, rows)
    when "Date", "Date32", "DateTime", "DateTime64"
      read_time(type, rows)
    when "UUID", "IPv4", "IPv6"
      read_identifier(type, rows)
    when "Enum8", "Enum16"
      read_enum(type, rows, nulls)
    when "Decimal", "Decimal32", "Decimal64", "Decimal128"
      read_decimal(type, rows)
    when "LowCardinality"
      read_low_cardinality(type, rows)
    else
      raise CodecError.new("unsupported ClickHouse type #{type.name}")
    end
  end

  private def read_numeric(type : Types::Type, rows : Int32) : Array(Value)
    if type.name.starts_with?("UInt")
      read_unsigned(type, rows)
    elsif type.name.starts_with?("Int")
      read_signed(type, rows)
    else
      read_float(type, rows)
    end
  end

  private def read_offsets(rows : Int32) : Array(UInt64)
    previous = 0_u64
    Array(UInt64).new(rows) do
      offset = reader.read(UInt64)
      raise CodecError.new("invalid or oversized cumulative offset") if offset < previous || offset > MAX_VALUES
      previous = offset
      offset
    end
  end

  private def read_low_cardinality(type : Types::Type, rows : Int32) : Array(Value)
    metadata = reader.read(UInt64)
    key_type = metadata & 255
    validate_dictionary_metadata(metadata)
    count = reader.read(UInt64)
    raise CodecError.new("LowCardinality dictionary too large") if count > MAX_VALUES
    inner = type.children[0]
    nullable = inner.name == "Nullable"
    inner = inner.children[0] if nullable
    nulls = nullable ? Bytes.new(count.to_i32) { |index| index == 0 ? 1_u8 : 0_u8 } : nil
    dictionary = read_data(inner, count.to_i32, nulls)
    keys_count = reader.read(UInt64)
    raise CodecError.new("LowCardinality key count differs from column size") unless keys_count == rows
    Array(Value).new(rows) do
      key = read_dictionary_key(key_type)
      raise CodecError.new("LowCardinality dictionary index out of bounds") if key >= dictionary.size
      nullable && key == 0 ? Value.new(nil) : dictionary[key.to_i32]
    end
  end

  private def validate_dictionary_metadata(metadata : UInt64) : Nil
    unless metadata & 255 <= 3 && metadata & 0x100 == 0 && metadata & 0x600 == 0x600 && metadata & ~0x6ff_u64 == 0
      raise CodecError.new("unsupported LowCardinality dictionary metadata")
    end
  end

  private def read_dictionary_key(key_type : UInt64) : UInt64
    case key_type
    when 0 then reader.read(UInt8).to_u64
    when 1 then reader.read(UInt16).to_u64
    when 2 then reader.read(UInt32).to_u64
    else        reader.read(UInt64)
    end
  end

  private def write_data(type : Types::Type, values : Array(Value)) : Nil
    reserve(values.size)
    return if values.empty?
    case type.name
    when "UInt8", "UInt16", "UInt32", "UInt64", "UInt128", "Int8", "Int16", "Int32", "Int64", "Int128", "Float32", "Float64"
      write_numeric(type, values)
    when "Bool", "String", "FixedString", "Nothing"
      write_simple(type, values)
    when "Nullable", "Array", "Tuple", "Map"
      write_composite(type, values)
    when "Date", "Date32", "DateTime", "DateTime64"
      write_time(type, values)
    when "UUID", "IPv4", "IPv6"
      write_identifier(type, values)
    when "Enum8", "Enum16"
      write_enum(type, values)
    when "Decimal", "Decimal32", "Decimal64", "Decimal128"
      write_decimal(type, values)
    when "LowCardinality"
      write_low_cardinality(type, values)
    else
      raise CodecError.new("unsupported ClickHouse type #{type.name}")
    end
  rescue ex : OverflowError | TypeCastError
    raise CodecError.new("value is incompatible with #{type.name}: #{ex.message}")
  end

  private def write_numeric(type : Types::Type, values : Array(Value)) : Nil
    if type.name.starts_with?("UInt")
      write_unsigned(type, values)
    elsif type.name.starts_with?("Int")
      write_signed(type, values)
    else
      write_float(type, values)
    end
  end

  private def write_low_cardinality(type : Types::Type, values : Array(Value)) : Nil
    inner = type.children[0]
    nullable = inner.name == "Nullable"
    inner = inner.children[0] if nullable
    default = default_value(inner)
    dictionary = nullable ? [default, default] : [default]
    index = {default => (nullable ? 1_u64 : 0_u64)}
    keys = values.map do |value|
      if value.null?
        raise CodecError.new("null in non-nullable LowCardinality") unless nullable
        0_u64
      else
        index[value] ||= begin
          key = dictionary.size.to_u64
          dictionary << value
          key
        end
      end
    end
    key_type = dictionary.size <= 256 ? 0 : dictionary.size <= 65_536 ? 1 : 2
    writer.write(0x600_u64 | key_type.to_u64)
    writer.write(dictionary.size.to_u64)
    write_data(inner, dictionary)
    writer.write(keys.size.to_u64)
    keys.each do |key|
      case key_type
      when 0 then writer.write(key.to_u8)
      when 1 then writer.write(key.to_u16)
      else        writer.write(key.to_u32)
      end
    end
  end

  private def decimal_parameters(type : Types::Type) : Tuple(Int32, Int32)
    if type.name == "Decimal"
      expect_arguments(type, 0, 2)
      {type.parameters[0].to_i, type.parameters[1].to_i}
    else
      expect_arguments(type, 0, 1)
      precision = case type.name
                  when "Decimal32" then 9
                  when "Decimal64" then 18
                  else                  38
                  end
      {precision, type.parameters[0].to_i}
    end
  end

  private def default_value(type : Types::Type) : Value
    case type.name
    when "String", "FixedString" then Value.new("")
    when "Bool"                  then Value.new(false)
    when "Float32", "Float64"    then Value.new(0.0)
    when "Nullable", "Nothing", "Array", "Map", "Tuple", "LowCardinality"
      default_composite(type)
    when "Date", "Date32", "DateTime", "DateTime64"
      default_time(type)
    when "UUID", "IPv4", "IPv6", "Enum8", "Enum16", "Decimal", "Decimal32", "Decimal64", "Decimal128"
      default_scalar(type)
    else
      Value.new(0_i128)
    end
  end

  private def default_composite(type : Types::Type) : Value
    case type.name
    when "Nullable", "Nothing" then Value.new(nil)
    when "Array"               then Value.new([] of Value)
    when "Map"                 then Value.new(MapValue.new([] of Tuple(Value, Value)))
    when "Tuple"               then Value.new(TupleValue.new(type.children.map { |child| default_value(child) }, type.field_names))
    when "LowCardinality"      then default_value(type.children[0])
    else
      raise CodecError.new("unknown default composite")
    end
  end

  private def default_time(type : Types::Type) : Value
    case type.name
    when "Date", "Date32" then Value.new(DateValue.new(0))
    when "DateTime"       then Value.new(Timestamp.new(0_i64, 0, type.parameters.first?))
    when "DateTime64"     then Value.new(Timestamp.new(0_i64, type.parameters[0].to_i, type.parameters[1]?))
    else
      raise CodecError.new("unknown default timestamp")
    end
  end

  private def default_scalar(type : Types::Type) : Value
    case type.name
    when "Decimal", "Decimal32", "Decimal64", "Decimal128"
      Value.new(Decimal.new(0_i128, decimal_parameters(type)[1]))
    when "UUID" then Value.new(UUID.empty)
    when "IPv4" then Value.new(IPv4.new(0_u32))
    when "IPv6" then Value.new(IPv6.new(StaticArray(UInt8, 16).new(0_u8)))
    when "Enum8", "Enum16"
      label, code = type.enum_values.first
      Value.new(EnumValue.new(code, label))
    else
      Value.new(0_i128)
    end
  end

  private def consume_bytes(count : Int32) : Nil
    raise CodecError.new("column exceeds block byte budget") if count > @remaining_bytes
    @remaining_bytes -= count
  end

  private def write_string(bytes : Bytes) : Nil
    consume_bytes(bytes.size)
    writer.var_uint(bytes.size)
    writer.bytes(bytes)
  end
end

require "./column_codec/*"
