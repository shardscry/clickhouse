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

The standalone manifest installs `shardscry/clickhouse` from GitHub with
`version: ~> 0.0.1`. Copy this directory anywhere and run `shards install`;
the application does not depend on the repository checkout or other examples.
