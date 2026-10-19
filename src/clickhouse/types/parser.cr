require "./type"

class ClickHouse::Types::Parser
  MAX_DEPTH     =   32
  MAX_ARGUMENTS = 1024

  def self.parse(expression : String) : Type
    new(expression).parse
  end

  def initialize(@expression : String)
    raise CodecError.new("type expression is too long") if @expression.bytesize > 65_536
    @position = 0
  end

  def parse : Type
    result = parse_type(0)
    whitespace
    fail_type("unexpected trailing input") unless finished?
    result
  end

  private def parse_type(depth : Int32) : Type
    fail_type("type nesting exceeds #{MAX_DEPTH}") if depth > MAX_DEPTH
    whitespace
    name = identifier
    whitespace
    return Type.new(name) unless peek == '('
    @position += 1
    children = [] of Type
    parameters = [] of String
    names = [] of String?
    enums = {} of String => Int16
    whitespace
    unless peek == ')'
      loop do
        fail_type("too many type arguments") if children.size + parameters.size + enums.size >= MAX_ARGUMENTS
        parse_argument(name, depth, children, parameters, names, enums)
        whitespace
        break unless peek == ','
        @position += 1
        whitespace
      end
    end
    expect(')')
    Type.new(name, children, parameters, names, enums)
  rescue ex : ArgumentError | OverflowError
    fail_type("invalid parameter: #{ex.message}")
  end

  private def parse_argument(name, depth, children, parameters, names, enums) : Nil
    case name
    when "FixedString", "Decimal", "Decimal32", "Decimal64", "Decimal128", "DateTime", "DateTime64"
      whitespace
      parameters << (peek == '\'' ? quoted('\'') : number)
    when "Enum8", "Enum16"
      parse_enum(enums)
    when "Tuple", "Nested"
      parse_field_name(names)
      children << parse_type(depth + 1)
    else
      children << parse_type(depth + 1)
    end
  end

  private def parse_enum(enums : Hash(String, Int16)) : Nil
    whitespace
    label = quoted('\'')
    whitespace
    expect('=')
    whitespace
    code = number.to_i16
    fail_type("duplicate enum label or code") if enums.has_key?(label) || enums.has_value?(code)
    enums[label] = code
  end

  private def parse_field_name(names : Array(String?)) : Nil
    whitespace
    saved = @position
    delimiter = peek
    candidate = if delimiter && (delimiter == '`' || delimiter == '"')
                  quoted(delimiter)
                else
                  identifier
                end
    after_name = @position
    whitespace
    if @position > after_name && peek.try { |char| char.ascii_letter? || char == '_' }
      names << candidate
    else
      names << nil
      @position = saved
    end
  end

  private def identifier : String
    start = @position
    while char = peek
      break unless char.ascii_alphanumeric? || char == '_'
      @position += 1
    end
    fail_type("expected type or field name") if start == @position
    @expression.byte_slice(start, @position - start)
  end

  private def number : String
    start = @position
    @position += 1 if peek == '-'
    digits = @position
    while char = peek
      break unless char.ascii_number?
      @position += 1
    end
    fail_type("expected numeric parameter") if digits == @position
    @expression.byte_slice(start, @position - start)
  end

  private def quoted(delimiter : Char) : String
    expect(delimiter)
    String.build do |output|
      closed = false
      while char = peek
        @position += 1
        if char == delimiter
          if peek == delimiter
            output << delimiter
            @position += 1
          else
            closed = true
            break
          end
        elsif char == '\\'
          escaped = peek || fail_type("unterminated escape")
          @position += 1
          output << case escaped
          when 'n' then '\n'
          when 'r' then '\r'
          when 't' then '\t'
          when '0' then '\0'
          else          escaped
          end
        else
          output.write_byte(char.ord.to_u8)
        end
      end
      fail_type("unterminated quoted parameter") unless closed
    end
  end

  private def whitespace : Nil
    while char = peek
      break unless char.ascii_whitespace?
      @position += 1
    end
  end

  private def peek : Char?
    @expression.byte_at?(@position).try(&.unsafe_chr)
  end

  private def finished? : Bool
    @position >= @expression.bytesize
  end

  private def expect(char : Char) : Nil
    fail_type("expected #{char}") unless peek == char
    @position += 1
  end

  private def fail_type(message : String) : NoReturn
    raise CodecError.new("invalid type at byte #{@position}: #{message}")
  end
end
