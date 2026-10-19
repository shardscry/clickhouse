require "spec"
require "../../src/clickhouse/compression/frame"

private class FragmentedCompressionIO < IO
  def initialize(@inner : IO)
  end

  def read(slice : Bytes) : Int32
    @inner.read(slice[0, Math.min(1, slice.size)])
  end

  def write(slice : Bytes) : NoReturn
    raise IO::Error.new("read-only test IO")
  end
end

private def compression_frame(input : Bytes, method = :lz4) : Bytes
  io = IO::Memory.new
  ClickHouse::Compression.write_frame(io, input, method)
  io.to_slice.dup
end

private def rehash_compression_frame(frame : Bytes) : Nil
  low, high = ClickHouse::Compression::CityHash.hash128(frame[16, frame.size - 16])
  IO::ByteFormat::LittleEndian.encode(low, frame[0, 8])
  IO::ByteFormat::LittleEndian.encode(high, frame[8, 8])
end

describe ClickHouse::Compression do
  it "decodes an independent CityHash and liblz4 native frame" do
    # Generated with spec/fixtures/compression/generate.cc.
    frame = "a48a3ad62afb0764c017bc25c74ea4f78235000000c0030000ff0f436c69636b486f757365206e617469766520636f6d7072657373696f6e201e00ffffff8d5073696f6e20".hexbytes
    reader = ClickHouse::Compression::Reader.new(IO::Memory.new(frame))
    reader.gets_to_end.should eq("ClickHouse native compression " * 32)
  end

  it "writes ClickHouse's sizes and low-high little-endian checksum order" do
    frame = compression_frame("hello".to_slice, :none)
    frame[16].should eq(0x02)
    IO::ByteFormat::LittleEndian.decode(UInt32, frame[17, 4]).should eq(14)
    IO::ByteFormat::LittleEndian.decode(UInt32, frame[21, 4]).should eq(5)
    frame[25, 5].should eq("hello".to_slice)
    low, high = ClickHouse::Compression::CityHash.hash128(frame[16, 14])
    IO::ByteFormat::LittleEndian.decode(UInt64, frame[0, 8]).should eq(low)
    IO::ByteFormat::LittleEndian.decode(UInt64, frame[8, 8]).should eq(high)
  end

  it "reads fragmented input and spans LZ4 and NONE frames" do
    source = IO::Memory.new
    ClickHouse::Compression.write_frame(source, "hello".to_slice)
    ClickHouse::Compression.write_frame(source, " world".to_slice, :none)
    source.rewind
    reader = ClickHouse::Compression::Reader.new(FragmentedCompressionIO.new(source))
    reader.gets_to_end.should eq("hello world")
    reader.buffered_remaining.should eq(0)
  end

  it "does not read ahead from a drained frame into packet headers" do
    source = IO::Memory.new
    ClickHouse::Compression.write_frame(source, "hello".to_slice)
    source.write_byte(5_u8)
    source.rewind
    reader = ClickHouse::Compression::Reader.new(source)
    first = Bytes.new(2)
    reader.read_fully(first)
    first.should eq("he".to_slice)
    reader.buffered_remaining.should eq(3)
    rest = Bytes.new(3)
    reader.read_fully(rest)
    rest.should eq("llo".to_slice)
    reader.buffered_remaining.should eq(0)
    source.read_byte.should eq(5_u8)
  end

  it "rejects corruption and truncation" do
    original = compression_frame(("hello" * 100).to_slice)
    original.size.times do |size|
      expect_raises(ClickHouse::Compression::Error) do
        ClickHouse::Compression::Reader.new(IO::Memory.new(original[0, size])).gets_to_end
      end unless size == 0
    end
    original[original.size - 1] ^= 1_u8
    expect_raises(ClickHouse::Compression::Error, "checksum") do
      ClickHouse::Compression::Reader.new(IO::Memory.new(original)).gets_to_end
    end
  end

  it "rejects oversized and invalid size headers before reading their payload" do
    [0_u32, 8_u32, UInt32::MAX].each do |compressed_size|
      frame = compression_frame("hello".to_slice)
      IO::ByteFormat::LittleEndian.encode(compressed_size, frame[17, 4])
      expect_raises(ClickHouse::Compression::Error, "sizes") do
        ClickHouse::Compression::Reader.new(IO::Memory.new(frame), 64).gets_to_end
      end
    end
    frame = compression_frame("hello".to_slice)
    IO::ByteFormat::LittleEndian.encode(UInt32::MAX, frame[21, 4])
    expect_raises(ClickHouse::Compression::Error, "sizes") do
      ClickHouse::Compression::Reader.new(IO::Memory.new(frame)).gets_to_end
    end
  end

  it "rejects unsupported methods and inconsistent uncompressed sizes" do
    frame = compression_frame("hello".to_slice, :none)
    frame[16] = 0x90_u8
    rehash_compression_frame(frame)
    expect_raises(ClickHouse::Compression::Error, "unsupported") do
      ClickHouse::Compression::Reader.new(IO::Memory.new(frame)).gets_to_end
    end
    frame = compression_frame("hello".to_slice, :none)
    IO::ByteFormat::LittleEndian.encode(6_u32, frame[21, 4])
    rehash_compression_frame(frame)
    expect_raises(ClickHouse::Compression::Error, "size mismatch") do
      ClickHouse::Compression::Reader.new(IO::Memory.new(frame)).gets_to_end
    end
  end

  it "supports empty frames and bounds consecutive empty frames" do
    source = IO::Memory.new
    ClickHouse::Compression.write_frame(source, Bytes.empty)
    ClickHouse::Compression.write_frame(source, "value".to_slice)
    source.rewind
    ClickHouse::Compression::Reader.new(source).gets_to_end.should eq("value")

    source = IO::Memory.new
    17.times { ClickHouse::Compression.write_frame(source, Bytes.empty, :none) }
    source.rewind
    expect_raises(ClickHouse::Compression::Error, "empty") do
      ClickHouse::Compression::Reader.new(source).gets_to_end
    end
  end
end
