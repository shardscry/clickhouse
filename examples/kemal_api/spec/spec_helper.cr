ENV["KEMAL_ENV"] = "test"

require "spec"
require "spec-kemal"
require "uuid"
require "../src/app"
require "../src/schema"
require "./helpers/service_container"

private alias BidRequest = KemalAPI::Entities::BidRequest
private alias BidQuery = KemalAPI::Structs::BidQuery
private alias BidPage = KemalAPI::Structs::PageResult(KemalAPI::Entities::BidRequest)
private alias Repository = KemalAPI::Contracts::BidRequestRepository

class KemalAPI::MemoryBidRequestRepository < KemalAPI::Contracts::BidRequestRepository
  @requests = [] of BidRequest

  def insert(requests : Array(BidRequest)) : Nil
    @requests.concat(requests)
  end

  def list(query : BidQuery) : BidPage
    from = query.from
    to = query.to
    matches = @requests.select do |request|
      (!from || request.received_at >= from) && (!to || request.received_at < to)
    end
    matches.sort! do |left, right|
      comparison = right.received_at <=> left.received_at
      comparison == 0 ? uuid_key(right.ingestion_id) <=> uuid_key(left.ingestion_id) : comparison
    end
    page = query.offset >= matches.size ? [] of BidRequest : matches[query.offset.to_i, query.per_page]
    BidPage.new(page, query.page, query.per_page, matches.size.to_u64)
  end

  def clear : Nil
    @requests.clear
  end

  private def uuid_key(value : UUID) : Tuple(String, String)
    # ClickHouse's UUID comparison is second-half-major, not textual ordering.
    hex = value.to_s.delete('-')
    {hex[16, 16], hex[0, 16]}
  end
end

class KemalAPI::ControlledBidRequestRepository < KemalAPI::Contracts::BidRequestRepository
  getter inner : Repository
  getter insert_calls : Int32 = 0
  getter list_calls : Int32 = 0
  property insert_failure : ClickHouse::InsertOutcomeUnknown?

  def initialize(@inner : Repository)
  end

  def insert(requests : Array(BidRequest)) : Nil
    @insert_calls += 1
    if failure = @insert_failure
      raise failure
    end
    @inner.insert(requests)
  end

  def list(query : BidQuery) : BidPage
    @list_calls += 1
    @inner.list(query)
  end

  def reset : Nil
    @insert_failure = nil
    @insert_calls = 0
    @list_calls = 0
  end
end

module KemalAPI::SpecSupport
  INTEGRATION = ENV["CLICKHOUSE_INTEGRATION"]? == "1"
  ENV["CLICKHOUSE_TABLE"] = "ortb_spec_#{UUID.random.to_s.delete('-')}" if INTEGRATION

  CONTAINER  = TestContainer.new
  CONFIG     = CONTAINER.config
  MEMORY     = MemoryBidRequestRepository.new
  REPOSITORY = ControlledBidRequestRepository.new(INTEGRATION ? Repositories::BidRequestRepository.new(CONFIG) : MEMORY)

  def self.json_headers : HTTP::Headers
    HTTP::Headers{"Content-Type" => "application/json"}
  end

  def self.request(id : String = "auction-1", impression_count : Int32 = 1) : JSON::Any
    JSON.parse({
      id:   id,
      imp:  Array.new(impression_count) { |index| {id: "imp-#{index}", banner: {format: [{w: 300, h: 250}]}} },
      site: {page: "https://publisher.example/article"},
      ext:  {vendor: {preserved: true}},
    }.to_json)
  end

  def self.query(**params) : BidQuery
    values = {} of String => String
    params.each { |key, value| values[key.to_s] = value.to_s }
    BidQuery.from_query(URI::Params.parse(URI::Params.encode(values)))
  end

  def self.seed(id : String, received_at : String, ingestion_id : String = UUID.random.to_s) : BidRequest
    entity = BidRequest.new(
      ingestion_id: UUID.new(ingestion_id),
      received_at: Time.parse_rfc3339(received_at),
      id: id,
      impression_count: 1,
      request: request(id),
    )
    REPOSITORY.insert([entity])
    entity
  end

  def self.get_path(**params) : String
    values = {} of String => String
    params.each { |key, value| values[key.to_s] = value.to_s }
    "/ortb/bids?#{URI::Params.encode(values)}"
  end

  def self.sql(statement : String) : Nil
    client = CONFIG.open_client
    begin
      client.exec(statement)
    ensure
      client.close
    end
  end

  def self.cleanup : Nil
    REPOSITORY.reset
    if INTEGRATION
      sql("TRUNCATE TABLE #{CONFIG.quoted_table}")
    else
      MEMORY.clear
    end
  end
end

Kemal.config.env = "test"
Kemal.config.logging = false
Kemal.config.serve_static = false
if KemalAPI::SpecSupport::INTEGRATION
  KemalAPI::Schema.create(KemalAPI::SpecSupport::CONFIG)
end
KemalAPI::SpecSupport::CONTAINER.bid_request_repository_override = KemalAPI::SpecSupport::REPOSITORY
KemalAPI::SpecSupport::CONTAINER.app.mount
Kemal.config.setup

Spec.after_each { KemalAPI::SpecSupport.cleanup }
Spec.after_suite do
  if KemalAPI::SpecSupport::INTEGRATION
    KemalAPI::SpecSupport.sql("DROP TABLE IF EXISTS #{KemalAPI::SpecSupport::CONFIG.quoted_table}")
  end
end
