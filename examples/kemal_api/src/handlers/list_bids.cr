require "../injectable"
require "../contracts/bid_request_repository"
require "../structs/bid_query"
require "./base"

private alias BidQuery = KemalAPI::Structs::BidQuery

@[ADI::Register]
class KemalAPI::Handlers::ListBids
  include KemalAPI::Handlers::Base
  include KemalAPI::Injectable

  inject bid_request_repository : KemalAPI::Contracts::BidRequestRepository

  def call(env : HTTP::Server::Context) : String
    respond(env) { @bid_request_repository.list(BidQuery.from_query(env.params.query)).to_json }
  end
end
