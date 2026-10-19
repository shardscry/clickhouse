# ameba:disable Lint/SpecFilename
require "json"
require "../../src/clickhouse"

class ScriptedPeer < IO
  getter output = IO::Memory.new
  property close_error : Exception?
  @closed = false

  def initialize(response : Bytes, @fragment_size : Int32 = 3)
    @input = IO::Memory.new(self.class.join(self.class.hello, response))
  end

  def read(slice : Bytes) : Int32
    raise IO::Error.new("scripted peer is closed") if @closed
    @input.read(slice[0, Math.min(@fragment_size, slice.size)])
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("scripted peer is closed") if @closed
    @output.write(slice)
  end

  def close : Nil
    if error = @close_error
      raise error
    end
    @closed = true
  end

  def closed? : Bool
    @closed
  end

  def self.join(*parts : Bytes) : Bytes
    output = IO::Memory.new
    parts.each { |part| output.write(part) }
    output.to_slice.dup
  end

  def self.hello : Bytes
    captured("ServerHello")
  end

  def self.exception : Bytes
    captured("Exception")
  end

  def self.answer_schema : Bytes
    captured("Data", "0100010002ffffffff00020006616e73776572")
  end

  def self.answer_rows : Bytes
    captured("Data", "0100010002ffffffff00020106616e73776572")
  end

  def self.insert_schema : Bytes
    captured("Data", "0100010002ffffffff000200026964")
  end

  private def self.captured(packet : String, prefix : String? = nil) : Bytes
    document = JSON.parse(File.read("#{__DIR__}/../fixtures/protocol_54460_lts.json"))
    event = document["trace"].as_a.find do |item|
      hex = item["hex"]?.try(&.as_s)
      item["direction"].as_s == "server" && item["packet"].as_s == packet &&
        hex && (prefix.nil? || hex.starts_with?(prefix))
    end
    raise "missing captured #{packet} fixture" unless event
    event["hex"].as_s.hexbytes
  end
end
