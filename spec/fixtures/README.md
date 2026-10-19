# Native protocol fixtures

`protocol_54460_*.json` records independent real-server exchanges produced by
`scripts/native-protocol-probe.py`, a Python standard-library implementation of
the audited subset of revision 54460. The Crystal driver does not invoke this
script or the ClickHouse CLI at runtime.

Captured on 2026-10-20 using these official Docker images:

| Channel | Version | Published image-index digest | arm64 manifest digest |
| --- | --- | --- | --- |
| LTS | 26.8.31.2 | `sha256:05d2e46507afdcf08da46e5528b68847104dbbed691c327e505414b4b7f4e4c8` | `sha256:9dbcb3258bbbfaf8ca20193c512c478b4f114c72c7eb4770c47aacc700fc4a35` |
| Stable | 26.9.22.3 | `sha256:3358498f63c33d60ec1fa3abe9918e63c6b1d86dbad20e5613590a2899d5d872` | `sha256:e3896e0b10b080613463ec6d6bc1e9368abd53909bb091344009760e7a4d5165` |

Both servers advertised revision **54492**; the independent client advertised
**54460**. Plain TCP and verified TLS passed the same eight checks:
Hello/addendum/Ping, SELECT/schema/metadata, multi-block SELECT, escaped typed
parameters, binary INSERT with both empty markers, terminal exceptions followed
by reuse, cancellation/draining followed by reuse, and incorrect authentication.

The protocol reference source is ClickHouse commit
`abf12b3b072bc93aadeb8c5d15f42fc20f9ee82a`; the independent implementation also
cross-checks official ch-go commit `600546438865214b4f407cae06a9492c925b8802`.
These source pins describe the protocol research, not the build commit of either
runtime Docker server. Exact runtime versions appear in the captures.

Packet `hex` fields are bytes observed or sent on the application stream after
TLS decryption. To keep fixtures small, telemetry payloads have their byte count
and SHA-256 instead of hex; already-buffered Data packets consumed after Cancel
are counted separately. Query UUIDs, server hostnames, timings, and hashes vary
when regenerating. `trace_sha256` hashes the JSON serialization of the trace with
sorted keys; it protects a particular capture rather than defining a stable
cross-run snapshot. Test credentials are disposable Docker-only values.

Regenerate from the repository directory:

```sh
bash scripts/generate-test-certs.sh
docker compose up -d --wait
python3 scripts/native-protocol-probe.py --port 19000 --output spec/fixtures/protocol_54460_lts.json
python3 scripts/native-protocol-probe.py --port 29000 --output spec/fixtures/protocol_54460_stable.json
python3 scripts/native-protocol-probe.py --port 19440 --tls --ca spec/fixtures/tls/ca.crt --output spec/fixtures/protocol_54460_lts_tls.json
python3 scripts/native-protocol-probe.py --port 29440 --tls --ca spec/fixtures/tls/ca.crt --output spec/fixtures/protocol_54460_stable_tls.json
```

The `tls/` directory contains generated, ignored certificates and disposable
private keys. Generate fresh certificates before starting containers; use
`--force` to replace existing test certificates and restart both servers after
replacement. `docker compose down -v` removes only this project's containers and
volumes. The probe performs uncompressed protocol validation; Crystal integration
specs separately cover LZ4.

Run the Crystal suite against the already-started servers:

```sh
bash scripts/test-integration.sh lts
CLICKHOUSE_COMPRESSION=lz4 bash scripts/test-integration.sh lts
bash scripts/test-integration.sh stable
CLICKHOUSE_COMPRESSION=lz4 bash scripts/test-integration.sh stable
```

This starts only a disposable Crystal test container and includes both native
TCP and verified native TLS. The observed network compression codec must be
selected by the driver; enabling the query compression flag alone does not
guarantee that a modern server will send LZ4.
