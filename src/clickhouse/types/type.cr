require "../value"

class ClickHouse::Types::Type
  getter name : String
  getter children : Array(Type)
  getter parameters : Array(String)
  getter field_names : Array(String?)
  getter enum_values : Hash(String, Int16)

  def initialize(@name : String, @children = [] of Type, @parameters = [] of String,
                 @field_names = [] of String?, @enum_values = {} of String => Int16)
  end
end
