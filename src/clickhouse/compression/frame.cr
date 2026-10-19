require "./city_hash"
require "./lz4"

private alias CompressionError = ClickHouse::Compression::Error

module ClickHouse::Compression
  extend self

  DEFAULT_MAX_FRAME_SIZE = 64 * 1024 * 1024
  private HEADER_SIZE            =  9
  private CHECKSUM_SIZE          = 16

  # Writes one native frame. Packet IDs and table names are not compressed.
  def write_frame(io : IO, bytes : Bytes, method : Symbol = :lz4, max_frame_size : Int32 = DEFAULT_MAX_FRAME_SIZE) : Nil
    raise CompressionError.new("compression frame exceeds size limit") if bytes.size > max_frame_size
    payload, marker = case method
                      when :lz4
                        {LZ4.compress(bytes), 0x82_u8}
                      when :none
                        {bytes, 0x02_u8}
                      else
                        raise CompressionError.new("unsupported compression method: #{method}")
                      end
    if payload.size.to_u64 + HEADER_SIZE > UInt32::MAX
      raise CompressionError.new("compressed frame size exceeds UInt32")
    end
    frame = Bytes.new(HEADER_SIZE + payload.size)
    frame[0] = marker
    IO::ByteFormat::LittleEndian.encode((payload.size + HEADER_SIZE).to_u32, frame[1, 4])
    IO::ByteFormat::LittleEndian.encode(bytes.size.to_u32, frame[5, 4])
    frame[HEADER_SIZE, payload.size].copy_from(payload)
    low, high = CityHash.hash128(frame)
    io.write_bytes(low, IO::ByteFormat::LittleEndian)
    io.write_bytes(high, IO::ByteFormat::LittleEndian)
    io.write(frame)
  end

  # Reads Native blocks spanning frames, without reading ahead into packet headers.
  class Reader < IO
    @buffer = Bytes.empty
    @position = 0

    def initialize(@io : IO, @max_frame_size : Int32 = DEFAULT_MAX_FRAME_SIZE)
      raise ArgumentError.new("max_frame_size must be positive") unless @max_frame_size > 0
    end

    def buffered_remaining : Int32
      @buffer.size - @position
    end

    def read(slice : Bytes) : Int32
      return 0 if slice.empty?
      empty_frames = 0
      while buffered_remaining == 0
        return 0 unless read_frame
        if @buffer.empty?
          empty_frames += 1
          raise CompressionError.new("too many consecutive empty compression frames") if empty_frames > 16
        end
      end
      count = Math.min(slice.size, buffered_remaining)
      slice[0, count].copy_from(@buffer[@position, count])
      @position += count
      count
    end

    def write(slice : Bytes) : NoReturn
      raise IO::Error.new("compression reader is read-only")
    end

    private def read_frame : Bool
      first = @io.read_byte
      return false unless first
      checksum = Bytes.new(CHECKSUM_SIZE)
      checksum[0] = first
      @io.read_fully(checksum[1, CHECKSUM_SIZE - 1])
      header = Bytes.new(HEADER_SIZE)
      @io.read_fully(header)
      compressed_size = IO::ByteFormat::LittleEndian.decode(UInt32, header[1, 4])
      uncompressed_size = IO::ByteFormat::LittleEndian.decode(UInt32, header[5, 4])
      maximum_compressed = @max_frame_size.to_i64 + @max_frame_size // 255 + 16 + HEADER_SIZE
      if compressed_size < HEADER_SIZE || compressed_size > maximum_compressed || uncompressed_size > @max_frame_size
        raise CompressionError.new("invalid compression frame sizes")
      end
      payload_size = compressed_size.to_i - HEADER_SIZE
      frame = Bytes.new(compressed_size.to_i)
      frame[0, HEADER_SIZE].copy_from(header)
      @io.read_fully(frame[HEADER_SIZE, payload_size])
      low, high = CityHash.hash128(frame)
      unless low == IO::ByteFormat::LittleEndian.decode(UInt64, checksum[0, 8]) &&
             high == IO::ByteFormat::LittleEndian.decode(UInt64, checksum[8, 8])
        raise CompressionError.new("compression frame checksum mismatch")
      end
      payload = frame[HEADER_SIZE, payload_size]
      @buffer = case header[0]
                when 0x82
                  LZ4.decompress(payload, uncompressed_size.to_i)
                when 0x02
                  raise CompressionError.new("uncompressed frame size mismatch") unless payload_size == uncompressed_size
                  payload
                else
                  raise CompressionError.new("unsupported compression method: 0x#{header[0].to_s(16)}")
                end
      @position = 0
      true
    rescue IO::EOFError
      raise CompressionError.new("truncated compression frame")
    end
  end
end
