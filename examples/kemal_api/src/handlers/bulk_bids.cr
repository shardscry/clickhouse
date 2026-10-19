require "uuid"
require "../injectable"
require "../contracts/bid_request_repository"
require "../entities/bid_request"
require "../structs/bulk_bid_input"
require "./base"

private alias BidRequest = KemalAPI::Entities::BidRequest
private alias BulkBidInput = KemalAPI::Structs::BulkBidInput

@[ADI::Register]
class KemalAPI::Handlers::BulkBids
  include KemalAPI::Handlers::Base
  include KemalAPI::Injectable

  inject bid_request_repository : KemalAPI::Contracts::BidRequestRepository

  def call(env : HTTP::Server::Context) : String
    respond(env) do
      input = BulkBidInput.parse(read_json_body(env))
      received_at = Time.unix_ms(Time.utc.to_unix_ms)
      requests = input.requests.map do |request|
        BidRequest.new(
          ingestion_id: UUID.random,
          received_at: received_at,
          id: request["id"].as_s,
          impression_count: request["imp"].as_a.size,
          request: request,
        )
      end
      @bid_request_repository.insert(requests)
      env.response.status_code = 201
      env.response.headers["Location"] = "/ortb/bids"
      {
        inserted:      requests.size,
        ingestion_ids: requests.map(&.ingestion_id.to_s),
        received_at:   received_at.to_rfc3339(fraction_digits: 3),
      }.to_json
    end
  end
end
