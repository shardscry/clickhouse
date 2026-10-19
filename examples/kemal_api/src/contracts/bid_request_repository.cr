require "../entities/bid_request"
require "../structs/bid_query"
require "../structs/page_result"

abstract class KemalAPI::Contracts::BidRequestRepository
  abstract def insert(requests : Array(KemalAPI::Entities::BidRequest)) : Nil
  abstract def list(query : KemalAPI::Structs::BidQuery) : KemalAPI::Structs::PageResult(KemalAPI::Entities::BidRequest)
end
