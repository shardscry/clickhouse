require "./value"

class ClickHouse::Column
  getter name : String
  getter type : String
  getter values : Array(Value)

  def initialize(@name : String, @type : String, @values : Array(Value))
  end

  def initialize(@name : String, @type : String, values : Array(T)) forall T
    @values = values.map { |value| Value.wrap(value) }
  end

  def [](index : Int) : Value
    @values[index]
  end
end
