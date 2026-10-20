# ClickHouse

[![Crystal](https://img.shields.io/badge/Crystal-1.21%2B-000000?logo=crystal&logoColor=white)](https://crystal-lang.org/)
[![ClickHouse Native](https://img.shields.io/badge/ClickHouse-Native%20TCP%20Client-FFCC01?logo=clickhouse&logoColor=black)](https://clickhouse.com/)
[![ClickHouse Query](https://img.shields.io/badge/ClickHouse-Query%20Client-FFCC01?logo=clickhouse&logoColor=black)](https://clickhouse.com/)

A native Crystal driver for ClickHouse over TCP and verified TLS. The shard owns
the native protocol, columnar type codecs, binary batch inserts, and LZ4/CityHash
compression. It does not invoke `clickhouse-client` or wrap a C++ client library.

Requires Crystal **1.21.0 or newer**. TLS uses Crystal's standard OpenSSL support;
compression is implemented in Crystal without an additional native dependency.

## Installation

Add the repository to your application's `shard.yml` and run `shards install`:

```yaml
dependencies:
  clickhouse:
    github: shardscry/clickhouse
    version: ~> 0.0.1
```

The current version is **`0.0.1`**, an early development release. APIs and protocol
coverage may change as the shard develops. The examples install the published
GitHub dependency with `~> 0.0.1` and can run outside this checkout. See
[release notes](RELEASE_NOTES.md) for capabilities, validation, and known limitations.

## Connect and query

```crystal
require "clickhouse"

client = ClickHouse::Client.from_string(
  ENV["CLICKHOUSE_URL"]? || "clickhouse://default:password@127.0.0.1:9000/default",
  compression: :lz4,
)

begin
  puts client.ping

  result = client.query(
    "SELECT {id:UInt64} AS id, {name:String} AS name",
    params: {id: 42_u64, name: "Ada"},
  )
  result.rows.each do |row|
    puts "#{row["id"].as_u64}: #{row["name"].as_s}"
  end
ensure
  client.close
end
```

Parameters use ClickHouse's typed `{name:Type}` syntax. Values travel separately
from SQL; use parameters rather than interpolating application data. Settings
can be passed separately, for example `settings: {max_block_size: 1000}`.

`clickhouse://` defaults to port `9000`; `clickhouses://` enables TLS and defaults
to `9440`. Percent-encode credentials and database names when needed. Supply
`tls_ca: "/path/to/ca.pem"` for a private CA, and `tls_hostname:` when the verified
server name differs from the connection address. Certificate and hostname
verification are enabled by default.

## Streaming and connection ownership

Use `query_each` to consume rows without materializing the whole result:

```crystal
client.query_each("SELECT number FROM numbers({count:UInt64})", params: {count: 10_000_u64}) do |row|
  puts row["number"].as_u64
end
```

`query_blocks` yields columnar `ClickHouse::Block` values. Streaming retains one
decoded block at a time; retained rows keep their owned values. `query` collects
rows and enforces `max_result_rows` (default `1_000_000`) and `max_result_bytes`
(default `64 MiB` of decoded Native data). Query methods report errors even after
earlier rows have been yielded.

One client has one connection and one active operation. Overlapping operations
raise `ClickHouse::BusyError`; use separate clients for concurrency. Timeouts,
malformed packets, or abandoning a streaming result discard the connection.
Create a new client after it closes. Operations are never replayed automatically.

## Binary batch inserts

```crystal
client.exec("CREATE TABLE IF NOT EXISTS users (id UInt64, name String) ENGINE=MergeTree ORDER BY id")

client.insert("users", columns: ["id", "name"]) do |batch|
  batch.append(1_u64, "Ada")
  batch.append(2_u64, "Grace")
end
```

The server supplies the column schema. Values are encoded as Native columns,
not SQL `VALUES` strings. Column order and types must match the requested schema.
Configure `batch_size` (default `1000`) and `batch_bytes` (default `8 MiB`) when
constructing the client. A transport failure after an upload starts can raise
`ClickHouse::InsertOutcomeUnknown`, including the query ID; verify the result
before deciding whether to retry.

For data already arranged in columns, submit Native blocks directly:

```crystal
block = ClickHouse::Block.new([
  ClickHouse::Column.new("id", "UInt64", [3_u64, 4_u64]),
  ClickHouse::Column.new("name", "String", ["Katherine", "Margaret"]),
])
client.insert_blocks("users", columns: ["id", "name"], blocks: [block])
```

Both insertion interfaces send Native binary blocks. `insert_blocks` avoids
per-row argument arrays and transposition, and consumes its block enumerable
once. Column names, order, types, dimensions, and configured batch limits are
validated against the server schema. Supplied blocks retain their values after
insertion. Construct each block within `batch_size` and `batch_bytes`; direct
blocks are not split automatically. `batch.append_block(block)` also supports
mixing row input and complete columns in one INSERT.

## Values and supported types

Rows support access by column name or index, returning `ClickHouse::Value`.

| ClickHouse types | Crystal access and representation |
| --- | --- |
| Int/UInt8–128 | `as_i64`, `as_u64`, `as_i128`, `as_u128`; checked conversions |
| Float32/64, Bool | `as_f64`, `as_bool` |
| String, FixedString | `as_bytes` preserves arbitrary bytes; `as_s` is explicit text access; FixedString retains padding |
| Nullable(T), Nothing | `null?` distinguishes nulls from default values |
| Decimal32/64/128, Decimal(P,S) up to precision 38 | `as_decimal`: exact `unscaled : Int128` and `scale` |
| Date, Date32 | `raw.as(ClickHouse::DateValue)` stores days from the Unix epoch |
| DateTime, DateTime64 | `as_timestamp`: signed ticks, precision, timezone metadata; `to_time` converts the instant |
| UUID | `as_uuid` |
| IPv4, IPv6 | `raw.as(ClickHouse::IPv4)` / `raw.as(ClickHouse::IPv6)` |
| Enum8/16 | `as_s` returns the label; `raw.as(ClickHouse::EnumValue)` retains the signed code |
| Array(T), Tuple, named Tuple | `as_array`, `as_tuple.values`, `as_tuple.names` |
| Map(K,V) | `as_map.entries`: ordered pairs preserving duplicate keys |
| LowCardinality(T) | Decoded values use the inner type's accessors |

Insert exact decimals with `ClickHouse::Decimal.new(12_345_i128, 2)` and timestamps
with `ClickHouse::Timestamp.new(ticks, precision, timezone)`. Arrays and tuples
are wrapped automatically. Use `ClickHouse::MapValue` when duplicate map keys
matter; a Crystal `Hash` cannot represent those duplicates.

ClickHouse's text parameter parser interprets negative fractional epoch values
between `-1` and `0` seconds incorrectly. `Time` and `Timestamp` query parameters
in that interval raise `ArgumentError` before sending SQL. Pass exact ticks as an
`Int64` parameter and use `fromUnixTimestamp64Nano({ticks:Int64}, 'UTC')` instead
(or the corresponding milli/microsecond function). Native binary DateTime64
queries and inserts preserve the full supported tick range, including that interval.

The client advertises protocol revision **54460**, with minimum server protocol
revision **54459**. Codecs reject unsupported types and custom serialization.
Connection pooling, a `crystal-db` adapter, ZSTD, external tables, transactions,
Int/UInt256, Decimal256, AggregateFunction states, and JSON/Variant/Dynamic codecs
are not implemented. LowCardinality supports per-block dictionaries; shared
dictionary serialization is rejected.

## Configuration and errors

Client keyword options include `connect_timeout` (default `5.seconds`),
`read_timeout`, `write_timeout`, and `query_timeout` (each `30.seconds`),
`compression: :none | :lz4`, and the batch/result limits above. `:none` disables
native compression; LZ4 applies to Native data blocks, not packet headers.

`ClickHouse::ServerError` preserves the server's `code`, `name`, `server_stack`,
and query ID. Connection, busy-state, deadline, codec, and ambiguous-insert
failures have distinct exception types. Configuration inspection redacts passwords.

## Examples

Each directory is a standalone application with its own manifest, lockfile, and
instructions. No shared example helpers are required. The connection, query,
batch-insert, and types examples have been built and run with Crystal 1.21.0
against ClickHouse 26.8.31.2 LTS.

- [Connection](examples/connection/README.md): connect, authenticate, and ping.
- [Query](examples/query/README.md): typed parameters and row streaming.
- [Batch insert](examples/batch_insert/README.md): temporary table, multiple binary batches, and read-back.
- [Types](examples/types/README.md): exact decimals/timestamps, binary strings, UUIDs, and composites.
- [Kemal API](examples/kemal_api/README.md): bulk OpenRTB bid-request ingestion at
  `POST /ortb/bids/bulk`, with paginated listing and UTC date/time filters at
  `GET /ortb/bids`. Includes handler injection, repositories, database setup,
  Docker, and HTTP/persistence specs.
- [Local insert benchmark](examples/kemal_api/benchmark/README.md): one million
  randomized OpenRTB records per row/columnar mode, in 10,000-record INSERTs,
  with real Docker persistence checks. Run explicitly; CI excludes this workload.

```sh
cd examples/query
shards install
shards build
CLICKHOUSE_URL='clickhouse://default:clickhouse_test@127.0.0.1:19000/default' ./bin/example
```

## Development

```sh
shards install
crystal tool format --check --exclude lib --exclude examples/kemal_api/lib
shards build ameba
bin/ameba
crystal spec
```

Real-server specs are opt-in. The Docker configuration pins ClickHouse
**26.8.31.2 LTS** and **26.9.22.3 stable** by image digest and exposes loopback TCP
ports `19000`/`29000` and TLS ports `19440`/`29440`.

```sh
./scripts/generate-test-certs.sh
docker compose up -d --wait
CLICKHOUSE_INTEGRATION=1 \
  CLICKHOUSE_URL='clickhouse://default:clickhouse_test@127.0.0.1:19000/default' \
  CLICKHOUSE_COMPRESSION=lz4 crystal spec spec/integration
```

For verified TLS coverage, also provide `CLICKHOUSE_TLS_URL` with the
`clickhouses://` scheme and `CLICKHOUSE_TLS_CA=spec/fixtures/tls/ca.crt`.
The integration fixtures use disposable tables and verify authentication,
query/insert sequencing, streaming, deadlines, and TLS trust failures.

## License

MIT. CityHash attribution is included in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
