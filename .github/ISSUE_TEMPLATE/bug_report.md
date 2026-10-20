---
name: Bug report
about: Report a reproducible defect in the ClickHouse shard
title: "[BUG] <short summary>"
---

<!-- Remove credentials, row contents, and other private data from examples and logs. -->

## Summary

<!-- Describe the failing connection, query, insert, or decoding operation. -->

## Environment

- Shard version or commit (`ClickHouse::VERSION`):
- Crystal version (`crystal --version`):
- ClickHouse Server version (`SELECT version()`):
- OS and architecture:
- Native connection: TCP (`clickhouse://`) / TLS (`clickhouses://`)
- Compression: `:none` / `:lz4`
- Relevant timeout, batch, or result limits:

<!-- For TLS issues, describe certificate trust configuration without sharing private keys. -->

## Minimal reproduction

<!-- Include a self-contained Crystal snippet or repository link. Include SQL,
CREATE TABLE, relevant column types, and a small input sample when needed.
For inserts, specify row-based Client#insert or columnar Client#insert_blocks. -->

```crystal

```

## Steps to reproduce

1.
2.
3.

## Expected behavior

<!-- What did you expect to happen? -->

## Actual behavior

<!-- Describe the result and include the full error or relevant logs. -->

```text

```

## Additional context

<!-- Optional: regression version, frequency, related issues, or a workaround. -->
