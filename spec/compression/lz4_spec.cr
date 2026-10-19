require "spec"
require "../../src/clickhouse/compression/lz4"

describe ClickHouse::Compression::LZ4 do
  it "decodes an independent liblz4 1.10.0 block" do
    # Generated with spec/fixtures/compression/generate.cc.
    compressed = "ff0f436c69636b486f757365206e617469766520636f6d7072657373696f6e201e00ffffff8d5073696f6e20".hexbytes
    expected = "ClickHouse native compression " * 32
    ClickHouse::Compression::LZ4.decompress(compressed, expected.bytesize).should eq(expected.to_slice)
  end

  it "decodes overlapping matches" do
    compressed = Bytes[0x44, 'a'.ord, 'b'.ord, 'c'.ord, 'd'.ord, 4, 0, 0x50, 'E'.ord, 'F'.ord, 'G'.ord, 'H'.ord, 'I'.ord]
    ClickHouse::Compression::LZ4.decompress(compressed, 17).should eq("abcdabcdabcdEFGHI".to_slice)
  end

  it "compresses repeated data using matches" do
    input = ("abcdefg" * 10_000).to_slice
    compressed = ClickHouse::Compression::LZ4.compress(input)
    compressed.size.should be < 400
    ClickHouse::Compression::LZ4.decompress(compressed, input.size).should eq(input)
  end

  it "round-trips empty, short, incompressible and long literal data" do
    random = Random.new(0xc1c_u64)
    [0, 1, 4, 5, 12, 13, 15, 16, 270, 1_024, 65_536].each do |size|
      input = Bytes.new(size)
      random.random_bytes(input)
      compressed = ClickHouse::Compression::LZ4.compress(input)
      ClickHouse::Compression::LZ4.decompress(compressed, size).should eq(input)
    end
  end

  it "rejects truncated lengths, literals, offsets, and invalid backreferences" do
    [Bytes[0xf0], Bytes[0xf0, 255], Bytes[0x20, 1], Bytes[0x10, 1, 1], Bytes[0, 0, 0], Bytes[0, 1, 0]].each do |input|
      expect_raises(ClickHouse::Compression::Error) do
        ClickHouse::Compression::LZ4.decompress(input, 32)
      end
    end
  end

  it "rejects blocks without the required final literal sequence" do
    expect_raises(ClickHouse::Compression::Error, "final sequence") do
      ClickHouse::Compression::LZ4.decompress(Bytes[0x10, 'a'.ord, 1, 0], 5)
    end
    expect_raises(ClickHouse::Compression::Error, "final sequence") do
      ClickHouse::Compression::LZ4.decompress(Bytes.empty, 0)
    end
  end

  it "bounds literal and match expansion by the advertised size" do
    [Bytes[0xf0, 255, 255, 0], Bytes[0x1f, 'a'.ord, 1, 0, 255, 0]].each do |input|
      expect_raises(ClickHouse::Compression::Error) do
        ClickHouse::Compression::LZ4.decompress(input, 16)
      end
    end
    expect_raises(ClickHouse::Compression::Error, "size") do
      ClickHouse::Compression::LZ4.decompress(Bytes[0], 1)
    end
  end

  it "rejects deterministic malformed input without unbounded expansion" do
    random = Random.new(0x12a4_u64)
    500.times do
      input = Bytes.new(random.rand(0..64))
      random.random_bytes(input)
      begin
        result = ClickHouse::Compression::LZ4.decompress(input, random.rand(0..128))
        result.size.should be <= 128
      rescue ClickHouse::Compression::Error
      end
    end
  end
end
