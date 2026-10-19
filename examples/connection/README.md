# Connection

Connects through native TCP, authenticates, checks Ping/Pong, and reads the server
version. The client closes in `ensure`, including when a query raises.

Requires Crystal 1.21.0 and a running ClickHouse server. From this directory:

```sh
shards install
shards build
CLICKHOUSE_URL='clickhouse://default:clickhouse_test@127.0.0.1:19000/default' ./bin/example
```

For TLS, use `clickhouses://` and set `CLICKHOUSE_TLS_CA` to your private CA file
when required. The server certificate must match the URL hostname.

The local manifest points at the shard in `../..`; the application does not
depend on any other example. The current `0.0.1-draft` version is a beta prerelease.
Use `github: shardscry/clickhouse` with
`version: 0.0.1-draft` when copying the application elsewhere.
