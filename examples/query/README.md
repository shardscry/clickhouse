# Typed parameters and streaming

Runs a small materialized query, then streams ten rows across small Native
blocks. It enables LZ4 and sends parameter values separately from SQL, including
a string containing a quote.

```sh
shards install
shards build
CLICKHOUSE_URL='clickhouse://default:clickhouse_test@127.0.0.1:19000/default' ./bin/example
```

Requires Crystal 1.21.0. Set `CLICKHOUSE_TLS_CA` for a private CA when using a
`clickhouses://` URL. Fully consume streaming results; early exit closes the
connection to avoid reusing an unread response.

The standalone manifest uses `path: ../..` for this `0.0.1-draft` beta prerelease.
Use `github: shardscry/clickhouse` with
`version: 0.0.1-draft` when moving the application outside the checkout.
