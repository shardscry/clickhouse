require "./connection"

class ClickHouse::Batch
  private DECIMAL_PRECISIONS = {"Decimal32" => "9", "Decimal64" => "18", "Decimal128" => "38"}
  getter? sent : Bool = false
  getter? input_finished : Bool = false
  @columns : Array(Column)
  @schema_types : Array(Types::Type)
  @rows : Int32 = 0
  @bytes : Int64 = 0
  @finished : Bool = false

  def initialize(@connection : Connection, schema : Block, @config : Config)
    @columns = schema.columns.map { |column| Column.new(column.name, column.type, [] of Value) }
    @schema_types = schema.columns.map { |column| Types::Parser.parse(column.type) }
  end

  def append(*values) : Nil
    append(values.to_a.map { |value| Value.wrap(value) })
  end

  def append(values : Array(Value)) : Nil
    raise ClosedError.new("insert batch is closed") if @finished
    raise ArgumentError.new("expected #{@columns.size} values, got #{values.size}") unless values.size == @columns.size
    bytes = values.sum { |value| estimate(value, 0) }
    raise ArgumentError.new("row exceeds configured batch_bytes") if bytes > @config.batch_bytes
    flush if @rows > 0 && (@rows >= @config.batch_size || @bytes + bytes > @config.batch_bytes)
    @columns.each_with_index { |column, index| column.values << values[index] }
    @rows += 1
    @bytes += bytes
    flush if @rows >= @config.batch_size
  end

  def flush : Nil
    raise ClosedError.new("insert batch is closed") if @finished
    return if @rows == 0
    @sent = true
    @connection.send_block(Block.new(@columns))
    @columns.each(&.values.clear)
    @rows = 0
    @bytes = 0
  end

  def append_block(block : Block) : Nil
    raise ClosedError.new("insert batch is closed") if @finished
    validate_block(block)
    return if block.row_count == 0
    flush
    @sent = true
    @connection.send_block(block)
  end

  protected def finish : Nil
    flush
    # The receive fiber can observe completion while the EOF write is flushing.
    @input_finished = true
    @connection.send_block(Block.new([] of Column))
    @finished = true
  end

  protected def invalidate : Nil
    @finished = true
    @columns.each(&.values.clear)
  end

  private def validate_block(block : Block) : Nil
    raise ArgumentError.new("columnar insert blocks cannot be zero-column end markers") if block.columns.empty?
    raise ArgumentError.new("columnar block exceeds configured batch_size") if block.row_count > @config.batch_size
    raise ArgumentError.new("columnar block column count differs from insert schema") unless block.columns.size == @columns.size
    bytes = 0_i64
    block.columns.each_with_index do |column, index|
      validate_column(column, index, block.row_count)
      column.values.each do |value|
        bytes += estimate(value, 0)
        raise ArgumentError.new("columnar block exceeds configured batch_bytes") if bytes > @config.batch_bytes
      end
    end
  end

  private def validate_column(column : Column, index : Int32, rows : Int32) : Nil
    expected = @columns[index]
    raise ArgumentError.new("columnar block names/order differ from insert schema") unless column.name == expected.name
    raise ArgumentError.new("columnar block column sizes changed after construction") unless column.values.size == rows
    actual_type = Types::Parser.parse(column.type)
    unless equivalent_type?(@schema_types[index], actual_type)
      raise ArgumentError.new("columnar type #{column.type} differs from insert schema #{expected.type}")
    end
  end

  private def equivalent_type?(expected : Types::Type, actual : Types::Type) : Bool
    return false unless type_signature(expected) == type_signature(actual)
    return false unless expected.field_names == actual.field_names && expected.enum_values == actual.enum_values
    return false unless expected.children.size == actual.children.size
    expected.children.each_with_index.all? { |child, index| equivalent_type?(child, actual.children[index]) }
  end

  private def type_signature(type : Types::Type) : Tuple(String, Array(String))
    precision = DECIMAL_PRECISIONS[type.name]?
    return {type.name, type.parameters} unless precision
    {"Decimal", [precision] + type.parameters}
  end

  private def estimate(value : Value, depth : Int32) : Int64
    raise ArgumentError.new("insert value exceeds nesting limit") if depth > 64
    case raw = value.raw
    when String then raw.bytesize.to_i64 + 16
    when Bytes  then raw.size.to_i64 + 16
    when Array(Value)
      16_i64 + raw.sum { |item| estimate(item, depth + 1) }
    when TupleValue
      16_i64 + raw.values.sum { |item| estimate(item, depth + 1) }
    when MapValue
      16_i64 + raw.entries.sum { |pair| estimate(pair[0], depth + 1) + estimate(pair[1], depth + 1) }
    else
      32_i64
    end
  end
end
