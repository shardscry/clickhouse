require "spec"
require "json"
require "../../src/clickhouse/codecs/block_codec"

describe "independently captured revision-54460 server blocks" do
  Dir[File.join(__DIR__, "../fixtures/protocol_54460_*.json")].sort.each do |path|
    it "decodes real #{File.basename(path)} packets without trailing bytes" do
      fixture = JSON.parse(File.read(path))
      fixture["client_revision"].as_i.should eq(54460)
      matched = false
      packet_count = 0
      fixture["trace"].as_a.each do |packet|
        next unless packet["direction"].as_s == "server" && packet["packet"].as_s == "Data"
        bytes = packet["hex"].as_s.hexbytes
        memory = IO::Memory.new(bytes)
        reader = ClickHouse::Protocol::Reader.new(memory)
        reader.var_uint.should eq(1_u64)
        reader.string.should eq("")
        block = ClickHouse::Codecs::BlockCodec.read(reader, 54460)
        memory.pos.should eq(bytes.size)
        packet_count += 1
        answer = block.columns.find { |column| column.name == "answer" }
        name = block.columns.find { |column| column.name == "name" }
        if answer && name && block.row_count == 1
          answer.values.first.as_u64.should eq(42_u64)
          name.values.first.as_s.should eq("Ada")
          matched = true
        end
      end
      packet_count.should be > 10
      matched.should be_true
    end
  end
end
