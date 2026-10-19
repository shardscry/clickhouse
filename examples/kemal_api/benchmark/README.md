# Local native insertion benchmark

This opt-in real-server spec compares **1,000,000 rows per mode**, using
**100 INSERT operations of 10,000 records each**. Both paths use the native
binary protocol with LZ4:

- Row mode calls `Client#insert` and `Batch#append` for each record.
- Columnar mode builds typed columns and passes each block to `Client#insert_blocks`.

The benchmark bypasses HTTP so it measures the driver's insertion paths. It
uses the Kemal example's five-column schema, realistic synthetic OpenRTB JSON,
and separate disposable MergeTree tables. `record_factory.cr` generates a fresh
randomized body, UUID, unique request ID, and deterministic receipt time for every
record. Each mode resets the same random seed, giving both paths identical
million-record datasets while retaining only one 10,000-record batch at a time.
No external traffic or real user data is involved.

Run from this directory or the example directory:

```sh
./run.sh
# Or from examples/kemal_api:
./benchmark/run.sh
```

The script starts the example's pinned ClickHouse Docker service, compiles with
Crystal 1.21.0 in release mode, and runs the spec. It leaves the server running
and drops only its own uniquely named benchmark tables, including after a failed
assertion. It is outside `spec/` and is never run automatically by CI.

For a shorter smoke run, use `BENCHMARK_ROWS=10000 ./run.sh`. The row count must
be a positive multiple of 10,000. `CLICKHOUSE_BENCHMARK_URL` can select a server
reachable from the benchmark container. Running the spec directly requires
`CLICKHOUSE_BENCHMARK=1` and `--release`.

`BENCHMARK_SEED` defaults to `424242`. Random generation includes impression
counts/formats/prices, publisher/site, device/geo, user, currency, timeout, and
vendor fields. Reports show the seed and actual average payload size.

Random body/UUID generation is timed separately from insertion. The comparable
ingestion timer includes `Batch#append` conversion in row mode and typed
column/Block construction plus `insert_blocks` in columnar mode. Optional
column-preparation and native-API timings expose that split. One connection is
reused per mode. Schema creation, one warm-up batch, truncation, verification,
and cleanup are excluded.

Each mode verifies the row count, exact UUID uniqueness, impression sum, payload
byte total, and first/last payloads before printing JSON metrics. An aggregate
XOR of server `cityHash64(payload)` values must also match between modes. Output
includes comparable ingestion rows/second, JSON-payload MiB/second, generation
plus ingestion throughput, batch size, server/compiler/driver versions,
architecture, and release mode. These are local measurements, with no arbitrary
minimum throughput assertion or general performance claim.
