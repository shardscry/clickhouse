require "json"
require "uuid"
require "clickhouse"

module KemalAPI::NativeInsertBenchmark
  record BidRecord, ingestion_id : UUID, request_id : String,
    received_at : ClickHouse::Timestamp, impression_count : UInt16, payload : String

  # Resetting the seed gives each insertion mode the same randomized records.
  class RecordFactory
    BASE_MILLISECONDS = Time.utc(2026, 1, 1).to_unix_ms
    private CURRENCIES        = ["USD", "EUR", "GBP"]
    private FORMATS           = [{w: 300, h: 250}, {w: 728, h: 90}, {w: 320, h: 50}, {w: 970, h: 250}]
    private GEOGRAPHIES       = [
      {"USA", "NY", "New York", 40.7128, -74.0060},
      {"GBR", "LND", "London", 51.5072, -0.1276},
      {"FRA", "IDF", "Paris", 48.8566, 2.3522},
    ]

    @random : Random::PCG32
    @sequence = 0_i64

    def initialize(seed : UInt64)
      @random = Random.new(seed)
    end

    def batch(size : Int32) : Array(BidRecord)
      Array(BidRecord).new(size) { next_record }
    end

    private def next_record : BidRecord
      sequence = @sequence
      @sequence += 1
      ingestion_id = UUID.random(@random)
      request_id = "auction-#{sequence}-#{@random.rand(UInt64).to_s(16)}"
      currency = CURRENCIES.sample(@random)
      impressions = @random.rand(1..3)
      payload = {
        id: request_id, at: 2, tmax: @random.rand(80..250), cur: [currency],
        bcat: ["IAB#{@random.rand(1..26)}"],
        imp: Array.new(impressions) { |index| impression(index, currency) },
        site: site, device: device, user: user,
        regs: {coppa: 0},
        ext: {
          vendor: {
            preserved: true, experiment: "arm-#{@random.rand(1..8)}",
            auction_group: @random.rand(1..1_000_000),
            placement_labels: ["section-#{@random.rand(1..100)}", "segment-#{@random.rand(1..1000)}"],
          },
        },
      }.to_json
      BidRecord.new(ingestion_id, request_id, ClickHouse::Timestamp.new(BASE_MILLISECONDS + sequence, 3, "UTC"), impressions.to_u16, payload)
    end

    private def impression(index : Int32, currency : String)
      {
        id: "imp-#{index}-#{@random.rand(1..1_000_000)}",
        bidfloor: @random.rand(1..500) / 100.0, bidfloorcur: currency, secure: 1,
        banner: {format: [FORMATS.sample(@random)], pos: @random.rand(0..7), api: [3, 5]},
        ext: {placement: "slot-#{@random.rand(1..100)}", viewability: @random.rand(40..100)},
      }
    end

    private def site
      publisher = @random.rand(1..1000)
      article = @random.rand(1..1_000_000)
      {
        id: "site-#{@random.rand(1..1000)}", domain: "publisher-#{publisher}.example",
        page: "https://publisher-#{publisher}.example/articles/#{article}", cat: ["IAB#{@random.rand(1..26)}"],
        publisher: {id: "publisher-#{publisher}", name: "Synthetic Publisher #{publisher}"},
        content: {id: "article-#{article}", title: "Synthetic article #{article}", language: "en"},
      }
    end

    private def device
      geography = GEOGRAPHIES.sample(@random)
      {
        ua: "Mozilla/5.0 (Linux; Android #{@random.rand(11..15)}) AppleWebKit/537.36 Chrome/#{@random.rand(120..130)}.0 Mobile Safari/537.36",
        ip: "192.0.2.#{@random.rand(1..254)}", devicetype: 4,
        make: "Synthetic", model: "Phone #{@random.rand(1..20)}", os: "Android", osv: @random.rand(11..15).to_s,
        language: ["en", "fr", "de"].sample(@random), w: 1080, h: 1920, pxratio: 3,
        geo: {
          country: geography[0], region: geography[1], city: geography[2], type: 2,
          lat: geography[3] + @random.rand(-100..100) / 10_000.0,
          lon: geography[4] + @random.rand(-100..100) / 10_000.0,
        },
      }
    end

    private def user
      {
        id: "synthetic-user-#{@random.rand(UInt64).to_s(16)}",
        yob: @random.rand(1950..2005), gender: ["M", "F", "O"].sample(@random),
        ext: {audience: ["segment-#{@random.rand(1..1000)}", "segment-#{@random.rand(1..1000)}"]},
      }
    end
  end
end
