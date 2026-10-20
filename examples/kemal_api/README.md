# OpenRTB bid-request ingestion API

A standalone Kemal application using the native Crystal ClickHouse driver to
ingest OpenRTB-shaped bid requests and query their receipt times with SQL. It
owns its dependencies, handlers, entities, repositories, and specs. Its manifest
installs `shardscry/clickhouse` from GitHub with `version: ~> 0.0.1`. This
directory can be copied and run independently of the repository checkout;
no shared example files are required.

This is an ingestion/query example. It does not run auctions or return OpenRTB
bid responses. The [IAB OpenRTB 2.6 specification](https://github.com/InteractiveAdvertisingBureau/openrtb2.x/blob/main/2.6.md#objectbidrequest)
requires a request ID, impressions, and unique IDs within those impressions.
This application validates those selected envelope fields, not the full
specification, inventory/media objects, privacy rules, or extension semantics.
Unknown fields and their JSON values are retained; original whitespace and
numeric formatting are not preserved.

## Run locally

Requires Crystal **1.21.0+**, Shards, and Docker Compose. From this directory:

```sh
shards install
docker compose up -d --wait
crystal run setup.cr
shards build
./bin/kemal_api
```

The API listens on `http://127.0.0.1:3000`. Compose starts the pinned official
ClickHouse LTS `26.8.31.2` on native TCP `127.0.0.1:19001`, independently of the
repository's other Docker projects. `setup.cr` creates the configured table if
missing; it does not migrate an existing table.

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLICKHOUSE_URL` | `clickhouse://default:clickhouse_test@127.0.0.1:19001/default` | Native endpoint, credentials, and database |
| `CLICKHOUSE_TABLE` | `ortb_bid_requests` | Simple SQL table identifier |
| `HOST` | `127.0.0.1` | HTTP bind address |
| `PORT` | `3000` | HTTP port |

## Insert bid requests

`POST /ortb/bids/bulk` accepts an `application/json` array:

```sh
curl -sS http://127.0.0.1:3000/ortb/bids/bulk \
  -H 'Content-Type: application/json' \
  -d '[
    {"id":"auction-1","imp":[{"id":"1","banner":{"format":[{"w":300,"h":250}]}}],"site":{"page":"https://publisher.example/article"}},
    {"id":"auction-2","imp":[{"id":"1","banner":{"format":[{"w":728,"h":90}]}}],"ext":{"vendor":"retained"}}
  ]'
```

Success is `201` with `inserted`, generated UUID `ingestion_ids`, one UTC
millisecond `received_at` shared by that bulk, and `Location: /ortb/bids`.

Limits are **1–10,000 requests**, **16 MiB total body**, **64 KiB serialized JSON per
request**, and **1–1000 impressions per request**. Every request needs a nonblank
string `id`; every impression must be an object with a nonblank string `id`,
unique within its request. The entire bulk is validated before insertion.

Records are append-only. Repeating an auction/request ID creates a new ingestion
UUID and another record. Inserts have no atomicity or exactly-once guarantee;
rows may already exist when an insert fails. An uncertain insert returns `503`
with `query_id`; reconcile its outcome before deciding whether to submit again.
The application does not automatically retry.

## List and filter

`GET /ortb/bids` returns `data`, `page`, `per_page`, `total`, and `total_pages`.
Each record contains ingestion metadata and the original semantic JSON object
under `request`. Defaults are `page=1&per_page=20`; `per_page` is limited to 100.

```sh
curl -sS 'http://127.0.0.1:3000/ortb/bids?page=1&per_page=20'
curl -sS 'http://127.0.0.1:3000/ortb/bids?date=2026-10-20'
curl -sS --get http://127.0.0.1:3000/ortb/bids \
  --data-urlencode 'from=2026-10-20T08:00:00.000+02:00' \
  --data-urlencode 'to=2026-10-20T09:00:00.000+02:00'
```

`date=YYYY-MM-DD` selects a UTC calendar day. Alternatively, `from` and/or `to`
accept RFC3339 timestamps with an explicit timezone and at most millisecond
precision. The lower bound is inclusive; the upper bound is exclusive. Do not
combine `date` with `from`/`to`. Dates are supported from 1900 through 2299.
URL-encode timezone `+` signs, as the example does.

SQL applies filters before pagination and orders by `received_at DESC,
ingestion_id DESC`. Counts use a separate query. New inserts can shift pages or
change totals between requests; this is offset pagination, not a snapshot.

Malformed JSON or query parameters return `400`; unsupported content type `415`;
invalid envelope fields `422`; byte/count limits `413`. Errors are JSON with
descriptive `error` text. An ambiguous insert additionally includes `query_id`.

## Structure and tests

`src/main.cr` starts the application. Configuration lives beside `app.cr`;
`routing.cr` delegates to individual injectable handlers. Entities are pure
structures, DTOs live in `structs/`, and the repository owns ClickHouse SQL and
binary inserts. Athena binds each handler's `bid_request_repository` centrally.
Each repository operation opens and closes its own client.

```sh
crystal spec --error-on-warnings
CLICKHOUSE_INTEGRATION=1 crystal spec --error-on-warnings
```

The first command uses an injected in-memory repository. The opt-in suite uses
real ClickHouse through `CLICKHOUSE_URL`, creates a uniquely named test table,
and cleans up only that table. It requires create/select/insert/truncate/drop
permissions. Both suites cover HTTP validation, dependency injection,
pagination, UTC/offset/millisecond boundaries, and ambiguous inserts; integration
also inspects stored native UUID, timestamp, count, and JSON columns.

Stop this example's disposable database with `docker compose down -v`.

## Local benchmark

The [benchmark harness](benchmark/README.md) generates randomized OpenRTB-shaped
requests and compares the row API (`Batch#append`) with the columnar API
(`Client#insert_blocks`). Both use ClickHouse's native columnar wire format.
It defaults to **1,000,000 records per mode**, in **100 inserts of 10,000 records**:

```sh
./benchmark/run.sh
BENCHMARK_ROWS=10000 ./benchmark/run.sh
```

The second command is a smaller smoke run. The workload is local and never runs
in CI. Both modes reset the same random seed, and generation time is reported
separately from ingestion. See its README for configuration, isolation, and
result interpretation.
