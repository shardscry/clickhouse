require "./repositories/bid_request_repository"
require "./contracts/bid_request_repository"

ADI.bind bid_request_repository : KemalAPI::Contracts::BidRequestRepository, "@bid_request_repository"
