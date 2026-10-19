require "clickhouse"

url = ENV["CLICKHOUSE_URL"]? || "clickhouse://default:clickhouse_test@127.0.0.1:19000/default"
client = ClickHouse::Client.from_string(url, compression: :lz4, tls_ca: ENV["CLICKHOUSE_TLS_CA"]?)

begin
  result = client.query(
    "SELECT {id:UInt64} AS id, {name:String} AS name",
    params: {id: 42_u64, name: "Ada's example"},
  )
  result.rows.each { |row| puts "#{row["id"].as_u64}: #{row["name"].as_s}" }

  client.query_each(
    "SELECT number AS id FROM numbers({count:UInt64})",
    params: {count: 10_u64},
    settings: {max_block_size: 3, max_threads: 1},
  ) do |row|
    puts "Streamed id: #{row["id"].as_u64}"
  end
ensure
  client.close
end
