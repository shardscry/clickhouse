require "./writer"
require "../version"

module ClickHouse::Protocol::QueryPacket
  def self.write(
    writer : Writer, revision : Int32, query_id : String, body : String,
    parameters : Hash(String, String), settings : Hash(String, String),
    compression : Bool,
  ) : Nil
    writer.var_uint(1)
    writer.string(query_id)
    write_client_info(writer, revision, query_id)
    settings.each do |key, value|
      writer.string(key)
      writer.var_uint(1)
      writer.string(value)
    end
    writer.string("")
    writer.string("") if revision >= 54441
    writer.var_uint(2)
    writer.var_uint(compression ? 1 : 0)
    writer.string(body)
    if revision >= 54459
      parameters.each do |key, value|
        writer.string(key)
        writer.var_uint(2)
        writer.string(value)
      end
      writer.string("")
    end
  end

  private def self.write_client_info(writer : Writer, revision : Int32, query_id : String) : Nil
    writer.write(1_u8)
    writer.string("")
    writer.string(query_id)
    writer.string("0.0.0.0:0")
    writer.write(0_i64) if revision >= 54449
    writer.write(1_u8)
    writer.string("")
    writer.string("")
    writer.string("shardscry/clickhouse")
    writer.var_uint(VERSION_PARTS[0])
    writer.var_uint(VERSION_PARTS[1])
    writer.var_uint(revision)
    writer.string("") if revision >= 54060
    writer.var_uint(0) if revision >= 54448
    writer.var_uint(VERSION_PARTS[2]) if revision >= 54401
    writer.write(0_u8) if revision >= 54442
    if revision >= 54453
      3.times { writer.var_uint(0) }
    end
  end
end
