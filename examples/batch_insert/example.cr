require "clickhouse"

url = ENV["CLICKHOUSE_URL"]? || "clickhouse://default:clickhouse_test@127.0.0.1:19000/default"
client = ClickHouse::Client.from_string(url, compression: :lz4, batch_size: 2, tls_ca: ENV["CLICKHOUSE_TLS_CA"]?)

begin
  client.exec("CREATE TEMPORARY TABLE example_users (id UInt64, name String) ENGINE=Memory")

  client.insert("example_users", columns: ["id", "name"]) do |batch|
    {"Ada", "Grace", "Barbara", "Margaret", "Katherine"}.each_with_index do |name, index|
      batch.append((index + 1).to_u64, name)
    end
  end

  client.query_each("SELECT id, name FROM example_users ORDER BY id") do |row|
    puts "#{row["id"].as_u64}: #{row["name"].as_s}"
  end
ensure
  # The temporary table belongs to this connection and disappears on close.
  client.close
end
