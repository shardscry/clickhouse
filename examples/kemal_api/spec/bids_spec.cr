require "./spec_helper"

private alias Support = KemalAPI::SpecSupport

describe "OpenRTB bid-request ingestion API" do
  it "returns an empty first page and pagination metadata" do
    get "/ortb/bids"
    response.status_code.should eq(200)
    response.content_type.should eq("application/json")
    JSON.parse(response.body).should eq(JSON.parse(%({"data":[],"page":1,"per_page":20,"total":0,"total_pages":0})))
  end

  it "stores all JSON fields with generated ingestion IDs and one millisecond timestamp per bulk" do
    requests = [Support.request("auction-a", 2), Support.request("auction-b")]
    post "/ortb/bids/bulk", Support.json_headers, requests.to_json
    response.status_code.should eq(201)
    response.headers["Location"].should eq("/ortb/bids")
    result = JSON.parse(response.body)
    result["inserted"].as_i.should eq(2)
    ids = result["ingestion_ids"].as_a.map(&.as_s)
    ids.uniq.size.should eq(2)
    ids.each { |id| UUID.parse?(id, version: UUID::Version::V4).should_not be_nil }
    received_at = Time.parse_rfc3339(result["received_at"].as_s)
    received_at.nanosecond.remainder(1_000_000).should eq(0)

    get "/ortb/bids"
    stored = JSON.parse(response.body)["data"].as_a
    stored.map(&.["ingestion_id"].as_s).sort!.should eq(ids.sort)
    stored.each do |row|
      row["request"].should eq(requests.find { |request| request["id"].as_s == row["id"].as_s })
      Time.parse_rfc3339(row["received_at"].as_s).should eq(received_at)
      row["impression_count"].as_i.should eq(row["request"]["imp"].as_a.size)
    end
  end

  it "accepts a JSON charset and appends repeated auction IDs rather than replacing data" do
    body = [Support.request("repeated-auction")].to_json
    2.times do
      post "/ortb/bids/bulk", HTTP::Headers{"Content-Type" => "application/json; charset=utf-8"}, body
      response.status_code.should eq(201)
    end
    get "/ortb/bids"
    rows = JSON.parse(response.body)["data"].as_a
    rows.size.should eq(2)
    rows.map(&.["id"].as_s).should eq(["repeated-auction", "repeated-auction"])
    rows.map(&.["ingestion_id"].as_s).uniq!.size.should eq(2)
  end

  it "accepts the maximum bulk request count" do
    requests = Array.new(10_000) { |index| Support.request("auction-#{index}") }
    post "/ortb/bids/bulk", Support.json_headers, requests.to_json
    response.status_code.should eq(201)
    JSON.parse(response.body)["inserted"].as_i.should eq(10_000)
    get "/ortb/bids?per_page=100"
    result = JSON.parse(response.body)
    result["total"].as_i.should eq(10_000)
    result["data"].as_a.size.should eq(100)
    result["total_pages"].as_i.should eq(100)
  end

  ["", "[", "{", %([{"id":"auction"})].each do |body|
    it "rejects malformed JSON #{body.inspect} before calling the repository" do
      post "/ortb/bids/bulk", Support.json_headers, body
      response.status_code.should eq(400)
      Support::REPOSITORY.insert_calls.should eq(0)
    end
  end

  [
    "[]", "{}", "null", "[null]", "[12]", %(["auction"]),
    %([{"imp":[{"id":"1"}]}]),
    %([{"id":12,"imp":[{"id":"1"}]}]),
    %([{"id":" ","imp":[{"id":"1"}]}]),
    %([{"id":"auction"}]),
    %([{"id":"auction","imp":null}]),
    %([{"id":"auction","imp":{}}]),
    %([{"id":"auction","imp":[]}]),
    %([{"id":"auction","imp":[null]}]),
    %([{"id":"auction","imp":[{}]}]),
    %([{"id":"auction","imp":[{"id":" "}]}]),
    %([{"id":"auction","imp":[{"id":1}]}]),
    %([{"id":"auction","imp":[{"id":"same"},{"id":"same"}]}]),
  ].each do |body|
    it "rejects an invalid ingestion envelope #{body}" do
      post "/ortb/bids/bulk", Support.json_headers, body
      response.status_code.should eq(422)
      JSON.parse(response.body)["error"].as_s.should_not be_empty
      Support::REPOSITORY.insert_calls.should eq(0)
    end
  end

  it "validates the whole bulk before inserting any requests" do
    post "/ortb/bids/bulk", Support.json_headers, [Support.request, JSON.parse(%({"id":"invalid","imp":[]}))].to_json
    response.status_code.should eq(422)
    JSON.parse(response.body)["error"].as_s.should contain("request 1.imp")
    Support::REPOSITORY.insert_calls.should eq(0)
  end

  it "rejects missing or unsupported content types" do
    post "/ortb/bids/bulk", body: "[]"
    response.status_code.should eq(415)
    post "/ortb/bids/bulk", HTTP::Headers{"Content-Type" => "text/plain"}, "[]"
    response.status_code.should eq(415)
  end

  it "rejects a body exceeding 16 MiB before parsing JSON" do
    post "/ortb/bids/bulk", Support.json_headers, "x" * (KemalAPI::Handlers::Base::MAX_BODY_BYTES + 1)
    response.status_code.should eq(413)
    Support::REPOSITORY.insert_calls.should eq(0)
  end

  it "rejects more than 10000 requests" do
    count = KemalAPI::Structs::BulkBidInput::MAX_REQUESTS + 1
    post "/ortb/bids/bulk", Support.json_headers, Array.new(count) { |index| {id: index.to_s, imp: [{id: "1"}]} }.to_json
    response.status_code.should eq(413)
    Support::REPOSITORY.insert_calls.should eq(0)
  end

  it "rejects more than 1000 impressions in one request" do
    request = {id: "auction", imp: Array.new(1001) { |index| {id: index.to_s} }}
    post "/ortb/bids/bulk", Support.json_headers, [request].to_json
    response.status_code.should eq(413)
    Support::REPOSITORY.insert_calls.should eq(0)
  end

  it "rejects an individual canonical request exceeding 64 KiB" do
    request = Support.request.as_h.dup
    request["ext"] = JSON::Any.new("x" * (64 * 1024))
    post "/ortb/bids/bulk", Support.json_headers, [request].to_json
    response.status_code.should eq(413)
    Support::REPOSITORY.insert_calls.should eq(0)
  end

  it "returns an ambiguous insert query ID without retrying" do
    Support::REPOSITORY.insert_failure = ClickHouse::InsertOutcomeUnknown.new("uncertain-query-123")
    post "/ortb/bids/bulk", Support.json_headers, [Support.request].to_json
    response.status_code.should eq(503)
    result = JSON.parse(response.body)
    result["query_id"].as_s.should eq("uncertain-query-123")
    Support::REPOSITORY.insert_calls.should eq(1)
  end
end
