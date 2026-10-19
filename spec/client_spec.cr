require "spec"
require "./helpers/scripted_peer"

describe ClickHouse::Client do
  it "handles fragmented captured packets and keeps successful connections reusable" do
    response = ScriptedPeer.join(ScriptedPeer.answer_schema, ScriptedPeer.answer_rows, Bytes[5, 4])
    peer = ScriptedPeer.new(response, fragment_size: 1)
    client = ClickHouse::Client.new(ClickHouse::Config.new, peer)
    begin
      result = client.query("SELECT toUInt64(42) AS answer, 'Ada' AS name")
      result.rows.first["answer"].as_u64.should eq(42_u64)
      result.rows.first["name"].as_s.should eq("Ada")
      client.ping.should be_true
      client.closed?.should be_false
    ensure
      client.close
    end
  end

  it "treats a captured server Exception as terminal without waiting for EndOfStream" do
    peer = ScriptedPeer.new(ScriptedPeer.exception)
    client = ClickHouse::Client.new(ClickHouse::Config.new, peer)
    error = expect_raises(ClickHouse::ServerError) { client.query("SELECT missing", query_id: "terminal-error") }
    error.code.should eq(60)
    error.query_id.should eq("terminal-error")
    client.closed?.should be_true
  end

  it "evicts malformed and truncated response streams" do
    [Bytes[99], ScriptedPeer.answer_rows[0, ScriptedPeer.answer_rows.size - 1]].each do |response|
      peer = ScriptedPeer.new(response)
      client = ClickHouse::Client.new(ClickHouse::Config.new, peer)
      expect_raises(ClickHouse::Error) { client.query("SELECT malformed") }
      client.closed?.should be_true
      expect_raises(ClickHouse::ClosedError) { client.ping }
    end
  end

  it "enforces materialized row and byte budgets across server blocks" do
    response = ScriptedPeer.join(ScriptedPeer.answer_schema, ScriptedPeer.answer_rows, ScriptedPeer.answer_rows, Bytes[5])
    [ClickHouse::Config.new(max_result_rows: 1), ClickHouse::Config.new(max_result_bytes: 4)].each do |config|
      client = ClickHouse::Client.new(config, ScriptedPeer.new(response))
      expect_raises(ClickHouse::Error, /materialized result exceeds/) { client.query("SELECT bounded") }
      client.closed?.should be_true
    end
  end

  it "preserves callback failures and discards their unconsumed response" do
    peer = ScriptedPeer.new(ScriptedPeer.join(ScriptedPeer.answer_rows, Bytes[5]))
    client = ClickHouse::Client.new(ClickHouse::Config.new, peer)
    expect_raises(ArgumentError, "callback failed") do
      client.query_each("SELECT callback") { |_row| raise ArgumentError.new("callback failed") }
    end
    client.closed?.should be_true
  end

  it "rejects reentrant operations without disturbing the active response" do
    peer = ScriptedPeer.new(ScriptedPeer.join(ScriptedPeer.answer_rows, Bytes[5, 4]))
    client = ClickHouse::Client.new(ClickHouse::Config.new, peer)
    begin
      client.query_each("SELECT reentrant") { |_row| expect_raises(ClickHouse::BusyError) { client.ping } }
      client.ping.should be_true
    ensure
      client.close
    end
  end

  it "returns an uncertain outcome and never replays an insert after rows were sent" do
    peer = ScriptedPeer.new(ScriptedPeer.insert_schema)
    client = ClickHouse::Client.new(ClickHouse::Config.new(batch_size: 1), peer)
    error = expect_raises(ClickHouse::InsertOutcomeUnknown) do
      client.insert("events", columns: ["id", "name"], query_id: "uncertain-insert") { |batch| batch.append(42_u64, "Ada") }
    end
    error.query_id.should eq("uncertain-insert")
    client.closed?.should be_true
    bytes = peer.output.to_slice
    marker = "INSERT INTO".to_slice
    (0..bytes.size - marker.size).count { |offset| bytes[offset, marker.size] == marker }.should eq(1)
  end

  it "does not label a disconnected empty insert as having sent rows" do
    peer = ScriptedPeer.new(ScriptedPeer.insert_schema)
    client = ClickHouse::Client.new(ClickHouse::Config.new, peer)
    expect_raises(ClickHouse::ConnectionError) { client.insert("events", columns: ["id", "name"]) { |_batch| } }
    client.closed?.should be_true
  end

  it "rejects EndOfStream received before insert input was finished" do
    peer = ScriptedPeer.new(ScriptedPeer.join(ScriptedPeer.insert_schema, Bytes[5]))
    client = ClickHouse::Client.new(ClickHouse::Config.new(batch_size: 1), peer)
    expect_raises(ClickHouse::ProtocolError, /before.*input|premature/i) do
      client.insert("events", columns: ["id", "name"]) do |batch|
        Fiber.yield
        batch.append(42_u64, "Ada")
      end
    end
    client.closed?.should be_true
  end

  it "does not replace a protocol failure with a TLS cleanup failure" do
    peer = ScriptedPeer.new(Bytes[99])
    client = ClickHouse::Client.new(ClickHouse::Config.new, peer)
    peer.close_error = OpenSSL::Error.new("scripted TLS close failure")
    begin
      expect_raises(ClickHouse::ProtocolError, /unsupported server packet/) { client.query("SELECT malformed") }
      client.closed?.should be_true
    ensure
      peer.close_error = nil
      client.close
    end
  end
end
