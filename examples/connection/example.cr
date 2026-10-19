require "clickhouse"

url = ENV["CLICKHOUSE_URL"]? || "clickhouse://default:clickhouse_test@127.0.0.1:19000/default"
client = ClickHouse::Client.from_string(url, tls_ca: ENV["CLICKHOUSE_TLS_CA"]?)

begin
  puts "Connected: #{client.ping}"
  puts "Server version: #{client.query("SELECT version() AS version").rows.first["version"].as_s}"
ensure
  client.close
end
