#!/usr/bin/env bash
set -euo pipefail

benchmark_root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
example_root=$(cd "$benchmark_root/.." && pwd)
repository_root=$(cd "$example_root/../.." && pwd)

docker compose -f "$example_root/docker-compose.yml" up -d --wait
docker run --rm --network clickhouse-kemal-ortb_default \
  -v "$repository_root:$repository_root" -w "$example_root" \
  -e CLICKHOUSE_BENCHMARK=1 \
  -e BENCHMARK_ROWS="${BENCHMARK_ROWS:-1000000}" \
  -e BENCHMARK_SEED="${BENCHMARK_SEED:-424242}" \
  -e CLICKHOUSE_URL="${CLICKHOUSE_BENCHMARK_URL:-clickhouse://default:clickhouse_test@clickhouse:9000/default}" \
  -e CRYSTAL_CACHE_DIR=/tmp/clickhouse-benchmark-cache \
  crystallang/crystal:1.21.0 \
  bash -ec 'shards install --frozen; crystal spec --release --error-on-warnings benchmark/native_insert_spec.cr'
