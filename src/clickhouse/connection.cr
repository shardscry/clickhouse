require "./config"
require "./transport/socket"
require "./protocol/reader"
require "./protocol/writer"
require "./protocol/query_packet"
require "./codecs/block_codec"
require "./compression/frame"
require "./server_info"
require "./summary"

class ClickHouse::Connection
  getter config : Config
  getter io : IO
  getter revision : Int32 = PROTOCOL_REVISION
  getter server_info : ServerInfo
  getter query_id : String = ""
  getter last_block_bytes : UInt64 = 0_u64
  @write_lock = Mutex.new
  @reader : Protocol::Reader
  @writer : Protocol::Writer
  @server_info : ServerInfo
  @closed = false

  def initialize(@config : Config, @io : IO)
    @reader = Protocol::Reader.new(@io)
    @writer = Protocol::Writer.new(@io)
    @server_info = begin
      handshake
    rescue ex
      @io.close rescue nil
      raise ex if ex.is_a?(ClickHouse::Error)
      raise ConnectionError.new("ClickHouse handshake failed", cause: ex)
    end
  end

  def closed? : Bool
    @closed || @io.closed?
  end

  def close : Nil
    @closed = true
    @io.close unless @io.closed?
  rescue IO::Error | Socket::Error | OpenSSL::Error
  end

  def ping : Bool
    write(&.var_uint(4))
    packet = next_packet
    raise server_error if packet == 2
    raise ProtocolError.new("expected Pong, received packet #{packet}") unless packet == 4
    true
  end

  def send_query(body : String, query_id : String, parameters : Hash(String, String), settings : Hash(String, String)) : Nil
    @query_id = query_id
    write do |writer|
      Protocol::QueryPacket.write(writer, @revision, query_id, body, parameters, settings, @config.compression == :lz4)
      write_block(writer, Block.new([] of Column))
    end
  end

  def send_block(block : Block) : Nil
    write { |writer| write_block(writer, block) }
  end

  def send_cancel : Nil
    write(&.var_uint(3))
  end

  def next_packet : UInt64
    @reader.var_uint
  end

  def read_block(compressible : Bool = true) : Block
    table = @reader.string
    raise ProtocolError.new("unexpected external table in response") unless table.empty?
    if compressible && @config.compression == :lz4
      stream = Compression::Reader.new(@io)
      block_reader = Protocol::Reader.new(stream)
      block = Codecs::BlockCodec.read(block_reader, @revision)
      @last_block_bytes = block_reader.bytes_read
      raise ProtocolError.new("unconsumed compressed block bytes") unless stream.buffered_remaining == 0
      block
    else
      before = @reader.bytes_read
      block = Codecs::BlockCodec.read(@reader, @revision)
      @last_block_bytes = @reader.bytes_read - before
      block
    end
  end

  def read_metadata(packet : UInt64, summary : Summary, on_progress : Proc(Progress, Nil)? = nil) : Nil
    case packet
    when 2
      raise server_error
    when 3
      progress = Progress.new(
        @reader.var_uint, @reader.var_uint, @reader.var_uint,
        @reader.var_uint, @reader.var_uint, @revision >= 54460 ? @reader.var_uint : 0_u64,
      )
      summary.add(progress)
      on_progress.try(&.call(progress))
    when 6
      rows = @reader.var_uint
      blocks = @reader.var_uint
      bytes = @reader.var_uint
      @reader.bool
      before_limit = @reader.var_uint
      @reader.bool
      summary.profile(rows, blocks, bytes, before_limit)
    when 7
      summary.totals = read_block
    when 8
      summary.extremes = read_block
    when 10, 14
      read_block(false)
    when 11
      @reader.string
      @reader.string
    else
      raise ProtocolError.new("unsupported server packet #{packet}")
    end
  end

  def server_error : ServerError
    code = @reader.read(Int32)
    name = @reader.string
    message = @reader.string
    stack = @reader.string
    @reader.bool
    ServerError.new(code, name, message, stack, @query_id.empty? ? nil : @query_id)
  end

  private def handshake : ServerInfo
    write do |writer|
      writer.var_uint(0)
      writer.string("shardscry/clickhouse")
      writer.var_uint(VERSION_PARTS[0])
      writer.var_uint(VERSION_PARTS[1])
      writer.var_uint(PROTOCOL_REVISION)
      writer.string(@config.database)
      writer.string(@config.username)
      writer.string(@config.password)
    end
    packet = next_packet
    raise server_error if packet == 2
    raise ProtocolError.new("expected ServerHello, received #{packet}") unless packet == 0
    name = @reader.string
    major = @reader.var_uint.to_i32
    minor = @reader.var_uint.to_i32
    raw_revision = @reader.var_uint.to_i32
    raise ProtocolError.new("server revision #{raw_revision} is below #{MINIMUM_REVISION}") if raw_revision < MINIMUM_REVISION
    timezone = @reader.string
    display_name = @reader.string
    patch = @reader.var_uint.to_i32
    @revision = Math.min(PROTOCOL_REVISION, raw_revision)
    write(&.string("")) if @revision >= 54458
    ServerInfo.new(name, major, minor, raw_revision, timezone, display_name, patch)
  end

  private def write(& : Protocol::Writer ->) : Nil
    @write_lock.synchronize do
      yield @writer
      @io.flush
    end
  end

  private def write_block(writer : Protocol::Writer, block : Block) : Nil
    buffer = IO::Memory.new
    Codecs::BlockCodec.write(Protocol::Writer.new(buffer), block, @revision)
    writer.var_uint(2)
    writer.string("")
    if @config.compression == :lz4
      data = buffer.to_slice
      offset = 0
      while offset < data.size
        size = Math.min(1024 * 1024, data.size - offset)
        Compression.write_frame(@io, data[offset, size])
        offset += size
      end
    else
      writer.bytes(buffer.to_slice)
    end
  end
end
