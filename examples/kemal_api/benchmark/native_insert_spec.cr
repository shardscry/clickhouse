require "spec"
require "../src/schema"
require "./record_factory"

unless ENV["CLICKHOUSE_BENCHMARK"]? == "1"
  raise ArgumentError.new("benchmark requires CLICKHOUSE_BENCHMARK=1; run benchmark/run.sh")
end

unless {{ flag?(:release) }}
  raise ArgumentError.new("benchmark requires crystal spec --release")
end

module KemalAPI::NativeInsertBenchmark
  BATCH_SIZE   =      10_000
  DEFAULT_ROWS =   1_000_000
  DEFAULT_SEED = 424_242_u64
  COLUMNS      = ["ingestion_id", "request_id", "received_at", "impression_count", "payload"]

  record Measurement, mode : Symbol, rows : Int32, json_payload_bytes : UInt64,
    generation : Time::Span, preparation : Time::Span, native_api : Time::Span,
    ingestion : Time::Span, payload_hash : UInt64, server_version : String

  def self.row_count : Int32
    count = (ENV["BENCHMARK_ROWS"]? || DEFAULT_ROWS.to_s).to_i?
    unless count && count >= BATCH_SIZE && count % BATCH_SIZE == 0
      raise ArgumentError.new("BENCHMARK_ROWS must be a positive multiple of #{BATCH_SIZE}")
    end
    count
  end

  def self.seed : UInt64
    value = (ENV["BENCHMARK_SEED"]? || DEFAULT_SEED.to_s).to_u64?
    value || raise ArgumentError.new("BENCHMARK_SEED must be UInt64")
  end

  def self.run(mode : Symbol, rows : Int32, seed : UInt64) : Measurement
    table = "ortb_benchmark_#{mode}_#{UUID.random.to_s.delete('-')}"
    schema_config = KemalAPI::Config.new(table: table)
    config = ClickHouse::Config.from_string(
      KemalAPI::Config.default_url,
      compression: :lz4,
      batch_size: BATCH_SIZE,
      batch_bytes: 64 * 1024 * 1024,
    )
    with_table(schema_config) do
      client = ClickHouse::Client.new(config)
      begin
        server_version = client.query("SELECT version() AS version").rows.first["version"].as_s
        warmup(client, table, mode, seed)
        measure(client, table, mode, rows, seed, server_version)
      ensure
        client.close
      end
    end
  end

  private def self.with_table(config : KemalAPI::Config, & : -> Measurement) : Measurement
    KemalAPI::Schema.create(config)
    yield
  ensure
    cleanup = config.open_client
    begin
      cleanup.exec("DROP TABLE IF EXISTS #{config.quoted_table} SYNC")
    ensure
      cleanup.close
    end
  end

  private def self.warmup(client : ClickHouse::Client, table : String, mode : Symbol, seed : UInt64) : Nil
    records = RecordFactory.new(seed ^ 1_u64).batch(BATCH_SIZE)
    if mode == :columnar
      client.insert_blocks(table, columns: COLUMNS, blocks: [columnar_block(records)], query_id: "warmup-#{UUID.random}")
    else
      send_rows(client, table, records, "warmup-#{UUID.random}")
    end
    client.exec("TRUNCATE TABLE `#{table}`")
  end

  private def self.measure(client : ClickHouse::Client, table : String, mode : Symbol, rows : Int32, seed : UInt64, version : String) : Measurement
    factory = RecordFactory.new(seed)
    generation = preparation = native_api = ingestion = Time::Span.zero
    payload_bytes = impressions = 0_u64
    first : BidRecord? = nil
    last : BidRecord? = nil
    (rows // BATCH_SIZE).times do |index|
      started = Time.instant
      records = factory.batch(BATCH_SIZE)
      payload_bytes += records.sum(&.payload.bytesize.to_u64)
      impressions += records.sum(&.impression_count.to_u64)
      first ||= records.first
      last = records.last
      query_id = "benchmark-#{mode}-#{index}-#{UUID.random}"
      generation += Time.instant - started

      started = Time.instant
      block = columnar_block(records) if mode == :columnar
      prepared = Time.instant
      preparation += prepared - started
      if block
        client.insert_blocks(table, columns: COLUMNS, blocks: [block], query_id: query_id)
      else
        send_rows(client, table, records, query_id)
      end
      finished = Time.instant
      native_api += finished - prepared
      ingestion += finished - started
      if (index + 1) % 10 == 0 || (index + 1) * BATCH_SIZE == rows
        puts({progress: mode.to_s, rows: (index + 1) * BATCH_SIZE, total_rows: rows}.to_json)
      end
    end
    hash = verify(client, table, rows, payload_bytes, impressions, first, last)
    Measurement.new(mode, rows, payload_bytes, generation, preparation, native_api, ingestion, hash, version)
  end

  private def self.send_rows(client : ClickHouse::Client, table : String, records : Array(BidRecord), query_id : String) : Nil
    client.insert(table, columns: COLUMNS, query_id: query_id) do |batch|
      records.each do |record|
        batch.append(record.ingestion_id, record.request_id, record.received_at, record.impression_count, record.payload)
      end
    end
  end

  private def self.columnar_block(records : Array(BidRecord)) : ClickHouse::Block
    ClickHouse::Block.new([
      ClickHouse::Column.new("ingestion_id", "UUID", records.map(&.ingestion_id)),
      ClickHouse::Column.new("request_id", "String", records.map(&.request_id)),
      ClickHouse::Column.new("received_at", "DateTime64(3, 'UTC')", records.map(&.received_at)),
      ClickHouse::Column.new("impression_count", "UInt16", records.map(&.impression_count)),
      ClickHouse::Column.new("payload", "String", records.map(&.payload)),
    ])
  end

  private def self.verify(client : ClickHouse::Client, table : String, rows : Int32, bytes : UInt64, impressions : UInt64, first : BidRecord?, last : BidRecord?) : UInt64
    actual = client.query(<<-SQL).rows.first
      SELECT count() AS rows, uniqExact(ingestion_id) AS unique_ids,
             sum(impression_count) AS impressions, sum(length(payload)) AS payload_bytes,
             groupBitXor(cityHash64(payload)) AS payload_hash
      FROM `#{table}`
      SQL
    actual["rows"].as_u64.should eq(rows.to_u64)
    actual["unique_ids"].as_u64.should eq(rows.to_u64)
    actual["impressions"].as_u64.should eq(impressions)
    actual["payload_bytes"].as_u64.should eq(bytes)
    [first, last].each do |record|
      record = record || raise "benchmark generated no records"
      verify_record(client, table, record)
    end
    actual["payload_hash"].as_u64
  end

  private def self.verify_record(client : ClickHouse::Client, table : String, record : BidRecord) : Nil
    found = client.query(
      "SELECT request_id, received_at, impression_count, payload FROM `#{table}` WHERE ingestion_id = {id:UUID}",
      params: {id: record.ingestion_id},
    ).rows
    found.size.should eq(1)
    found.first["request_id"].as_s.should eq(record.request_id)
    found.first["received_at"].as_timestamp.ticks.should eq(record.received_at.ticks)
    found.first["impression_count"].as_u64.should eq(record.impression_count.to_u64)
    found.first["payload"].as_bytes.should eq(record.payload.to_slice)
  end

  def self.report(measurement : Measurement, seed : UInt64) : Nil
    total = measurement.generation + measurement.ingestion
    puts({
      benchmark: "native_insert", mode: measurement.mode.to_s, seed: seed,
      rows: measurement.rows, inserts: measurement.rows // BATCH_SIZE, batch_size: BATCH_SIZE,
      json_payload_bytes: measurement.json_payload_bytes,
      average_json_bytes: (measurement.json_payload_bytes / measurement.rows).round(2),
      generation_ms: measurement.generation.total_milliseconds.round(3),
      column_preparation_ms: measurement.preparation.total_milliseconds.round(3),
      native_api_ms: measurement.native_api.total_milliseconds.round(3),
      ingestion_ms: measurement.ingestion.total_milliseconds.round(3),
      generation_and_ingestion_ms: total.total_milliseconds.round(3),
      ingestion_rows_per_second: (measurement.rows / measurement.ingestion.total_seconds).round(2),
      generation_and_ingestion_rows_per_second: (measurement.rows / total.total_seconds).round(2),
      ingestion_json_mib_per_second: (measurement.json_payload_bytes / 1_048_576.0 / measurement.ingestion.total_seconds).round(2),
      payload_hash: measurement.payload_hash,
      compression: "lz4", server_version: measurement.server_version,
      crystal_version: Crystal::VERSION, driver_version: ClickHouse::VERSION,
      release: {{ flag?(:release) }}, architecture: {{ flag?(:aarch64) ? "aarch64" : flag?(:x86_64) ? "x86_64" : "other" }},
    }.to_json)
  end
end

describe "local native row and columnar insert benchmark" do
  it "verifies the randomized million-row datasets before reporting comparable throughput" do
    rows = KemalAPI::NativeInsertBenchmark.row_count
    seed = KemalAPI::NativeInsertBenchmark.seed
    measurements = {:row, :columnar}.map do |mode|
      KemalAPI::NativeInsertBenchmark.run(mode, rows, seed)
    end
    measurements[0].payload_hash.should eq(measurements[1].payload_hash)
    measurements[0].json_payload_bytes.should eq(measurements[1].json_payload_bytes)
    measurements.each { |measurement| KemalAPI::NativeInsertBenchmark.report(measurement, seed) }
  end
end
