#!/usr/bin/env bash
set -euo pipefail

task_root=$(cd "$(dirname "$0")/.." && pwd)
server="${1:-lts}"
case "$server" in
  lts|stable) ;;
  *) printf 'Usage: %s [lts|stable]\n' "$0" >&2; exit 2 ;;
esac

docker run --rm --network clickhouse-crystal_default \
  -v "$task_root:/app" -w /app \
  -e CRYSTAL_CACHE_DIR=/tmp/crystal-cache \
  -e CLICKHOUSE_INTEGRATION=1 \
  -e "CLICKHOUSE_URL=clickhouse://default:clickhouse_test@clickhouse-$server:9000/default" \
  -e "CLICKHOUSE_TLS_URL=clickhouses://default:clickhouse_test@clickhouse-$server:9440/default" \
  -e CLICKHOUSE_TLS_CA=/app/spec/fixtures/tls/ca.crt \
  -e "CLICKHOUSE_COMPRESSION=${CLICKHOUSE_COMPRESSION:-none}" \
  crystallang/crystal:1.21.0 \
  bash -ec 'shards install
crystal spec spec/integration --error-on-warnings --error-trace'
