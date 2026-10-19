# Binary batch insert

Creates a connection-local temporary table, inserts five users in batches of
two, and streams them back in order. Column values use Native binary encoding;
the driver obtains the insert schema from the server. The temporary table is
removed automatically when the connection closes.

```sh
shards install
shards build
CLICKHOUSE_URL='clickhouse://default:clickhouse_test@127.0.0.1:19000/default' ./bin/example
```

Requires Crystal 1.21.0 and permissions to create temporary tables. LZ4 is
enabled. For TLS, use a `clickhouses://` URL and set `CLICKHOUSE_TLS_CA` when
trusting a private CA.

The standalone manifest uses `path: ../..` for the `0.0.1-draft` beta prerelease.
Use `github: shardscry/clickhouse` with
`version: 0.0.1-draft` when copying the application elsewhere.
