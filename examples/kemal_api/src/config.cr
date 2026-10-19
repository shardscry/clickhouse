require "clickhouse"
require "athena-dependency_injection"

@[ADI::Register(name: "config", public: true)]
class KemalAPI::Config
  getter table : String
  @client_config : ClickHouse::Config

  def initialize(
    url : String = KemalAPI::Config.default_url,
    @table : String = KemalAPI::Config.default_table,
  )
    unless /\A[a-zA-Z_][a-zA-Z_0-9]*\z/.matches?(@table)
      raise ArgumentError.new("CLICKHOUSE_TABLE must be a simple SQL identifier")
    end
    @client_config = ClickHouse::Config.from_string(url, compression: :lz4,
      batch_size: 10_000, batch_bytes: 64 * 1024 * 1024)
  end

  def self.default_url : String
    ENV["CLICKHOUSE_URL"]? || "clickhouse://default:clickhouse_test@127.0.0.1:19001/default"
  end

  def self.default_table : String
    ENV["CLICKHOUSE_TABLE"]? || "ortb_bid_requests"
  end

  def quoted_table : String
    "`#{@table}`"
  end

  def open_client : ClickHouse::Client
    ClickHouse::Client.new(@client_config)
  end
end
