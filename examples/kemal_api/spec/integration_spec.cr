require "./spec_helper"

private alias Support = KemalAPI::SpecSupport

if Support::INTEGRATION
  describe "real ClickHouse persistence" do
    it "stores UUID ingestion keys, millisecond time, and the complete semantic JSON object" do
      input = Support.request("auction-real'\\Ω", 2)
      post "/ortb/bids/bulk", Support.json_headers, [input].to_json
      response.status_code.should eq(201)
      created = JSON.parse(response.body)
      client = Support::CONFIG.open_client
      begin
        result = client.query("SELECT ingestion_id, received_at, request_id AS id, impression_count, payload AS request FROM #{Support::CONFIG.quoted_table}")
        result.rows.size.should eq(1)
        row = result.rows.first
        row["ingestion_id"].as_uuid.to_s.should eq(created["ingestion_ids"][0].as_s)
        row["id"].as_s.should eq(input["id"].as_s)
        row["impression_count"].as_u64.should eq(2_u64)
        JSON.parse(row["request"].as_s).should eq(input)
        row["received_at"].as_timestamp.ticks.should eq(Time.parse_rfc3339(created["received_at"].as_s).to_unix_ms)
      ensure
        client.close
      end
    end
  end
end
