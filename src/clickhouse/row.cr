require "./block"

struct ClickHouse::Row
  def initialize(@block : Block, @index : Int32)
    raise IndexError.new unless (0...@block.row_count).includes?(@index)
  end

  def [](name : String) : Value
    column = @block.columns.find { |item| item.name == name }
    raise KeyError.new("unknown column #{name}") unless column
    column.values[@index]
  end

  def [](column : Int) : Value
    @block.columns[column].values[@index]
  end
end
