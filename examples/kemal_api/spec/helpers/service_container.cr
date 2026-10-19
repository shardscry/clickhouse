require "../../src/app"

class KemalAPI::TestContainer < ADI::ServiceContainer
  property bid_request_repository_override : KemalAPI::Contracts::BidRequestRepository?

  def bid_request_repository : KemalAPI::Contracts::BidRequestRepository
    @bid_request_repository_override || super
  end
end
