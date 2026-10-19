require "spec"
require "base64"
require "../../src/clickhouse/codecs/block_codec"
require "../../src/clickhouse/row"

module CodecSpec
  def self.decode(type : String, bytes : Bytes, rows = 1) : Array(ClickHouse::Value)
    input = IO::Memory.new(bytes)
    values = ClickHouse::Codecs::ColumnCodec.new(reader: ClickHouse::Protocol::Reader.new(input)).read(ClickHouse::Types::Parser.parse(type), rows)
    input.pos.should eq(bytes.size)
    values
  end

  def self.encode(type : String, values : Array(ClickHouse::Value)) : Bytes
    output = IO::Memory.new
    ClickHouse::Codecs::ColumnCodec.new(writer: ClickHouse::Protocol::Writer.new(output)).write(ClickHouse::Types::Parser.parse(type), values)
    output.to_slice.dup
  end

  def self.round_trip(type : String, values : Array(ClickHouse::Value)) : Array(ClickHouse::Value)
    decode(type, encode(type, values), values.size)
  end
end

describe ClickHouse::Codecs::BlockCodec do
  it "decodes an independently generated ClickHouse 26.8.31.2 analytical block" do
    bytes = Base64.decode(File.read("#{__DIR__}/../fixtures/codecs/analytical_lts.native.base64"))
    input = IO::Memory.new(bytes)
    block = ClickHouse::Codecs::BlockCodec.read(ClickHouse::Protocol::Reader.new(input), 0)
    input.pos.should eq(bytes.size)
    block.columns.size.should eq(18)
    row = ClickHouse::Row.new(block, 0)
    row["wide"].as_u128.should eq(UInt128::MAX)
    row["signed"].as_i128.should eq(Int128::MIN)
    row["binary"].as_bytes.should eq(Bytes[0, 255, 97])
    row["fixed"].as_bytes.should eq(Bytes[0, 255, 97, 0, 0])
    row["absent"].null?.should be_true
    row["nothing"].null?.should be_true
    row["precise"].as_timestamp.ticks.should eq(-1_i64)
    row["uid"].as_uuid.should eq(UUID.new("550e8400-e29b-41d4-a716-446655440000"))
    row["ip4"].raw.as(ClickHouse::IPv4).to_s.should eq("192.168.1.10")
    row["ip6"].raw.as(ClickHouse::IPv6).bytes.to_slice.should eq("20010db8000000000000000000000001".hexbytes)
    row["amount"].as_decimal.unscaled.should eq(-123456789012345678901234_i128)
    row["kind"].as_s.should eq("off")
    row["items"].as_array.map(&.raw).should eq([1_u16, nil, 3_u16])
    row["details"].as_tuple.values[0].as_s.should eq("Ada")
    row["pairs"].as_map.entries.map { |key, value| {key.as_s, value.as_u64} }.should eq([{"a", 1_u64}, {"a", 2_u64}])
    row["category"].as_s.should eq("Ada")
    row["optional_category"].null?.should be_true
    row["categories"].as_array.map(&.as_s).should eq(["Ada", "Grace"])
  end

  it "reads independent revision-zero and TCP SELECT 1 vectors" do
    raw = "010101310555496e743801".hexbytes
    block = ClickHouse::Codecs::BlockCodec.read(ClickHouse::Protocol::Reader.new(IO::Memory.new(raw)), 0)
    ClickHouse::Row.new(block, 0)["1"].as_u64.should eq(1_u64)
    output = IO::Memory.new
    ClickHouse::Codecs::BlockCodec.write(ClickHouse::Protocol::Writer.new(output), block, 0)
    output.to_slice.should eq(raw)

    tcp = "010002ffffffff00010101310555496e74380001".hexbytes
    decoded = ClickHouse::Codecs::BlockCodec.read(ClickHouse::Protocol::Reader.new(IO::Memory.new(tcp)), 54460)
    decoded.columns[0][0].as_u64.should eq(1_u64)
    output = IO::Memory.new
    ClickHouse::Codecs::BlockCodec.write(ClickHouse::Protocol::Writer.new(output), decoded, 54460)
    output.to_slice.should eq(tcp)
  end

  it "rejects custom serialization, unknown block info, and unsupported revisions" do
    custom = "010002ffffffff00010101310555496e74380101".hexbytes
    expect_raises(ClickHouse::CodecError, /custom/) do
      ClickHouse::Codecs::BlockCodec.read(ClickHouse::Protocol::Reader.new(IO::Memory.new(custom)), 54460)
    end
    expect_raises(ClickHouse::CodecError, /BlockInfo/) do
      ClickHouse::Codecs::BlockCodec.read(ClickHouse::Protocol::Reader.new(IO::Memory.new(Bytes[3])), 54460)
    end
    expect_raises(ClickHouse::CodecError, /revision/) do
      ClickHouse::Codecs::BlockCodec.read(ClickHouse::Protocol::Reader.new(IO::Memory.new), 54492)
    end
  end

  it "owns prior rows after decoding another block" do
    first = ClickHouse::Block.new([ClickHouse::Column.new("name", "String", [ClickHouse::Value.wrap("Ada")])])
    second = ClickHouse::Block.new([ClickHouse::Column.new("name", "String", [ClickHouse::Value.wrap("Grace")])])
    output = IO::Memory.new
    [first, second].each { |block| ClickHouse::Codecs::BlockCodec.write(ClickHouse::Protocol::Writer.new(output), block, 54460) }
    input = ClickHouse::Protocol::Reader.new(IO::Memory.new(output.to_slice))
    retained = ClickHouse::Row.new(ClickHouse::Codecs::BlockCodec.read(input, 54460), 0)
    ClickHouse::Codecs::BlockCodec.read(input, 54460)
    retained["name"].as_s.should eq("Ada")
  end
end

describe ClickHouse::Codecs::ColumnCodec do
  it "encodes and decodes the full-width unsigned maxima and signed negative-one vectors" do
    {"UInt8" => 1, "UInt16" => 2, "UInt32" => 4, "UInt64" => 8, "UInt128" => 16}.each do |type, size|
      bytes = Bytes.new(size, 255_u8)
      expected = size == 16 ? UInt128::MAX : (1_u128 << (size * 8)) - 1
      CodecSpec.decode(type, bytes)[0].as_u128.should eq(expected)
      CodecSpec.encode(type, [ClickHouse::Value.wrap(expected)]).should eq(bytes)
    end
    {"Int8" => 1, "Int16" => 2, "Int32" => 4, "Int64" => 8, "Int128" => 16}.each do |type, size|
      bytes = Bytes.new(size, 255_u8)
      CodecSpec.decode(type, bytes)[0].as_i128.should eq(-1_i128)
      CodecSpec.encode(type, [ClickHouse::Value.wrap(-1_i128)]).should eq(bytes)
    end
    CodecSpec.decode("Float32", "0000803f".hexbytes)[0].as_f64.should eq(1.0)
    CodecSpec.decode("Float64", "000000000000f07f".hexbytes)[0].as_f64.infinite?.should eq(1)
    CodecSpec.decode("Float64", "000000000000f87f".hexbytes)[0].as_f64.nan?.should be_true
    CodecSpec.decode("Bool", Bytes[0, 1, 255], 3).map(&.as_bool).should eq([false, true, true])
    expect_raises(ClickHouse::CodecError) { CodecSpec.encode("Int8", [ClickHouse::Value.wrap(128_u16)]) }
    expect_raises(ClickHouse::CodecError) { CodecSpec.encode("UInt8", [ClickHouse::Value.wrap(-1_i16)]) }
  end

  it "decodes independent numeric, binary, nullable, and date vectors" do
    CodecSpec.decode("Int16", "ffff0080ff7f".hexbytes, 3).map(&.as_i64).should eq([-1_i64, -32768_i64, 32767_i64])
    CodecSpec.decode("UInt64", "ffffffffffffffff".hexbytes)[0].as_u64.should eq(UInt64::MAX)
    CodecSpec.decode("UInt128", "ffffffffffffffffffffffffffffffff".hexbytes)[0].as_u128.should eq(UInt128::MAX)
    CodecSpec.decode("String", "0300ff61".hexbytes)[0].as_bytes.should eq(Bytes[0, 255, 97])
    CodecSpec.decode("FixedString(3)", "610000".hexbytes)[0].as_bytes.should eq(Bytes[97, 0, 0])
    CodecSpec.decode("Nullable(UInt8)", "000100050009".hexbytes, 3).map(&.raw).should eq([5_u8, nil, 9_u8])
    CodecSpec.decode("Nullable(Nothing)", "01013030".hexbytes, 2).all?(&.null?).should be_true
    CodecSpec.decode("Date32", "ffffffff".hexbytes)[0].raw.as(ClickHouse::DateValue).days.should eq(-1)
    timestamp = CodecSpec.decode("DateTime64(3, 'UTC')", "ffffffffffffffff".hexbytes)[0].as_timestamp
    timestamp.ticks.should eq(-1)
    timestamp.to_time.should eq(Time.unix(-1) + 999.milliseconds)
  end

  it "uses the ClickHouse UUID and IP byte order" do
    uuid = UUID.new("550e8400-e29b-41d4-a716-446655440000")
    bytes = "d4419be200840e5500004455664416a7".hexbytes
    CodecSpec.decode("UUID", bytes)[0].as_uuid.should eq(uuid)
    CodecSpec.encode("UUID", [ClickHouse::Value.wrap(uuid)]).should eq(bytes)
    CodecSpec.decode("IPv4", "0a01a8c0".hexbytes)[0].raw.as(ClickHouse::IPv4).to_s.should eq("192.168.1.10")
    ipv6 = CodecSpec.decode("IPv6", "20010db8000000000000000000000001".hexbytes)[0]
    CodecSpec.encode("IPv6", [ipv6]).should eq("20010db8000000000000000000000001".hexbytes)
  end

  it "preserves exact decimals, signed enum codes, and padding" do
    decimal = ClickHouse::Decimal.new(-15_i128, 1)
    CodecSpec.decode("Decimal(18,1)", "f1ffffffffffffff".hexbytes)[0].as_decimal.should eq(decimal)
    CodecSpec.encode("Decimal64(1)", [ClickHouse::Value.wrap(decimal)]).should eq("f1ffffffffffffff".hexbytes)
    enum_value = CodecSpec.decode("Enum8('active'=1,'disabled'=-1)", Bytes[255])[0]
    enum_value.as_s.should eq("disabled")
    enum_value.raw.as(ClickHouse::EnumValue).code.should eq(-1)
    # A null position's enum placeholder need not be a declared variant.
    CodecSpec.decode("Nullable(Enum8('one'=1))", Bytes[1, 0])[0].null?.should be_true
    expect_raises(ClickHouse::CodecError) { CodecSpec.decode("Enum8('one'=1)", Bytes[0]) }
    CodecSpec.encode("FixedString(3)", [ClickHouse::Value.wrap("a")]).should eq(Bytes[97, 0, 0])
    expect_raises(ClickHouse::CodecError) { CodecSpec.encode("Decimal(3,1)", [ClickHouse::Value.wrap(ClickHouse::Decimal.new(1000_i128, 1))]) }
  end

  it "reads independent array offsets and preserves duplicate map keys" do
    bytes = "020000000000000002000000000000000300000000000000010203".hexbytes
    values = CodecSpec.decode("Array(UInt8)", bytes, 3)
    values.map { |value| value.as_array.map(&.as_u64) }.should eq([[1_u64, 2_u64], [] of UInt64, [3_u64]])
    map = ClickHouse::MapValue.new([{ClickHouse::Value.wrap("a"), ClickHouse::Value.wrap(1_u8)}, {ClickHouse::Value.wrap("a"), ClickHouse::Value.wrap(2_u8)}])
    actual = CodecSpec.round_trip("Map(String,UInt8)", [ClickHouse::Value.wrap(map)])[0].as_map
    actual.entries.should eq(map.entries)
  end

  it "runs state prefixes before composite offsets and handles empty flattened values" do
    # LC version; array offset=2; metadata=0x600; dictionary=["", "a"]; two keys.
    bytes = "010000000000000002000000000000000006000000000000020000000000000000016102000000000000000101".hexbytes
    value = CodecSpec.decode("Array(LowCardinality(String))", bytes)[0]
    value.as_array.map(&.as_s).should eq(["a", "a"])
    empty = "01000000000000000000000000000000".hexbytes
    CodecSpec.decode("Array(LowCardinality(String))", empty)[0].as_array.should be_empty
    CodecSpec.encode("Array(LowCardinality(String))", [ClickHouse::Value.wrap([] of String)]).should eq(empty)
  end

  it "round-trips named tuples, nullable dictionaries, and changing block dictionaries" do
    tuple = ClickHouse::Value.wrap({"Ada", [1_u16, 2_u16]})
    result = CodecSpec.round_trip("Tuple(name String, ids Array(UInt16))", [tuple])[0].as_tuple
    result.names.should eq(["name", "ids"])
    result.values[0].as_s.should eq("Ada")
    result.values[1].as_array.map(&.as_u64).should eq([1_u64, 2_u64])
    ["Ada", "Grace"].each do |name|
      values = [ClickHouse::Value.wrap(nil), ClickHouse::Value.wrap(""), ClickHouse::Value.wrap(name)]
      CodecSpec.round_trip("LowCardinality(Nullable(String))", values).should eq(values)
    end
  end

  it "promotes LowCardinality keys at the exact UInt8 boundary and rejects invalid indices" do
    values = (1..256).map { |index| ClickHouse::Value.wrap("name-#{index}") }
    # The encoder reserves a default dictionary slot, so 255 names need UInt8 keys.
    narrow = CodecSpec.encode("LowCardinality(String)", values.first(255))
    narrow[8].should eq(0_u8)
    wide = CodecSpec.encode("LowCardinality(String)", values)
    wide[8].should eq(1_u8)
    CodecSpec.decode("LowCardinality(String)", wide, values.size).should eq(values)
    # An independent one-entry dictionary with an invalid key 1.
    invalid = "01000000000000000006000000000000010000000000000000010000000000000001".hexbytes
    expect_raises(ClickHouse::CodecError, /index/) { CodecSpec.decode("LowCardinality(String)", invalid) }
  end

  it "rejects malformed offsets, excessive allocation, unknown types, and every truncated vector" do
    expect_raises(ClickHouse::CodecError, /offset/) { CodecSpec.decode("Array(UInt8)", "02000000000000000100000000000000".hexbytes, 2) }
    expect_raises(ClickHouse::CodecError, /budget/) { CodecSpec.decode("String", "ffffffffffffffffff01".hexbytes) }
    expect_raises(ClickHouse::CodecError, /unsupported/) { CodecSpec.decode("JSON", Bytes.empty, 0) }
    bytes = CodecSpec.encode("Array(LowCardinality(String))", [ClickHouse::Value.wrap(["Ada", "Grace"])])
    bytes.size.times do |length|
      expect_raises(Exception) { CodecSpec.decode("Array(LowCardinality(String))", bytes[0, length]) }
    end
  end
end
