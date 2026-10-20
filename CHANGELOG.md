# Changelog

## 0.0.2

### Added

- Add a pre-commit hook for formatting, Ameba, library type-checking, and local specs.
- Add repository-specific bug report and feature request templates.
- Generate the API reference in `docs/` during pre-commit checks and require
  generated changes to be reviewed and staged.
- Add `make coverage` and a CI job using kcov 43 to publish local-spec coverage.

### Changed

- Align source, shard manifest, and standalone example versions at `0.0.2`.
- Update every example to the published `~> 0.0.2` driver dependency.

## 0.0.1

### Changed

- Publish the numbered `0.0.1` release and align the source and shard versions.
- Use `github: shardscry/clickhouse` with `~> 0.0.1` in every standalone example.
- Document the published dependency in the README and example instructions.
- Support numbered releases and prereleases in the tag-driven release workflow.

### Added

- Crystal 1.21+, ClickHouse Native TCP, and Query client README badges.

## 0.0.1-draft — Beta prerelease

Initial beta. APIs and compatibility guarantees may change before a stable release.

### Added

- Native Crystal ClickHouse TCP driver with revision-aware Hello, query, progress,
  exception, and completion handling at protocol revision 54460.
- TCP and verified TLS connections, password authentication, redacted
  configuration inspection, IO timeouts, and query deadlines.
- Materialized queries, row/block streaming, typed server-side parameters,
  settings, and explicit ownership of one active operation per connection.
- Server-schema-guided Native binary inserts with bounded batches and explicit
  unknown-outcome errors after transport failures.
- Direct columnar `insert_blocks`, typed column arrays, and mixed row/block
  batches with schema validation and retained caller ownership.
- Primitive, binary string, nullable, exact numeric/time, UUID/IP, enum,
  Array/Tuple/Map, and per-block LowCardinality codecs.
- Pure Crystal LZ4 and ClickHouse CityHash128 1.0.2 compression with bounded frame
  validation and independent upstream fixtures.
- Deterministic protocol, codec, compression, configuration, and real-server
  integration specs; pinned LTS/stable Docker services with private-CA TLS.
- Standalone connection, streaming-query, batch-insert, and typed-value examples.
- Standalone Kemal API for bulk OpenRTB bid-request inserts and paginated
  date/time lookups, with injected handlers, HTTP specs, and real-server tests.
- Local-only, opt-in Docker benchmark comparing one million randomized OpenRTB
  records per insertion mode in batches of 10,000, with persistence verification.
