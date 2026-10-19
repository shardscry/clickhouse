require "spec"
require "../../src/clickhouse/protocol/reader"
require "../../src/clickhouse/protocol/writer"

describe ClickHouse::Protocol::Reader do
  it "decodes independent VarUInt and little-endian numeric vectors" do
    reader = ClickHouse::Protocol::Reader.new(IO::Memory.new(Bytes[0xac, 0x02, 0xff, 0xff, 0x78, 0x56, 0x34, 0x12]))
    reader.var_uint.should eq(300_u64)
    reader.read(Int16).should eq(-1_i16)
    reader.read(UInt32).should eq(0x12345678_u32)
  end

  it "rejects overflowing and incomplete VarUInt values" do
    expect_raises(ClickHouse::ProtocolError) do
      ClickHouse::Protocol::Reader.new(IO::Memory.new(Bytes.new(10, 0xff_u8))).var_uint
    end
    expect_raises(IO::EOFError) do
      ClickHouse::Protocol::Reader.new(IO::Memory.new(Bytes[0x80])).var_uint
    end
  end

  it "preserves binary strings and bounds allocation before reading a payload" do
    reader = ClickHouse::Protocol::Reader.new(IO::Memory.new(Bytes[3, 0, 0xff, 0x61]))
    reader.string.to_slice.should eq(Bytes[0, 0xff, 0x61])
    expect_raises(ClickHouse::ProtocolError) do
      ClickHouse::Protocol::Reader.new(IO::Memory.new(Bytes[5]), 4).string
    end
  end

  it "encodes known wire bytes" do
    io = IO::Memory.new
    writer = ClickHouse::Protocol::Writer.new(io)
    writer.var_uint(300_u64)
    writer.write(-2_i16)
    writer.string("A\0")
    io.to_slice.should eq(Bytes[0xac, 2, 0xfe, 0xff, 2, 0x41, 0])
  end
end
