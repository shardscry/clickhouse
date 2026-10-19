class ClickHouse::Codecs::ColumnCodec
  private def read_composite(type : Types::Type, rows : Int32) : Array(Value)
    case type.name
    when "Nullable"
      read_nullable(type, rows)
    when "Array"
      read_array(type, rows)
    when "Tuple"
      read_tuple(type, rows)
    when "Map"
      read_map(type, rows)
    else
      raise CodecError.new("unsupported composite #{type.name}")
    end
  end

  private def read_nullable(type : Types::Type, rows : Int32) : Array(Value)
    nulls = reader.bytes(rows)
    values = read_data(type.children[0], rows, nulls)
    values.each_index { |index| values[index] = Value.new(nil) unless nulls[index] == 0 }
    values
  end

  private def read_array(type : Types::Type, rows : Int32) : Array(Value)
    offsets = read_offsets(rows)
    values = read_data(type.children[0], offsets.last.to_i32)
    previous = 0
    offsets.map do |offset|
      ending = offset.to_i32
      result = Value.new(values[previous, ending - previous])
      previous = ending
      result
    end
  end

  private def read_tuple(type : Types::Type, rows : Int32) : Array(Value)
    elements = type.children.map { |child| read_data(child, rows) }
    Array(Value).new(rows) do |index|
      Value.new(TupleValue.new(elements.map { |column| column[index] }, type.field_names.dup))
    end
  end

  private def read_map(type : Types::Type, rows : Int32) : Array(Value)
    offsets = read_offsets(rows)
    count = offsets.last.to_i32
    keys = read_data(type.children[0], count)
    values = read_data(type.children[1], count)
    previous = 0
    offsets.map do |offset|
      ending = offset.to_i32
      entries = Array(Tuple(Value, Value)).new(ending - previous) { |index| {keys[previous + index], values[previous + index]} }
      previous = ending
      Value.new(MapValue.new(entries))
    end
  end

  private def write_composite(type : Types::Type, values : Array(Value)) : Nil
    case type.name
    when "Nullable"
      write_nullable(type, values)
    when "Array"
      write_array(type, values)
    when "Tuple"
      write_tuple(type, values)
    when "Map"
      write_map(type, values)
    else
      raise CodecError.new("unsupported composite #{type.name}")
    end
  end

  private def write_nullable(type : Types::Type, values : Array(Value)) : Nil
    writer.bytes(Bytes.new(values.size) { |index| values[index].null? ? 1_u8 : 0_u8 })
    inner = type.children[0]
    write_data(inner, values.map { |value| value.null? ? default_value(inner) : value })
  end

  private def write_array(type : Types::Type, values : Array(Value)) : Nil
    flattened = [] of Value
    values.each do |value|
      array = value.as_array
      raise CodecError.new("array exceeds block value budget") if array.size > @remaining_values - flattened.size
      flattened.concat(array)
      writer.write(flattened.size.to_u64)
    end
    write_data(type.children[0], flattened)
  end

  private def write_tuple(type : Types::Type, values : Array(Value)) : Nil
    tuples = values.map(&.as_tuple.values)
    raise CodecError.new("Tuple arity differs from type") unless tuples.all? { |tuple| tuple.size == type.children.size }
    type.children.each_with_index { |child, index| write_data(child, tuples.map { |tuple| tuple[index] }) }
  end

  private def write_map(type : Types::Type, values : Array(Value)) : Nil
    entries = [] of Tuple(Value, Value)
    values.each do |value|
      pairs = value.as_map.entries
      raise CodecError.new("map exceeds block value budget") if pairs.size > @remaining_values - entries.size
      entries.concat(pairs)
      writer.write(entries.size.to_u64)
    end
    write_data(type.children[0], entries.map(&.[0]))
    write_data(type.children[1], entries.map(&.[1]))
  end
end
