require "spec"
require "../../src/clickhouse/types/parser"

describe ClickHouse::Types::Parser do
  it "parses nested named tuples, quoted enum labels, and timezone parameters" do
    type = ClickHouse::Types::Parser.parse("Tuple(`display name` String, events Array(Tuple(at DateTime64(9, 'UTC'), kind Enum8('a,b' = -1, 'it\\'s' = 7))))")
    type.field_names.should eq(["display name", "events"])
    tuple = type.children[1].children[0]
    tuple.children[0].parameters.should eq(["9", "UTC"])
    tuple.children[1].enum_values.should eq({"a,b" => -1_i16, "it's" => 7_i16})
  end

  it "rejects malformed, duplicate, and excessively nested expressions" do
    ["Array(UInt8", "UInt8 garbage", "Decimal(9,)", "Enum8('a'=1,'a'=2)", "Array(" * 34 + "UInt8" + ")" * 34].each do |expression|
      expect_raises(ClickHouse::CodecError) { ClickHouse::Types::Parser.parse(expression) }
    end
  end
end
