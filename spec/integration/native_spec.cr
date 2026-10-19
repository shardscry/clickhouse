require "spec"
require "uuid"
require "uri"
require "../../src/clickhouse"

module IntegrationSupport
  def self.url : String
    ENV["CLICKHOUSE_URL"]? || "clickhouse://default:clickhouse_test@127.0.0.1:19000/default"
  end

  def self.client(**options) : ClickHouse::Client
    configuration = options.merge({compression: compression})
    ClickHouse::Client.from_string(url, **configuration)
  end

  def self.compression : Symbol
    ENV["CLICKHOUSE_COMPRESSION"]? == "lz4" ? :lz4 : :none
  end

  def self.with_client(**options, &)
    client = self.client(**options)
    begin
      yield client
    ensure
      client.close
    end
  end

  def self.with_tls_client(**options, &)
    defaults = {
      tls_ca:       ENV["CLICKHOUSE_TLS_CA"],
      tls_hostname: "localhost",
      compression:  compression,
    }
    client = ClickHouse::Client.from_string(ENV["CLICKHOUSE_TLS_URL"], **defaults.merge(options))
    begin
      yield client
    ensure
      client.close
    end
  end

  def self.with_table(client, &)
    table = "crystal_spec_#{UUID.random.to_s.delete('-')}"
    client.exec("CREATE TABLE #{table} (id UInt64, name String) ENGINE=Memory")
    begin
      yield table
    ensure
      cleanup = ClickHouse::Client.new(client.config)
      begin
        cleanup.exec("DROP TABLE IF EXISTS #{table}")
      ensure
        cleanup.close
      end
    end
  end
end

if ENV["CLICKHOUSE_INTEGRATION"]? == "1"
  describe "native ClickHouse TCP integration" do
    it "authenticates, pings, and runs repeated typed queries on one connection" do
      IntegrationSupport.with_client do |client|
        client.ping.should be_true
        3.times do
          rows = client.query("SELECT toUInt64(42) AS answer, 'Ada' AS name").rows
          rows.size.should eq(1)
          rows.first["answer"].as_u64.should eq(42_u64)
          rows.first["name"].as_s.should eq("Ada")
        end
      end
    end

    it "streams all rows across several Native blocks" do
      IntegrationSupport.with_client do |client|
        actual = [] of UInt64
        client.query_each("SELECT number FROM numbers(23)", settings: {max_block_size: 3, max_threads: 1}) do |row|
          actual << row["number"].as_u64
        end
        actual.should eq((0_u64...23_u64).to_a)
        client.ping.should be_true
      end
    end

    it "encodes server-side parameters independently from binary columns" do
      IntegrationSupport.with_client do |client|
        text = "Ada's \\path\nline\t\u0000Ω"
        result = client.query("SELECT {id:UInt64} AS id, {name:String} AS name", params: {id: UInt64::MAX, name: text})
        result.rows.first["id"].as_u64.should eq(UInt64::MAX)
        result.rows.first["name"].as_s.should eq(text)
      end
    end

    it "distinguishes an empty result from the end-of-query marker" do
      IntegrationSupport.with_client do |client|
        result = client.query("SELECT toUInt64(1) AS id WHERE 0")
        result.rows.should be_empty
        result.columns.map(&.name).should eq(["id"])
        client.query("SELECT toUInt64(2) AS id").rows.first["id"].as_u64.should eq(2_u64)
      end
    end

    it "inserts several binary batches using the returned table schema" do
      IntegrationSupport.with_client(batch_size: 2) do |client|
        IntegrationSupport.with_table(client) do |table|
          client.insert(table, columns: ["id", "name"]) do |batch|
            5.times { |index| batch.append(index.to_u64, "user #{index}'s \\name") }
          end
          rows = client.query("SELECT id, name FROM #{table} ORDER BY id").rows
          rows.map(&.["id"].as_u64).should eq((0_u64...5_u64).to_a)
          rows.map(&.["name"].as_s).should eq((0...5).map { |index| "user #{index}'s \\name" })
          client.ping.should be_true
        end
      end
    end

    it "finishes an empty insert without poisoning the next query" do
      IntegrationSupport.with_client do |client|
        IntegrationSupport.with_table(client) do |table|
          client.insert(table, columns: ["id", "name"]) { |_batch| }
          client.query("SELECT count() AS total FROM #{table}").rows.first["total"].as_u64.should eq(0_u64)
        end
      end
    end

    it "round-trips a binary string spanning several native compression frames" do
      IntegrationSupport.with_client(batch_size: 1) do |client|
        IntegrationSupport.with_table(client) do |table|
          payload = "Ada's \\path\u0000Ω" * 200_000
          payload.bytesize.should be > 2 * 1024 * 1024
          client.insert(table, columns: ["id", "name"]) { |batch| batch.append(7_u64, payload) }
          rows = client.query("SELECT name FROM #{table}").rows
          rows.size.should eq(1)
          rows.first["name"].as_s.should eq(payload)
        end
      end
    end

    it "returns the server's structured terminal exception" do
      IntegrationSupport.with_client do |client|
        error = expect_raises(ClickHouse::ServerError) do
          client.query("SELECT * FROM crystal_spec_missing_table_#{UUID.random.to_s.delete('-')}")
        end
        error.code.should eq(60)
      end
    end

    it "rejects incorrect authentication credentials" do
      uri = URI.parse(IntegrationSupport.url)
      uri.password = "incorrect_test_password"
      expect_raises(ClickHouse::ServerError) { ClickHouse::Client.from_string(uri.to_s) }
    end

    it "discards a response stream abandoned by an early break" do
      client = IntegrationSupport.client
      begin
        seen = 0
        client.query_each("SELECT number FROM numbers(1000000000)", settings: {max_block_size: 2, max_threads: 1}) do |_row|
          seen += 1
          break if seen == 3
        end
        seen.should eq(3)
        client.closed?.should be_true
      ensure
        client.close
      end
    end

    it "applies a query deadline and evicts the timed-out socket" do
      client = IntegrationSupport.client(query_timeout: 100.milliseconds)
      begin
        expect_raises(ClickHouse::QueryTimeoutError) { client.query("SELECT sleep(2)") }
        client.closed?.should be_true
      ensure
        client.close
      end
    end

    it "rejects reentrant queries without disturbing the active response" do
      IntegrationSupport.with_client do |client|
        actual = [] of UInt64
        client.query_each("SELECT number FROM numbers(3)", settings: {max_block_size: 1, max_threads: 1}) do |row|
          expect_raises(ClickHouse::BusyError) { client.query("SELECT 1") }
          actual << row["number"].as_u64
        end
        actual.should eq([0_u64, 1_u64, 2_u64])
        client.ping.should be_true
      end
    end

    it "evicts a socket when materialization exceeds its configured row budget" do
      IntegrationSupport.with_client(max_result_rows: 2) do |client|
        error = expect_raises(ClickHouse::Error) do
          client.query("SELECT number FROM numbers(3)", settings: {max_block_size: 1, max_threads: 1})
        end
        error.message.to_s.should contain("configured limits")
        client.closed?.should be_true
      end
    end

    it "evicts a socket when materialization exceeds its configured byte budget" do
      IntegrationSupport.with_client(max_result_bytes: 128) do |client|
        error = expect_raises(ClickHouse::Error) { client.query("SELECT repeat('x', 1024) AS payload") }
        error.message.to_s.should contain("configured limits")
        client.closed?.should be_true
      end
    end
  end

  if tls_url = ENV["CLICKHOUSE_TLS_URL"]?
    describe "verified native TLS" do
      it "verifies the private CA and hostname before authenticating" do
        IntegrationSupport.with_tls_client do |client|
          client.ping.should be_true
          client.query("SELECT toUInt64(1) AS id").rows.first["id"].as_u64.should eq(1_u64)
        end
      end

      it "round-trips escaped parameters and bulk inserts while reading SSL responses" do
        IntegrationSupport.with_tls_client(batch_size: 8) do |client|
          text = "Ada's \\path\nline\t\u0000Ω"
          result = client.query("SELECT {name:String} AS name", params: {name: text})
          result.rows.first["name"].as_s.should eq(text)

          IntegrationSupport.with_table(client) do |table|
            payload = text + "x" * 16_384
            (payload.bytesize * 100).should be > 1024 * 1024
            client.insert(table, columns: ["id", "name"]) do |batch|
              100.times { |index| batch.append(index.to_u64, "#{index}:#{payload}") }
            end
            rows = client.query("SELECT id, name FROM #{table} ORDER BY id").rows
            rows.size.should eq(100)
            rows.each_with_index do |row, index|
              row["id"].as_u64.should eq(index.to_u64)
              row["name"].as_s.should eq("#{index}:#{payload}")
            end
            client.ping.should be_true
          end
        end
      end

      it "interrupts a blocked SSL read when the query deadline expires" do
        IntegrationSupport.with_tls_client(query_timeout: 100.milliseconds) do |client|
          started = Time.instant
          expect_raises(ClickHouse::QueryTimeoutError) { client.query("SELECT sleep(2)") }
          (Time.instant - started).should be < 1.second
          client.closed?.should be_true
        end
      end

      it "rejects a trusted certificate for the wrong hostname" do
        expect_raises(ClickHouse::ConnectionError) do
          ClickHouse::Client.from_string(tls_url, tls_ca: ENV["CLICKHOUSE_TLS_CA"], tls_hostname: "wrong-hostname.invalid")
        end
      end

      it "rejects an untrusted private CA" do
        expect_raises(ClickHouse::ConnectionError) do
          ClickHouse::Client.from_string(tls_url, tls_hostname: "localhost")
        end
      end
    end
  end
end
