require "clickhouse"

url = ENV["CLICKHOUSE_URL"]? || "clickhouse://default:clickhouse_test@127.0.0.1:19000/default"
client = ClickHouse::Client.from_string(url, compression: :lz4, tls_ca: ENV["CLICKHOUSE_TLS_CA"]?)

begin
  result = client.query(<<-SQL)
    SELECT
      toUInt64(18446744073709551615) AS maximum,
      unhex('410042ff') AS binary,
      CAST(NULL AS Nullable(String)) AS missing,
      CAST('123.45' AS Decimal(18, 2)) AS amount,
      toDateTime64('2026-01-02 03:04:05.123', 3, 'UTC') AS created_at,
      toUUID('00112233-4455-6677-8899-aabbccddeeff') AS id,
      ['read', 'write'] AS permissions,
      tuple(toUInt64(7), 'Ada') AS owner,
      map('role', 'reader', 'role', 'writer') AS attributes
    SQL
  row = result.rows.first

  puts "UInt64 maximum: #{row["maximum"].as_u64}"
  puts "Binary bytes: #{row["binary"].as_bytes.hexstring}"
  puts "Missing is null: #{row["missing"].null?}"

  amount = row["amount"].as_decimal
  puts "Exact amount: #{amount.unscaled} with scale #{amount.scale}"
  created_at = row["created_at"].as_timestamp
  puts "Timestamp: #{created_at.ticks} ticks, precision #{created_at.precision}, zone #{created_at.timezone}"
  puts "UUID: #{row["id"].as_uuid}"
  puts "Permissions: #{row["permissions"].as_array.map(&.as_s).join(", ")}"
  puts "Owner: #{row["owner"].as_tuple.values[1].as_s}"
  row["attributes"].as_map.entries.each do |key, value|
    puts "Map entry: #{key.as_s}=#{value.as_s}"
  end
ensure
  client.close
end
