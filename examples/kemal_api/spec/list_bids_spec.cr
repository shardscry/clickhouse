require "./spec_helper"

private alias Support = KemalAPI::SpecSupport

describe "OpenRTB bid-request listing" do
  it "provides disjoint pages with timestamp and ingestion-ID tie breaking" do
    Support.seed("oldest", "2026-01-01T00:00:00.000Z", "00000000-0000-4000-8000-000000000001")
    Support.seed("same-time-first", "2026-01-02T00:00:00.000Z", "00000000-0000-4000-8000-000000000002")
    Support.seed("same-time-second", "2026-01-02T00:00:00.000Z", "00000000-0000-4000-8000-000000000003")
    get "/ortb/bids?page=1&per_page=2"
    response.status_code.should eq(200)
    first = JSON.parse(response.body)
    first["data"].as_a.map(&.["id"].as_s).should eq(["same-time-second", "same-time-first"])
    first["total"].as_i.should eq(3)
    first["total_pages"].as_i.should eq(2)
    first["page"].as_i.should eq(1)
    first["per_page"].as_i.should eq(2)

    get "/ortb/bids?page=2&per_page=2"
    last = JSON.parse(response.body)
    last["data"].as_a.map(&.["id"].as_s).should eq(["oldest"])
    last["total"].as_i.should eq(3)
    get "/ortb/bids?page=3&per_page=2"
    JSON.parse(response.body)["data"].as_a.should be_empty
    JSON.parse(response.body)["total"].as_i.should eq(3)
  end

  it "applies UTC date boundaries inclusively at midnight and exclusively the next day" do
    Support.seed("before", "2026-01-01T23:59:59.999Z")
    Support.seed("first", "2026-01-02T00:00:00.000Z")
    Support.seed("middle", "2026-01-02T12:34:56.123Z")
    Support.seed("last", "2026-01-02T23:59:59.999Z")
    Support.seed("after", "2026-01-03T00:00:00.000Z")

    get "/ortb/bids?date=2026-01-02"
    response.status_code.should eq(200)
    result = JSON.parse(response.body)
    result["data"].as_a.map(&.["id"].as_s).should eq(["last", "middle", "first"])
    result["total"].as_i.should eq(3)
  end

  it "normalizes explicit timezone offsets and filters before pagination and counting" do
    Support.seed("before", "2026-01-01T23:59:59.999Z")
    Support.seed("first", "2026-01-02T00:00:00.000Z")
    Support.seed("last", "2026-01-02T23:59:59.999Z")
    Support.seed("after", "2026-01-03T00:00:00.000Z")
    get Support.get_path(from: "2026-01-02T02:00:00+02:00", to: "2026-01-03T02:00:00+02:00", page: 2, per_page: 1)
    response.status_code.should eq(200)
    result = JSON.parse(response.body)
    result["data"].as_a.map(&.["id"].as_s).should eq(["first"])
    result["total"].as_i.should eq(2)
    result["total_pages"].as_i.should eq(2)
  end

  it "supports independent open-ended from and to filters" do
    Support.seed("before", "2026-01-01T23:59:59.999Z")
    Support.seed("boundary", "2026-01-02T00:00:00.000Z")
    get Support.get_path(from: "2026-01-02T00:00:00Z")
    response.status_code.should eq(200)
    JSON.parse(response.body)["data"].as_a.map(&.["id"].as_s).should eq(["boundary"])
    get Support.get_path(to: "2026-01-02T00:00:00Z")
    JSON.parse(response.body)["data"].as_a.map(&.["id"].as_s).should eq(["before"])
  end

  it "preserves pre-epoch millisecond boundaries" do
    Support.seed("before", "1969-12-31T23:59:59.499Z")
    Support.seed("match", "1969-12-31T23:59:59.500Z")
    Support.seed("after", "1969-12-31T23:59:59.501Z")
    get Support.get_path(from: "1969-12-31T23:59:59.500Z", to: "1969-12-31T23:59:59.501Z")
    response.status_code.should eq(200)
    JSON.parse(response.body)["data"].as_a.map(&.["id"].as_s).should eq(["match"])
  end

  it "accepts leap day and the last supported UTC date" do
    get "/ortb/bids?date=2024-02-29"
    response.status_code.should eq(200)
    get "/ortb/bids?date=2299-12-31"
    response.status_code.should eq(200)
  end

  %w[page=0 page=-1 page=abc page=2147483648 page= per_page=0 per_page=101 per_page=1.5 per_page=bad per_page=].each do |query|
    it "rejects invalid pagination #{query}" do
      get "/ortb/bids?#{query}"
      response.status_code.should eq(400)
      Support::REPOSITORY.list_calls.should eq(0)
    end
  end

  [
    "date=2026-02-30", "date=2026-2-03", "date=", "date=invalid",
    "date=2026-01-01&from=2026-01-01T00:00:00Z",
    "date=2026-01-01&to=2026-01-02T00:00:00Z",
    "from=2026-01-01T00:00:00", "from=2026-01-01", "from=",
    "from=2026-01-01T00:00:00.1234Z", "from=2026-02-30T00:00:00Z",
    "from=2026-01-01T24:00:00Z", "from=2026-01-01T00:00:00%2B24:00",
    "from=2026-01-01T00:00:00%2B01:60",
    "from=2026-01-02T00:00:00Z&to=2026-01-01T00:00:00Z",
    "from=2026-01-01T00:00:00Z&to=2026-01-01T00:00:00Z",
  ].each do |query|
    it "rejects invalid or ambiguous date filters #{query}" do
      get "/ortb/bids?#{query}"
      response.status_code.should eq(400)
      Support::REPOSITORY.list_calls.should eq(0)
    end
  end

  it "handles large offsets without Int32 multiplication overflow" do
    get "/ortb/bids?page=2147483647&per_page=100"
    response.status_code.should eq(200)
    JSON.parse(response.body)["data"].as_a.should be_empty
  end
end
