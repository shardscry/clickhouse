require "./spec_helper"

private alias Support = KemalAPI::SpecSupport

describe "application dependency injection" do
  it "resolves the HTTP application's overridden repository" do
    Support::CONTAINER.bid_request_repository.should be(Support::REPOSITORY)
    post "/ortb/bids/bulk", Support.json_headers, [Support.request].to_json
    response.status_code.should eq(201)
    Support::REPOSITORY.list(Support.query).total.should eq(1_u64)
  end

  it "shares application and configuration services within one container" do
    Support::CONTAINER.app.should be(Support::CONTAINER.app)
    Support::CONTAINER.config.should be(Support::CONFIG)
  end

  it "isolates repository bindings between containers" do
    first = KemalAPI::TestContainer.new
    second = KemalAPI::TestContainer.new
    first_repository = KemalAPI::MemoryBidRequestRepository.new
    second_repository = KemalAPI::MemoryBidRequestRepository.new
    first.bid_request_repository_override = first_repository
    second.bid_request_repository_override = second_repository

    request = KemalAPI::Entities::BidRequest.new(
      ingestion_id: UUID.random,
      received_at: Time.unix_ms(1_700_000_000_123),
      id: "auction-one-container",
      impression_count: 1,
      request: Support.request("auction-one-container"),
    )
    first.bid_request_repository.insert([request])
    first.bid_request_repository.list(Support.query).data.should eq([request])
    second.bid_request_repository.list(Support.query).data.should be_empty
    first.app.should_not be(second.app)
  end
end
