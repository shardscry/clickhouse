require "../block"
require "./column_codec"

module ClickHouse::Codecs::BlockCodec
  MAX_COLUMNS  =      1024
  MAX_ROWS     = 1_000_000
  MAX_REVISION =     54460

  def self.read(reader : Protocol::Reader, revision : Int32) : Block
    check_revision(revision)
    read_info(reader) if revision > 0
    column_count = reader.var_uint
    row_count = reader.var_uint
    raise CodecError.new("block column limit exceeded") if column_count > MAX_COLUMNS
    raise CodecError.new("block row limit exceeded") if row_count > MAX_ROWS
    raise CodecError.new("nonempty rows without columns") if column_count == 0 && row_count != 0
    codec = ColumnCodec.new(reader: reader)
    columns = Array(Column).new(column_count.to_i32) do
      name = codec.read_string(65_536)
      expression = codec.read_string(65_536)
      if revision >= 54454 && reader.read(UInt8) != 0
        raise CodecError.new("custom column serialization is unsupported")
      end
      type = Types::Parser.parse(expression)
      values = codec.read(type, row_count.to_i32)
      Column.new(name, expression, values)
    end
    Block.new(columns)
  end

  def self.write(writer : Protocol::Writer, block : Block, revision : Int32) : Nil
    check_revision(revision)
    raise CodecError.new("block column limit exceeded") if block.columns.size > MAX_COLUMNS
    raise CodecError.new("block row limit exceeded") if block.row_count > MAX_ROWS
    unless block.columns.all? { |column| column.values.size == block.row_count }
      raise CodecError.new("block column sizes changed after construction")
    end
    codec = ColumnCodec.new(writer: writer)
    types = block.columns.map do |column|
      type = Types::Parser.parse(column.type)
      codec.validate(type)
      type
    end
    if revision > 0
      writer.var_uint(1)
      writer.write(0_u8)
      writer.var_uint(2)
      writer.write(-1_i32)
      writer.var_uint(0)
    end
    writer.var_uint(block.columns.size)
    writer.var_uint(block.row_count)
    block.columns.each_with_index do |column, index|
      writer.string(column.name)
      writer.string(column.type)
      writer.write(0_u8) if revision >= 54454
      codec.write(types[index], column.values)
    end
  end

  private def self.check_revision(revision : Int32) : Nil
    raise CodecError.new("unsupported Native block revision #{revision}") unless (0..MAX_REVISION).includes?(revision)
  end

  private def self.read_info(reader : Protocol::Reader) : Nil
    16.times do
      case field = reader.var_uint
      when 0 then return
      when 1 then reader.read(UInt8)
      when 2 then reader.read(Int32)
      else        raise CodecError.new("unknown BlockInfo field #{field}")
      end
    end
    raise CodecError.new("unterminated BlockInfo")
  end
end
