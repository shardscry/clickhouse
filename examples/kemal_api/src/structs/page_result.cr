require "json"

struct KemalAPI::Structs::PageResult(T)
  include JSON::Serializable

  getter data : Array(T)
  getter page : Int32
  getter per_page : Int32
  getter total : UInt64
  getter total_pages : UInt64

  def initialize(@data : Array(T), @page : Int32, @per_page : Int32, @total : UInt64)
    raise ArgumentError.new("per_page must be positive") unless @per_page > 0
    @total_pages = @total // @per_page.to_u64
    @total_pages += 1_u64 unless @total % @per_page.to_u64 == 0
  end
end
