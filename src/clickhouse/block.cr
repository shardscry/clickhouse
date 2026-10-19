require "./column"

class ClickHouse::Block
  getter columns : Array(Column)
  getter row_count : Int32

  def initialize(@columns : Array(Column))
    @row_count = @columns.first?.try(&.values.size) || 0
    unless @columns.all? { |column| column.values.size == @row_count }
      raise CodecError.new("all block columns must have the same row count")
    end
  end

  def empty? : Bool
    @columns.empty?
  end
end
