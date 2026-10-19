require "spec"
require "../../src/clickhouse/protocol/parameters"

describe ClickHouse::Protocol::Parameters do
  it "matches the official clickhouse-go top-level TSV text vectors" do
    # Independent vectors from query_parameters_test.go at clickhouse-go commit
    # 264ecebc123a794563a2f24ba40d3fd0e7817133 (TestNamedStringEscaper).
    vectors = [
      {"hello", "hello"},
      {"a\tb", "a\\tb"},
      {"a\nb", "a\\nb"},
      {"a\rb", "a\\rb"},
      {"a\\b", "a\\\\b"},
      {"a\\nb", "a\\\\nb"},
      {"it's", "it's"},
      {"a\u0000b", "a\\0b"},
    ]
    vectors.each do |input, expected|
      ClickHouse::Protocol::Parameters.text(input).should eq(expected)
    end
  end

  it "keeps top-level null distinct from text NULL, backslash N, and empty strings" do
    encoded = ClickHouse::Protocol::Parameters.encode({missing: nil, word: "NULL", marker: "\\N", empty: ""})
    encoded.values.uniq!.size.should eq(4)
    encoded.keys.should eq(["missing", "word", "marker", "empty"])
  end

  it "accepts symbol or string names and rejects query-shaped names before writing" do
    ClickHouse::Protocol::Parameters.encode({id: 42_u64}).should eq(
      ClickHouse::Protocol::Parameters.encode({"id" => 42_u64})
    )
    ["", "1id", "id; SELECT 1", "id:String}", "a\u0000b", "na-me"].each do |name|
      expect_raises(ArgumentError, "parameter name") do
        ClickHouse::Protocol::Parameters.encode({name => "value"})
      end
    end
  end

  it "rejects temporal values affected by the server's negative-zero epoch parser" do
    instant = Time.utc(1969, 12, 31, 23, 59, 59, nanosecond: 500_000_000)
    expect_raises(ArgumentError) { ClickHouse::Protocol::Parameters.encode({instant: instant}) }
    expect_raises(ArgumentError) do
      ClickHouse::Protocol::Parameters.encode({instant: ClickHouse::Timestamp.new(-500_i64, 3, "UTC")})
    end
  end

  it "encodes identical binary strings and Bytes without modifying either input" do
    bytes = Bytes[0, 9, 10, 13, 39, 92, 0xff]
    original = bytes.dup
    text = String.new(bytes)
    string_values = {"payload" => text}
    ClickHouse::Protocol::Parameters.encode(string_values).should eq(
      ClickHouse::Protocol::Parameters.encode({payload: bytes})
    )
    bytes.should eq(original)
    string_values["payload"].to_slice.should eq(original)
  end
end
