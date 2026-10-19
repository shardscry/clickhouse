require "../config"
require "../contracts/bid_request_repository"

private alias BidRequest = KemalAPI::Entities::BidRequest
private alias BidQuery = KemalAPI::Structs::BidQuery
private alias BidPage = KemalAPI::Structs::PageResult(KemalAPI::Entities::BidRequest)

@[ADI::Register(name: "bid_request_repository", public: true)]
class KemalAPI::Repositories::BidRequestRepository < KemalAPI::Contracts::BidRequestRepository
  private alias Parameters = Hash(String, Int64 | UInt64)

  def initialize(@config : KemalAPI::Config)
  end

  def insert(requests : Array(BidRequest)) : Nil
    return if requests.empty?
    validate_counts(requests)
    client = @config.open_client
    begin
      client.insert_blocks(@config.table,
        columns: ["ingestion_id", "request_id", "received_at", "impression_count", "payload"],
        blocks: [columnar_block(requests)])
    ensure
      client.close
    end
  end

  private def columnar_block(requests : Array(BidRequest)) : ClickHouse::Block
    ClickHouse::Block.new([
      ClickHouse::Column.new("ingestion_id", "UUID", requests.map(&.ingestion_id)),
      ClickHouse::Column.new("request_id", "String", requests.map(&.id)),
      ClickHouse::Column.new("received_at", "DateTime64(3, 'UTC')", requests.map { |entity| ClickHouse::Timestamp.new(entity.received_at.to_unix_ms, 3, "UTC") }),
      ClickHouse::Column.new("impression_count", "UInt16", requests.map(&.impression_count.to_u16)),
      ClickHouse::Column.new("payload", "String", requests.map(&.request.to_json)),
    ])
  end

  def list(query : BidQuery) : BidPage
    where, bounds = range_filter(query)
    parameters = bounds.merge({"limit" => query.per_page.to_u64, "offset" => query.offset})
    statement = <<-SQL
      SELECT ingestion_id, request_id, received_at, impression_count, payload
      FROM #{@config.quoted_table}#{where}
      ORDER BY received_at DESC, ingestion_id DESC
      LIMIT {limit:UInt64} OFFSET {offset:UInt64}
      SQL
    client = @config.open_client
    begin
      rows = client.query(statement, params: parameters).rows
      count = client.query("SELECT count() AS total FROM #{@config.quoted_table}#{where}", params: bounds)
      total = count.rows.first["total"].as_u64
      BidPage.new(rows.map { |row| entity(row) }, query.page, query.per_page, total)
    ensure
      client.close
    end
  end

  private def range_filter(query : BidQuery) : Tuple(String, Parameters)
    conditions = [] of String
    parameters = Parameters.new
    if from = query.from
      conditions << "received_at >= fromUnixTimestamp64Milli({from_ms:Int64}, 'UTC')"
      parameters["from_ms"] = from.to_unix_ms
    end
    if to = query.to
      conditions << "received_at < fromUnixTimestamp64Milli({to_ms:Int64}, 'UTC')"
      parameters["to_ms"] = to.to_unix_ms
    end
    where = conditions.empty? ? "" : " WHERE #{conditions.join(" AND ")}"
    {where, parameters}
  end

  private def entity(row : ClickHouse::Row) : BidRequest
    BidRequest.new(
      ingestion_id: row["ingestion_id"].as_uuid,
      received_at: row["received_at"].as_timestamp.to_time,
      id: row["request_id"].as_s,
      impression_count: row["impression_count"].as_u64.to_i32,
      request: JSON.parse(row["payload"].as_s),
    )
  end

  private def validate_counts(requests : Array(BidRequest)) : Nil
    requests.each do |entity|
      unless (0..UInt16::MAX).includes?(entity.impression_count)
        raise ArgumentError.new("impression_count must fit UInt16")
      end
    end
  end
end
