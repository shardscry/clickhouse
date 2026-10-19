require "spec"
require "../../src/clickhouse"

module ColumnarIntegrationSupport
  def self.verify(url : String, tls_ca : String? = nil, tls_hostname : String? = nil) : Nil
    compression = ENV["CLICKHOUSE_COMPRESSION"]? == "lz4" ? :lz4 : :none
    client = ClickHouse::Client.from_string(url, compression: compression, batch_size: 10_000,
      tls_ca: tls_ca, tls_hostname: tls_hostname)
    table = "crystal_columnar_#{UUID.random.to_s.delete('-')}"
    begin
      client.exec("CREATE TABLE #{table} (id UInt64, name String, received_at DateTime64(3, 'UTC')) ENGINE=Memory")
      blocks = [0, 2].map do |offset|
        ClickHouse::Block.new([
          ClickHouse::Column.new("id", "UInt64", [offset.to_u64, (offset + 1).to_u64]),
          ClickHouse::Column.new("name", "String", ["Ada #{offset}", "Grace #{offset}"]),
          ClickHouse::Column.new("received_at", "DateTime64(3,'UTC')", [ClickHouse::Timestamp.new(-1_i64, 3, "UTC"), ClickHouse::Timestamp.new(1705321845123_i64, 3, "UTC")]),
        ])
      end
      client.insert_blocks(table, columns: ["id", "name", "received_at"], blocks: blocks)
      client.insert_blocks(table, columns: ["id", "name", "received_at"], blocks: [] of ClickHouse::Block)
      rows = client.query("SELECT * FROM #{table} ORDER BY id").rows
      rows.map(&.["id"].as_u64).should eq([0_u64, 1_u64, 2_u64, 3_u64])
      rows[0]["received_at"].as_timestamp.ticks.should eq(-1_i64)
      rows[1]["received_at"].as_timestamp.ticks.should eq(1705321845123_i64)
      client.ping.should be_true
    ensure
      client.close
      cleanup = ClickHouse::Client.from_string(url, tls_ca: tls_ca, tls_hostname: tls_hostname)
      begin
        cleanup.exec("DROP TABLE IF EXISTS #{table}")
      ensure
        cleanup.close
      end
    end
  end
end

if ENV["CLICKHOUSE_INTEGRATION"]? == "1"
  describe "native columnar insert integration" do
    it "streams typed columns, preserves timestamp metadata, and supports an empty stream" do
      url = ENV["CLICKHOUSE_URL"]? || "clickhouse://default:clickhouse_test@127.0.0.1:19000/default"
      ColumnarIntegrationSupport.verify(url)
    end

    if tls_url = ENV["CLICKHOUSE_TLS_URL"]?
      it "streams columnar blocks through verified TLS and reuses the connection" do
        ColumnarIntegrationSupport.verify(tls_url, tls_ca: ENV["CLICKHOUSE_TLS_CA"], tls_hostname: "localhost")
      end
    end
  end
end
