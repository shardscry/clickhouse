# Exact and composite values

Reads one row containing UInt64's maximum, a binary String with NUL and invalid
UTF-8, null, exact Decimal, millisecond UTC timestamp, UUID, Array, Tuple, and Map.
The map intentionally repeats a key; `as_map.entries` retains both entries.
Decimal output keeps the unscaled integer and scale instead of using Float64.

```sh
shards install
shards build
CLICKHOUSE_URL='clickhouse://default:clickhouse_test@127.0.0.1:19000/default' ./bin/example
```

Requires Crystal 1.21.0. LZ4 is enabled. Use a `clickhouses://` URL for TLS and
`CLICKHOUSE_TLS_CA` when a private CA is required.

This application has its own manifest and no shared example helpers. It installs
`shardscry/clickhouse` from GitHub with `version: ~> 0.0.2`, so it can be copied
outside the repository and installed independently with `shards install`.
