require "uuid"
require "./connection"
require "./protocol/deadline"
require "./protocol/parameters"
require "./result"
require "./batch"

class ClickHouse::Client
  getter config : Config
  @connection : Connection
  @busy = Atomic(Bool).new(false)

  def initialize(@config : Config = Config.new)
    @connection = Connection.new(@config, Transport.open(@config))
  end

  def initialize(@config : Config, io : IO)
    @connection = Connection.new(@config, io)
  end

  def self.from_string(uri : String, **options) : self
    new(Config.from_string(uri, **options))
  end

  def server_info : ServerInfo
    @connection.server_info
  end

  def revision : Int32
    @connection.revision
  end

  def closed? : Bool
    @connection.closed?
  end

  def close : Nil
    @connection.close
  end

  def cancel : Nil
    return if closed?
    @connection.send_cancel
  ensure
    close
  end

  def ping : Bool
    operation { @connection.ping }
  end

  def query_blocks(
    sql : String, params = {} of String => String, settings = {} of String => String,
    query_id : String? = nil, on_progress : Proc(Progress, Nil)? = nil, & : Block ->
  ) : Summary
    parameters = Protocol::Parameters.encode(params)
    query_settings = encode_settings(settings)
    id = query_id || UUID.random.to_s
    operation do
      summary = Summary.new(id)
      @connection.send_query(sql, id, parameters, query_settings)
      read_response(summary, on_progress) { |block| yield block }
      summary
    end
  end

  def query_each(
    sql : String, params = {} of String => String, settings = {} of String => String,
    query_id : String? = nil, on_progress : Proc(Progress, Nil)? = nil, & : Row ->
  ) : Summary
    query_blocks(sql, params: params, settings: settings, query_id: query_id, on_progress: on_progress) do |block|
      block.row_count.times { |index| yield Row.new(block, index) }
    end
  end

  def query(
    sql : String, params = {} of String => String, settings = {} of String => String,
    query_id : String? = nil, on_progress : Proc(Progress, Nil)? = nil,
  ) : Result
    rows = [] of Row
    columns = [] of Column
    bytes = 0_u64
    summary = query_blocks(sql, params: params, settings: settings, query_id: query_id, on_progress: on_progress) do |block|
      next if block.empty?
      columns = block.columns if columns.empty?
      bytes += @connection.last_block_bytes
      if rows.size.to_i64 + block.row_count > @config.max_result_rows || bytes > @config.max_result_bytes
        raise Error.new("materialized result exceeds configured limits; use query_each or query_blocks")
      end
      block.row_count.times { |index| rows << Row.new(block, index) }
    end
    Result.new(rows, columns, summary)
  end

  def exec(
    sql : String, params = {} of String => String, settings = {} of String => String,
    query_id : String? = nil,
  ) : Summary
    query_blocks(sql, params: params, settings: settings, query_id: query_id) { |_block| }
  end

  def insert(
    table : String, columns : Array(String), settings = {} of String => String,
    query_id : String? = nil, & : Batch ->
  ) : Summary
    raise ArgumentError.new("insert columns must be nonempty and unique") if columns.empty? || columns.uniq.size != columns.size
    sql = "INSERT INTO #{quote_table(table)} (#{columns.map { |column| quote_identifier(column) }.join(", ")}) VALUES"
    query_settings = encode_settings(settings)
    id = query_id || UUID.random.to_s
    operation do
      summary = Summary.new(id)
      @connection.send_query(sql, id, {} of String => String, query_settings)
      schema = read_insert_schema(summary)
      unless schema.columns.map(&.name) == columns
        raise ProtocolError.new("server insert schema does not match requested columns")
      end
      batch = Batch.new(@connection, schema, @config)
      upload(batch, summary) { |input| yield input }
    end
  end

  def insert_blocks(
    table : String, columns : Array(String), blocks : Enumerable(Block),
    settings = {} of String => String, query_id : String? = nil,
  ) : Summary
    insert(table, columns: columns, settings: settings, query_id: query_id) do |batch|
      blocks.each { |block| batch.append_block(block) }
    end
  end

  private def upload(batch : Batch, summary : Summary, & : Batch ->) : Summary
    completion = Channel(Exception?).new(1)
    reader_finished = false
    spawn { receive_insert(batch, summary, completion) }
    begin
      yield batch
      batch.finish
      reader_error = completion.receive
      reader_finished = true
      raise reader_error if reader_error
      summary
    rescue ex
      insert_failed(ex, batch, summary.query_id, completion, reader_finished)
    ensure
      batch.invalidate
    end
  end

  private def receive_insert(batch : Batch, summary : Summary, completion : Channel(Exception?)) : Nil
    read_response(summary, insert_batch: batch) { |_block| }
    completion.send(nil)
  rescue ex
    close
    completion.send(ex)
  end

  private def insert_failed(
    error : Exception, batch : Batch, query_id : String,
    completion : Channel(Exception?), reader_finished : Bool,
  ) : NoReturn
    close
    reader_error = reader_finished ? nil : completion.receive
    if reader_error.is_a?(ServerError | ProtocolError) && transport_error?(error)
      raise reader_error
    end
    if batch.sent? && transport_error?(error)
      raise InsertOutcomeUnknown.new(query_id, reader_error || error)
    end
    raise error
  end

  private def read_insert_schema(summary : Summary) : Block
    loop do
      packet = @connection.next_packet
      if packet == 1
        block = @connection.read_block
        return block unless block.empty?
      elsif packet == 5
        raise ProtocolError.new("server ended INSERT before sending its schema")
      else
        @connection.read_metadata(packet, summary)
      end
    end
  end

  private def read_response(
    summary : Summary, on_progress : Proc(Progress, Nil)? = nil,
    insert_batch : Batch? = nil, & : Block ->
  ) : Nil
    loop do
      packet = @connection.next_packet
      case packet
      when 1
        yield @connection.read_block
      when 5
        if insert_batch && !insert_batch.input_finished?
          raise ProtocolError.new("server ended INSERT before input was finished")
        end
        break
      else
        @connection.read_metadata(packet, summary, on_progress)
      end
    end
  end

  private def operation(&)
    raise ClosedError.new("ClickHouse connection is closed") if closed?
    raise BusyError.new("one active operation is allowed per connection") if @busy.swap(true)
    completed = false
    deadline = Protocol::Deadline.new(@connection.io, @config.query_timeout)
    begin
      result = yield
      raise QueryTimeoutError.new("ClickHouse operation exceeded query_timeout") if deadline.expired?
      completed = true
      result
    rescue ex
      if deadline.expired? && !ex.is_a?(InsertOutcomeUnknown)
        raise QueryTimeoutError.new("ClickHouse operation exceeded query_timeout", cause: ex)
      end
      if transport_error?(ex) && !ex.is_a?(ClickHouse::Error)
        raise ConnectionError.new("ClickHouse connection failed", cause: ex)
      end
      raise ex
    ensure
      deadline.stop
      unless completed
        cancel rescue close
      end
      @busy.set(false)
    end
  end

  private def transport_error?(error : Exception) : Bool
    error.is_a?(IO::Error | Socket::Error | OpenSSL::Error | ConnectionError)
  end

  private def encode_settings(settings) : Hash(String, String)
    result = {} of String => String
    result["network_compression_method"] = "lz4" if @config.compression == :lz4
    settings.each do |key, value|
      name = key.to_s
      raise ArgumentError.new("invalid setting name #{name}") unless /\A[a-zA-Z_][a-zA-Z_0-9]*\z/.matches?(name)
      if name.starts_with?("output_format_native_") || name.starts_with?("input_format_native_") ||
         {"network_compression_method", "async_insert", "send_progress_in_http_headers"}.includes?(name)
        raise ArgumentError.new("setting #{name} is not supported by this native driver")
      end
      result[name] = value.is_a?(Bool) ? (value ? "1" : "0") : value.to_s
    end
    result
  end

  private def quote_table(value : String) : String
    parts = value.split('.')
    raise ArgumentError.new("expected table or database.table") unless (1..2).includes?(parts.size)
    parts.map { |part| quote_identifier(part) }.join('.')
  end

  private def quote_identifier(value : String) : String
    raise ArgumentError.new("identifier must be nonempty and contain no NUL") if value.empty? || value.includes?('\0')
    String.build do |io|
      io.write_byte(0x60_u8)
      value.each_byte do |byte|
        io.write_byte(0x5c_u8) if byte == 0x5c || byte == 0x60
        io.write_byte(byte)
      end
      io.write_byte(0x60_u8)
    end
  end
end
