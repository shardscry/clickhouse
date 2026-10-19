require "spec"
require "../../src/clickhouse"

module TypeIntegrationSupport
  def self.with_client(&)
    url = ENV["CLICKHOUSE_URL"]? || "clickhouse://default:clickhouse_test@127.0.0.1:19000/default"
    compression = ENV["CLICKHOUSE_COMPRESSION"]? == "lz4" ? :lz4 : :none
    client = ClickHouse::Client.from_string(url, compression: compression, batch_size: 1)
    begin
      yield client
    ensure
      client.close
    end
  end

  def self.pairs : ClickHouse::MapValue
    ClickHouse::MapValue.new([
      {ClickHouse::Value.wrap("a"), ClickHouse::Value.wrap(1_u8)},
      {ClickHouse::Value.wrap("a"), ClickHouse::Value.wrap(2_u8)},
    ])
  end
end

if ENV["CLICKHOUSE_INTEGRATION"]? == "1"
  describe "native analytical type interoperability" do
    it "decodes server values without narrowing binary, wide numeric, or timestamp data" do
      TypeIntegrationSupport.with_client do |client|
        row = client.query(<<-SQL).rows.first
          SELECT
            toUInt64('18446744073709551615') AS unsigned64,
            toUInt128('340282366920938463463374607431768211455') AS unsigned128,
            toInt128('-170141183460469231731687303715884105728') AS signed128,
            unhex('00ff61') AS binary,
            toFixedString(unhex('00ff61'), 5) AS fixed,
            CAST(NULL AS Nullable(UInt16)) AS absent,
            NULL AS nothing,
            toDateTime64('1969-12-31 23:59:59.999', 3, 'UTC') AS precise,
            toUUID('550e8400-e29b-41d4-a716-446655440000') AS uid,
            toIPv4('192.168.1.10') AS ip4,
            toIPv6('2001:db8::1') AS ip6,
            toDecimal128('-12345678901234567890.1234', 4) AS amount,
            CAST('off' AS Enum8('on'=1,'off'=-1)) AS kind
          SQL
        row["unsigned64"].as_u64.should eq(UInt64::MAX)
        row["unsigned128"].as_u128.should eq(UInt128::MAX)
        row["signed128"].as_i128.should eq(Int128::MIN)
        row["binary"].as_bytes.should eq(Bytes[0, 255, 97])
        row["fixed"].as_bytes.should eq(Bytes[0, 255, 97, 0, 0])
        row["absent"].null?.should be_true
        row["nothing"].null?.should be_true
        row["precise"].as_timestamp.should eq(ClickHouse::Timestamp.new(-1_i64, 3, "UTC"))
        row["uid"].as_uuid.should eq(UUID.new("550e8400-e29b-41d4-a716-446655440000"))
        row["ip4"].raw.as(ClickHouse::IPv4).to_s.should eq("192.168.1.10")
        row["ip6"].raw.as(ClickHouse::IPv6).bytes.to_slice.should eq("20010db8000000000000000000000001".hexbytes)
        row["amount"].as_decimal.should eq(ClickHouse::Decimal.new(-123456789012345678901234_i128, 4))
        row["kind"].as_s.should eq("off")
      end
    end

    it "inserts and reads common analytical types with per-block dictionaries and ordered duplicate map keys" do
      TypeIntegrationSupport.with_client do |client|
        table = "crystal_types_#{UUID.random.to_s.delete('-')}"
        client.exec(<<-SQL)
          CREATE TABLE #{table} (
            id UInt64, signed Int128, unsigned UInt128, binary String,
            fixed FixedString(5), day Date, day32 Date32,
            moment DateTime('UTC'), precise DateTime64(9,'UTC'),
            uid UUID, ip4 IPv4, ip6 IPv6, amount Decimal(38,4),
            kind Enum8('on'=1,'off'=-1), optional Nullable(UInt16),
            items Array(Nullable(UInt16)), details Tuple(name String, ids Array(UInt16)),
            pairs Map(String,UInt8), category LowCardinality(String),
            optional_category LowCardinality(Nullable(String)),
            categories Array(LowCardinality(String))
          ) ENGINE=Memory
          SQL
        begin
          names = ["Ada", "Grace", "Katherine"]
          client.insert(table, columns: ["id", "signed", "unsigned", "binary", "fixed", "day", "day32", "moment", "precise", "uid", "ip4", "ip6", "amount", "kind", "optional", "items", "details", "pairs", "category", "optional_category", "categories"]) do |batch|
            names.each_with_index do |name, index|
              values = [
                ClickHouse::Value.wrap(index.to_u64),
                ClickHouse::Value.wrap(Int128::MIN),
                ClickHouse::Value.wrap(UInt128::MAX),
                ClickHouse::Value.wrap(Bytes[0, 255, 97]),
                ClickHouse::Value.wrap(Bytes[0, 255, 97]),
                ClickHouse::Value.wrap(ClickHouse::DateValue.new(19_000)),
                ClickHouse::Value.wrap(ClickHouse::DateValue.new(-1)),
                ClickHouse::Value.wrap(ClickHouse::Timestamp.new(1_705_321_845_i64, 0, "UTC")),
                ClickHouse::Value.wrap(ClickHouse::Timestamp.new(-1_i64, 9, "UTC")),
                ClickHouse::Value.wrap(UUID.new("550e8400-e29b-41d4-a716-446655440000")),
                ClickHouse::Value.wrap(ClickHouse::IPv4.new(0xc0a8010a_u32)),
                ClickHouse::Value.wrap(ClickHouse::IPv6.new(StaticArray(UInt8, 16).new { |position| "20010db8000000000000000000000001".hexbytes[position] })),
                ClickHouse::Value.wrap(ClickHouse::Decimal.new(-123456789012345678901234_i128, 4)),
                ClickHouse::Value.wrap("off"),
                ClickHouse::Value.wrap(nil),
                ClickHouse::Value.wrap([ClickHouse::Value.wrap(1_u16), ClickHouse::Value.wrap(nil), ClickHouse::Value.wrap(3_u16)]),
                ClickHouse::Value.wrap({name, [1_u16, 2_u16]}),
                ClickHouse::Value.wrap(TypeIntegrationSupport.pairs),
                ClickHouse::Value.wrap(name),
                ClickHouse::Value.wrap(index == 0 ? nil : name),
                ClickHouse::Value.wrap(index == 0 ? [] of String : [name, name]),
              ]
              batch.append(values)
            end
          end
          rows = client.query("SELECT * FROM #{table} ORDER BY id", settings: {max_block_size: 1, max_threads: 1}).rows
          rows.size.should eq(3)
          rows.each_with_index do |row, index|
            row["id"].as_u64.should eq(index.to_u64)
            row["signed"].as_i128.should eq(Int128::MIN)
            row["unsigned"].as_u128.should eq(UInt128::MAX)
            row["binary"].as_bytes.should eq(Bytes[0, 255, 97])
            row["fixed"].as_bytes.should eq(Bytes[0, 255, 97, 0, 0])
            row["day"].raw.as(ClickHouse::DateValue).days.should eq(19_000)
            row["day32"].raw.as(ClickHouse::DateValue).days.should eq(-1)
            row["moment"].as_timestamp.ticks.should eq(1_705_321_845_i64)
            row["precise"].as_timestamp.ticks.should eq(-1_i64)
            row["amount"].as_decimal.unscaled.should eq(-123456789012345678901234_i128)
            row["kind"].as_s.should eq("off")
            row["optional"].null?.should be_true
            row["items"].as_array.map(&.raw).should eq([1_u16, nil, 3_u16])
            row["details"].as_tuple.names.should eq(["name", "ids"])
            row["details"].as_tuple.values[0].as_s.should eq(names[index])
            row["pairs"].as_map.entries.should eq(TypeIntegrationSupport.pairs.entries)
            row["category"].as_s.should eq(names[index])
            if index == 0
              row["optional_category"].null?.should be_true
              row["categories"].as_array.should be_empty
            else
              row["optional_category"].as_s.should eq(names[index])
              row["categories"].as_array.map(&.as_s).should eq([names[index], names[index]])
            end
          end
        ensure
          TypeIntegrationSupport.with_client { |cleanup| cleanup.exec("DROP TABLE IF EXISTS #{table}") }
        end
      end
    end
  end
end
