require "spec"
require "../../src/clickhouse"

module ParameterIntegrationSupport
  def self.with_client(&)
    url = ENV["CLICKHOUSE_URL"]? || "clickhouse://default:clickhouse_test@127.0.0.1:19000/default"
    compression = ENV["CLICKHOUSE_COMPRESSION"]? == "lz4" ? :lz4 : :none
    client = ClickHouse::Client.from_string(url, compression: compression)
    begin
      yield client
    ensure
      client.close
    end
  end
end

if ENV["CLICKHOUSE_INTEGRATION"]? == "1"
  describe "native typed parameter conformance" do
    it "distinguishes top-level NULL, NULL text, empty strings, and literal escape markers" do
      ParameterIntegrationSupport.with_client do |client|
        row = client.query(
          "SELECT {missing:Nullable(String)} AS missing, {word:Nullable(String)} AS word, {empty:String} AS empty, {marker:String} AS marker",
          params: {missing: nil, word: "NULL", empty: "", marker: "\\N"},
        ).rows.first
        row["missing"].null?.should be_true
        row["word"].null?.should be_false
        row["word"].as_s.should eq("NULL")
        row["empty"].as_s.should eq("")
        row["marker"].as_s.should eq("\\N")
      end
    end

    it "preserves both TSV and Field escaping, every ASCII control byte, and invalid UTF-8" do
      payload = Bytes.new(256, &.to_u8)
      ParameterIntegrationSupport.with_client do |client|
        row = client.query("SELECT {payload:String} AS payload", params: {payload: payload}).rows.first
        row["payload"].as_bytes.should eq(payload)
      end
    end

    it "keeps SQL-shaped application values separate from the query text" do
      text = "'); SELECT 999 AS injected; -- \\N\\t\\n actual\t\n\u0000Ω"
      ParameterIntegrationSupport.with_client do |client|
        rows = client.query("SELECT {text:String} AS text, toUInt8(7) AS sentinel", params: {text: text}).rows
        rows.size.should eq(1)
        rows.first["text"].as_s.should eq(text)
        rows.first["sentinel"].as_u64.should eq(7_u64)
      end
    end

    it "preserves UInt64/UInt128 maxima, signed extrema, booleans, and floating-point values" do
      ParameterIntegrationSupport.with_client do |client|
        row = client.query(
          "SELECT {u64:UInt64} AS u64, {u128:UInt128} AS u128, {signed:Int128} AS signed, {flag:Bool} AS flag, {number:Float64} AS number",
          params: {u64: UInt64::MAX, u128: UInt128::MAX, signed: Int128::MIN, flag: true, number: -1.234567890123456e-100},
        ).rows.first
        row["u64"].as_u64.should eq(UInt64::MAX)
        row["u128"].as_u128.should eq(UInt128::MAX)
        row["signed"].as_i128.should eq(Int128::MIN)
        row["flag"].as_bool.should be_true
        row["number"].as_f64.should eq(-1.234567890123456e-100)
      end
    end

    it "preserves exact negative decimals including fractional values between minus one and zero" do
      amount = ClickHouse::Decimal.new(-123_456_789_012_345_678_901_234_567_890_i128, 7)
      tiny = ClickHouse::Decimal.new(-1_i128, 18)
      ParameterIntegrationSupport.with_client do |client|
        row = client.query(
          "SELECT {amount:Decimal(38, 7)} AS amount, {tiny:Decimal(38, 18)} AS tiny",
          params: {amount: amount, tiny: tiny},
        ).rows.first
        row["amount"].as_decimal.should eq(amount)
        row["tiny"].as_decimal.should eq(tiny)
      end
    end

    it "preserves nested nullable arrays and quoted tuple strings" do
      nested = [["Ada's\\path\n\t\u0000", nil, "NULL"], ["", "\\N", "Ω"]]
      pair = {42_u64, "tuple's\\value\n\u0000"}
      ParameterIntegrationSupport.with_client do |client|
        row = client.query(
          "SELECT {nested:Array(Array(Nullable(String)))} AS nested, {pair:Tuple(UInt64, String)} AS pair",
          params: {nested: nested, pair: pair},
        ).rows.first
        actual = row["nested"].as_array.map do |array|
          array.as_array.map { |value| value.null? ? nil : value.as_s }
        end
        actual.should eq(nested)
        values = row["pair"].as_tuple.values
        values[0].as_u64.should eq(42_u64)
        values[1].as_s.should eq(pair[1])
      end
    end

    it "preserves ordinary Hash values and duplicate ordered MapValue entries" do
      mapping = {"quoted'key" => "value\\with\ncontrols\u0000", "empty" => ""}
      entries = [
        {ClickHouse::Value.new("role"), ClickHouse::Value.new("reader")},
        {ClickHouse::Value.new("role"), ClickHouse::Value.new("writer's\\role")},
      ]
      ParameterIntegrationSupport.with_client do |client|
        row = client.query(
          "SELECT {mapping:Map(String, String)} AS mapping, {duplicates:Map(String, String)} AS duplicates",
          params: {mapping: mapping, duplicates: ClickHouse::MapValue.new(entries)},
        ).rows.first
        row["mapping"].as_map.entries.map { |key, value| {key.as_s, value.as_s} }.should eq(mapping.to_a)
        row["duplicates"].as_map.entries.should eq(entries)
      end
    end

    it "quotes EnumValue labels inside nested arrays" do
      label = "reader's\\role"
      role = ClickHouse::EnumValue.new(1_i16, label)
      ParameterIntegrationSupport.with_client do |client|
        row = client.query(
          "SELECT {roles:Array(Enum8('reader\\'s\\\\role' = 1))} AS roles",
          params: {roles: [role]},
        ).rows.first
        row["roles"].as_array.first.raw.as(ClickHouse::EnumValue).should eq(role)
      end
    end

    it "preserves nested DateTime64 instants and nullable Decimal values" do
      instants = [ClickHouse::Timestamp.new(1_700_000_000_123_i64, 3), ClickHouse::Timestamp.new(-123_456_i64, 3)]
      amounts = [ClickHouse::Decimal.new(123_i128, 2), nil, ClickHouse::Decimal.new(-1_i128, 2)]
      ParameterIntegrationSupport.with_client do |client|
        row = client.query(
          "SELECT {instants:Array(DateTime64(3, 'UTC'))} AS instants, {amounts:Array(Nullable(Decimal(18, 2)))} AS amounts",
          params: {instants: instants, amounts: amounts},
        ).rows.first
        row["instants"].as_array.map(&.as_timestamp.ticks).should eq(instants.map(&.ticks))
        row["amounts"].as_array.map { |value| value.null? ? nil : value.as_decimal }.should eq(amounts)
      end
    end

    it "preserves UUID and IPv4/IPv6 values including nested UUID quoting" do
      id = UUID.new("00112233-4455-6677-8899-aabbccddeeff")
      ipv4 = ClickHouse::IPv4.new(0xc0000201_u32)
      ipv6 = ClickHouse::IPv6.new(StaticArray[0x20_u8, 0x01_u8, 0x0d_u8, 0xb8_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8])
      ParameterIntegrationSupport.with_client do |client|
        row = client.query(
          "SELECT {id:UUID} AS id, {ipv4:IPv4} AS ipv4, {ipv6:IPv6} AS ipv6, {ids:Array(UUID)} AS ids",
          params: {id: id, ipv4: ipv4, ipv6: ipv6, ids: [id]},
        ).rows.first
        row["id"].as_uuid.should eq(id)
        row["ipv4"].raw.as(ClickHouse::IPv4).should eq(ipv4)
        row["ipv6"].raw.as(ClickHouse::IPv6).should eq(ipv6)
        row["ids"].as_array.first.as_uuid.should eq(id)
      end
    end

    it "preserves whole-second Time values when the parameter is DateTime" do
      instant = Time.utc(2026, 1, 2, 3, 4, 5)
      ParameterIntegrationSupport.with_client do |client|
        row = client.query("SELECT {instant:DateTime('UTC')} AS instant", params: {instant: instant}).rows.first
        row["instant"].as_timestamp.ticks.should eq(instant.to_unix)
        row["instant"].as_timestamp.timezone.should eq("UTC")
      end
    end

    it "preserves negative fractional Time instants independently of their local timezone" do
      instant = Time.utc(1969, 12, 31, 23, 59, 58, nanosecond: 500_000_000)
      shifted = instant.in(Time::Location.fixed(19_800))
      ParameterIntegrationSupport.with_client do |client|
        row = client.query(
          "SELECT {utc:DateTime64(9, 'UTC')} AS utc, {shifted:DateTime64(9, 'Asia/Kolkata')} AS shifted",
          params: {utc: instant, shifted: shifted},
        ).rows.first
        row["utc"].as_timestamp.ticks.should eq(-1_500_000_000_i64)
        row["shifted"].as_timestamp.ticks.should eq(-1_500_000_000_i64)
        row["shifted"].as_timestamp.timezone.should eq("Asia/Kolkata")
      end
    end

    it "rejects ambiguous negative-zero epoch parameters before sending and supports an exact Int64 workaround" do
      instant = Time.utc(1969, 12, 31, 23, 59, 59, nanosecond: 500_000_000)
      timestamp = ClickHouse::Timestamp.new(-500_i64, 3)
      ParameterIntegrationSupport.with_client do |client|
        expect_raises(ArgumentError) do
          client.query("SELECT {instant:DateTime64(9, 'UTC')} AS instant", params: {instant: instant})
        end
        client.ping.should be_true
        expect_raises(ArgumentError) do
          client.query("SELECT {instant:DateTime64(3, 'UTC')} AS instant", params: {instant: timestamp})
        end
        client.ping.should be_true
        row = client.query(
          "SELECT fromUnixTimestamp64Nano({ticks:Int64}, 'Asia/Kolkata') AS instant",
          params: {ticks: -500_000_000_i64},
        ).rows.first
        row["instant"].as_timestamp.ticks.should eq(-500_000_000_i64)
        row["instant"].as_timestamp.timezone.should eq("Asia/Kolkata")
      end
    end

    it "preserves Timestamp scale, negative ticks, and the destination timezone metadata" do
      instant = ClickHouse::Timestamp.new(-123_456_i64, 3, "UTC")
      ParameterIntegrationSupport.with_client do |client|
        row = client.query(
          "SELECT {instant:DateTime64(3, 'Asia/Tokyo')} AS instant",
          params: {instant: instant},
        ).rows.first
        row["instant"].as_timestamp.ticks.should eq(instant.ticks)
        row["instant"].as_timestamp.precision.should eq(instant.precision)
        row["instant"].as_timestamp.timezone.should eq("Asia/Tokyo")
      end
    end

    it "preserves Date32 days before the epoch" do
      date = ClickHouse::DateValue.new(-1)
      ParameterIntegrationSupport.with_client do |client|
        row = client.query("SELECT {date:Date32} AS date", params: {date: date}).rows.first
        row["date"].raw.as(ClickHouse::DateValue).should eq(date)
      end
    end

    it "quotes DateValue calendar text within arrays and explicit TupleValue wrappers" do
      dates = [ClickHouse::DateValue.new(-1), ClickHouse::DateValue.new(0)]
      tuple = ClickHouse::TupleValue.new([ClickHouse::Value.new("Ada's tuple"), ClickHouse::Value.new(dates.first)])
      ParameterIntegrationSupport.with_client do |client|
        row = client.query(
          "SELECT {dates:Array(Date32)} AS dates, {tuple:Tuple(String, Date32)} AS tuple",
          params: {dates: dates, tuple: tuple},
        ).rows.first
        row["dates"].as_array.map(&.raw.as(ClickHouse::DateValue)).should eq(dates)
        row["tuple"].as_tuple.values[0].as_s.should eq("Ada's tuple")
        row["tuple"].as_tuple.values[1].raw.as(ClickHouse::DateValue).should eq(dates.first)
      end
    end

    it "preserves nested whole-second Time values as DateTime parameters" do
      instants = [Time.utc(2026, 1, 2, 3, 4, 5), Time.utc(2026, 1, 2, 3, 4, 6)]
      ParameterIntegrationSupport.with_client do |client|
        row = client.query(
          "SELECT {instants:Array(DateTime('UTC'))} AS instants",
          params: {instants: instants},
        ).rows.first
        row["instants"].as_array.map(&.as_timestamp.ticks).should eq(instants.map(&.to_unix))
      end
    end
  end
end
