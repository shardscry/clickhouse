require "uri/params"
require "../errors/request_error"

private alias RequestError = KemalAPI::Errors::RequestError

struct KemalAPI::Structs::BidQuery
  getter page : Int32
  getter per_page : Int32
  getter from : Time?
  getter to : Time?

  def initialize(@page : Int32 = 1, @per_page : Int32 = 20, @from : Time? = nil, @to : Time? = nil)
    raise RequestError.new(400, "page must be a positive integer") unless @page > 0
    raise RequestError.new(400, "per_page must be between 1 and 100") unless (1..100).includes?(@per_page)
    if first = @from
      raise RequestError.new(400, "from is outside the supported date range") unless (1900..2299).includes?(first.year)
    end
    if last = @to
      unless Time.utc(1900, 1, 1) <= last <= Time.utc(2300, 1, 1)
        raise RequestError.new(400, "to is outside the supported date range")
      end
    end
    if (first = @from) && (last = @to) && first >= last
      raise RequestError.new(400, "from must be earlier than to")
    end
  end

  def self.from_query(parameters : URI::Params) : self
    page = integer(parameters["page"]?, "page", 1)
    per_page = integer(parameters["per_page"]?, "per_page", 20)
    if date = parameters["date"]?
      if parameters.has_key?("from") || parameters.has_key?("to")
        raise RequestError.new(400, "date cannot be combined with from or to")
      end
      first = day(date)
      new(page, per_page, first, first + 1.day)
    else
      new(page, per_page, timestamp(parameters["from"]?, "from"), timestamp(parameters["to"]?, "to"))
    end
  end

  def offset : UInt64
    (@page.to_u64 - 1_u64) * @per_page.to_u64
  end

  private def self.integer(value : String?, field : String, default : Int32) : Int32
    return default unless value
    result = /\A[0-9]+\z/.matches?(value) ? value.to_i? : nil
    result || raise RequestError.new(400, "#{field} must be an integer")
  end

  private def self.day(value : String) : Time
    raise RequestError.new(400, "date must use YYYY-MM-DD") unless /\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/.matches?(value)
    parsed = Time.parse(value, "%F", Time::Location::UTC)
    unless (1900..2299).includes?(parsed.year) && parsed.to_s("%F") == value
      raise RequestError.new(400, "date must be a valid day between 1900 and 2299")
    end
    parsed
  rescue Time::Format::Error | ArgumentError
    raise RequestError.new(400, "date must be a valid day between 1900 and 2299")
  end

  private def self.timestamp(value : String?, field : String) : Time?
    return unless value
    pattern = /\A[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt](?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]{1,3})?(?:[Zz]|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])\z/
    unless pattern.matches?(value)
      raise RequestError.new(400, "#{field} must be RFC3339 with an explicit timezone and at most millisecond precision")
    end
    parsed = Time.parse_rfc3339(value).to_utc
    raise RequestError.new(400, "#{field} must be between 1900 and 2299") unless (1900..2299).includes?(parsed.year)
    parsed
  rescue Time::Format::Error | ArgumentError
    raise RequestError.new(400, "#{field} must be a valid RFC3339 timestamp")
  end
end
