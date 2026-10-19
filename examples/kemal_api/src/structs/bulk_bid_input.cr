require "json"
require "set"
require "../errors/request_error"

private alias RequestError = KemalAPI::Errors::RequestError

struct KemalAPI::Structs::BulkBidInput
  MAX_REQUESTS      = 10_000
  MAX_IMPRESSIONS   =   1000
  MAX_REQUEST_BYTES = 64 * 1024

  getter requests : Array(JSON::Any)

  def self.parse(body : String) : self
    parser = JSON::Parser.new(body)
    parser.max_nesting = 64
    new(parser.parse)
  rescue JSON::ParseException
    raise RequestError.new(400, "body must contain valid JSON")
  end

  def initialize(document : JSON::Any)
    @requests = document.as_a? || raise RequestError.new(422, "body must be an array of BidRequest objects")
    raise RequestError.new(422, "body must contain at least one BidRequest") if @requests.empty?
    raise RequestError.new(413, "body exceeds #{MAX_REQUESTS} BidRequests") if @requests.size > MAX_REQUESTS
    @requests.each_with_index { |request, index| validate_request(request, index) }
  end

  private def validate_request(request : JSON::Any, index : Int32) : Nil
    object = request.as_h? || raise RequestError.new(422, "request #{index} must be an object")
    if request.to_json.bytesize > MAX_REQUEST_BYTES
      raise RequestError.new(413, "request #{index} exceeds #{MAX_REQUEST_BYTES} serialized JSON bytes")
    end
    validate_id(object["id"]?, "request #{index}.id")
    impressions = object["imp"]?.try(&.as_a?)
    if impressions.nil? || impressions.empty?
      raise RequestError.new(422, "request #{index}.imp must be a nonempty array")
    end
    if impressions.size > MAX_IMPRESSIONS
      raise RequestError.new(413, "request #{index} exceeds #{MAX_IMPRESSIONS} impressions")
    end
    ids = Set(String).new
    impressions.each_with_index do |impression, position|
      fields = impression.as_h? || raise RequestError.new(422, "request #{index}.imp[#{position}] must be an object")
      id = validate_id(fields["id"]?, "request #{index}.imp[#{position}].id")
      raise RequestError.new(422, "request #{index} contains duplicate impression ids") unless ids.add?(id)
    end
  end

  private def validate_id(value : JSON::Any?, field : String) : String
    id = value.try(&.as_s?)
    raise RequestError.new(422, "#{field} must be a nonblank string") if id.nil? || id.strip.empty?
    id
  end
end
