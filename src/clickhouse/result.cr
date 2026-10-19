require "./row"
require "./summary"

class ClickHouse::Result
  include Enumerable(Row)

  getter rows : Array(Row)
  getter columns : Array(Column)
  getter summary : Summary

  def initialize(@rows : Array(Row), @columns : Array(Column), @summary : Summary)
  end

  def each(& : Row ->) : Nil
    @rows.each { |row| yield row }
  end
end
