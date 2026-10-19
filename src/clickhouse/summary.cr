require "./block"

record ClickHouse::Progress,
  rows : UInt64, bytes : UInt64, total_rows : UInt64,
  wrote_rows : UInt64, wrote_bytes : UInt64, elapsed_ns : UInt64

class ClickHouse::Summary
  getter query_id : String
  getter rows : UInt64 = 0_u64
  getter bytes : UInt64 = 0_u64
  getter total_rows : UInt64 = 0_u64
  getter wrote_rows : UInt64 = 0_u64
  getter wrote_bytes : UInt64 = 0_u64
  getter elapsed_ns : UInt64 = 0_u64
  getter blocks : UInt64 = 0_u64
  getter profile_rows : UInt64 = 0_u64
  getter profile_bytes : UInt64 = 0_u64
  getter rows_before_limit : UInt64 = 0_u64
  getter totals : ClickHouse::Block?
  getter extremes : ClickHouse::Block?

  def initialize(@query_id : String)
  end

  def add(progress : ClickHouse::Progress) : Nil
    @rows += progress.rows
    @bytes += progress.bytes
    @total_rows = Math.max(@total_rows, progress.total_rows)
    @wrote_rows += progress.wrote_rows
    @wrote_bytes += progress.wrote_bytes
    @elapsed_ns += progress.elapsed_ns
  end

  def profile(@profile_rows : UInt64, @blocks : UInt64, @profile_bytes : UInt64, @rows_before_limit : UInt64) : Nil
  end

  def totals=(@totals : ClickHouse::Block) : Nil
  end

  def extremes=(@extremes : ClickHouse::Block) : Nil
  end
end
