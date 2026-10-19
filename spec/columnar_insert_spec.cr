require "spec"
require "./helpers/scripted_peer"

class ColumnarBlockStream
  include Enumerable(ClickHouse::Block)
  getter passes = 0

  def initialize(@blocks : Array(ClickHouse::Block))
  end

  def each(& : ClickHouse::Block ->) : Nil
    @passes += 1
    @blocks.each { |block| yield block }
  end
end

module ColumnarSpec
  def self.block(ids : Array(UInt64), names : Array(String)) : ClickHouse::Block
    ClickHouse::Block.new([
      ClickHouse::Column.new("id", "UInt64", ids),
      ClickHouse::Column.new("name", "String", names),
    ])
  end

  def self.client(config = ClickHouse::Config.new) : Tuple(ClickHouse::Client, ScriptedPeer)
    peer = ScriptedPeer.new(ScriptedPeer.join(ScriptedPeer.insert_schema, Bytes[5, 4]))
    {ClickHouse::Client.new(config, peer), peer}
  end

  def self.sent_blocks(peer : ScriptedPeer) : Array(ClickHouse::Block)
    bytes = peer.output.to_slice
    external_eof = "0200010002ffffffff000000".hexbytes
    position = (0..bytes.size - external_eof.size).find { |offset| bytes[offset, external_eof.size] == external_eof }
    raise "missing external-table end marker" unless position
    reader = ClickHouse::Protocol::Reader.new(IO::Memory.new(bytes[position + external_eof.size..]))
    blocks = [] of ClickHouse::Block
    loop do
      reader.var_uint.should eq(2_u64)
      reader.string.should eq("")
      block = ClickHouse::Codecs::BlockCodec.read(reader, 54460)
      blocks << block
      break if block.empty?
    end
    blocks
  end
end

describe "columnar native insertion" do
  it "wraps typed column arrays without changing signedness or binary data" do
    ClickHouse::Column.new("id", "UInt128", [UInt128::MAX]).values[0].as_u128.should eq(UInt128::MAX)
    bytes = Bytes[0, 255]
    column = ClickHouse::Column.new("binary", "String", [bytes])
    bytes[0] = 1
    column.values[0].as_bytes.should eq(Bytes[0, 255])
  end

  it "consumes a block stream once and sends complete columns while retaining caller ownership" do
    first = ColumnarSpec.block([1_u64, 2_u64], ["Ada", "Grace"])
    second = ColumnarSpec.block([3_u64], ["Katherine"])
    empty = ColumnarSpec.block([] of UInt64, [] of String)
    stream = ColumnarBlockStream.new([first, empty, second])
    client, peer = ColumnarSpec.client
    begin
      summary = client.insert_blocks("events", columns: ["id", "name"], blocks: stream, query_id: "columnar-stream")
      summary.query_id.should eq("columnar-stream")
      stream.passes.should eq(1)
      sent = ColumnarSpec.sent_blocks(peer)
      sent.map(&.row_count).should eq([2, 1, 0])
      sent[0].columns[0].values.map(&.as_u64).should eq([1_u64, 2_u64])
      sent[1].columns[1].values[0].as_s.should eq("Katherine")
      first.columns[0].values.size.should eq(2)
      second.columns[1].values[0].as_s.should eq("Katherine")
      client.ping.should be_true
    ensure
      client.close
    end
  end

  it "flushes pending row values before sending a direct columnar block" do
    block = ColumnarSpec.block([2_u64, 3_u64], ["Grace", "Katherine"])
    client, peer = ColumnarSpec.client
    begin
      client.insert("events", columns: ["id", "name"]) do |batch|
        batch.append(1_u64, "Ada")
        batch.append_block(block)
      end
      sent = ColumnarSpec.sent_blocks(peer)
      sent.map(&.row_count).should eq([1, 2, 0])
      sent[0].columns[0].values[0].as_u64.should eq(1_u64)
      sent[1].columns[0].values.map(&.as_u64).should eq([2_u64, 3_u64])
    ensure
      client.close
    end
  end

  it "rejects mismatched names, types, dimensions, and explicit end markers" do
    wrong_name = ClickHouse::Block.new([
      ClickHouse::Column.new("wrong", "UInt64", [1_u64]), ClickHouse::Column.new("name", "String", ["Ada"]),
    ])
    wrong_type = ClickHouse::Block.new([
      ClickHouse::Column.new("id", "Int64", [1_i64]), ClickHouse::Column.new("name", "String", ["Ada"]),
    ])
    changed = ColumnarSpec.block([1_u64], ["Ada"])
    changed.columns[0].values << ClickHouse::Value.wrap(2_u64)
    [wrong_name, wrong_type, changed, ClickHouse::Block.new([] of ClickHouse::Column)].each do |block|
      client, _peer = ColumnarSpec.client
      expect_raises(ArgumentError) { client.insert_blocks("events", columns: ["id", "name"], blocks: [block]) }
      client.closed?.should be_true
    end
  end

  it "enforces configured direct-block row and byte budgets" do
    block = ColumnarSpec.block([1_u64, 2_u64], ["Ada", "Grace"])
    [ClickHouse::Config.new(batch_size: 1), ClickHouse::Config.new(batch_bytes: 1)].each do |config|
      client, _peer = ColumnarSpec.client(config)
      expect_raises(ArgumentError, /configured batch_/) { client.insert_blocks("events", columns: ["id", "name"], blocks: [block]) }
      client.closed?.should be_true
    end
  end

  it "preserves uncertain-outcome errors after direct block transmission" do
    peer = ScriptedPeer.new(ScriptedPeer.insert_schema)
    client = ClickHouse::Client.new(ClickHouse::Config.new, peer)
    block = ColumnarSpec.block([1_u64], ["Ada"])
    error = expect_raises(ClickHouse::InsertOutcomeUnknown) do
      client.insert_blocks("events", columns: ["id", "name"], blocks: [block], query_id: "columnar-uncertain")
    end
    error.query_id.should eq("columnar-uncertain")
    client.closed?.should be_true
  end
end
