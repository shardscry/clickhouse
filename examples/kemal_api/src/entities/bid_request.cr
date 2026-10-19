require "json"
require "uuid"
require "uuid/json"

struct KemalAPI::Entities::BidRequest
  include JSON::Serializable

  getter ingestion_id : UUID
  @[JSON::Field(converter: Time::Format.new("%FT%T.%L%:z"))]
  getter received_at : Time
  getter id : String
  getter impression_count : Int32
  getter request : JSON::Any

  def initialize(*, @ingestion_id : UUID, @received_at : Time, @id : String,
                 @impression_count : Int32, @request : JSON::Any)
  end
end
