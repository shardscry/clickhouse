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

The standalone manifest installs `shardscry/clickhouse` from GitHub with
`version: ~> 0.0.2`. This directory can be copied outside the checkout and
installed independently with `shards install`.
