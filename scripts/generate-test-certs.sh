#!/usr/bin/env bash
set -euo pipefail

task_root=$(cd "$(dirname "$0")/.." && pwd)
cert_dir="$task_root/spec/fixtures/tls"
mkdir -p "$cert_dir"

if [[ "${1:-}" != "--force" && -s "$cert_dir/ca.crt" && -s "$cert_dir/server.crt" && -s "$cert_dir/server.key" ]]; then
  if openssl x509 -checkend 3600 -noout -in "$cert_dir/ca.crt" >/dev/null 2>&1 \
    && openssl x509 -checkend 3600 -noout -in "$cert_dir/server.crt" >/dev/null 2>&1; then
    exit 0
  fi
fi

openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -keyout "$cert_dir/ca.key" -out "$cert_dir/ca.crt" \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -subj '/CN=ClickHouse Crystal disposable integration CA' >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes \
  -keyout "$cert_dir/server.key" -out "$cert_dir/server.csr" \
  -subj '/CN=localhost' >/dev/null 2>&1
cat > "$cert_dir/server.ext" <<'EOF'
subjectAltName=DNS:localhost,DNS:clickhouse-lts,DNS:clickhouse-stable,IP:127.0.0.1
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EOF
openssl x509 -req -days 30 -in "$cert_dir/server.csr" \
  -CA "$cert_dir/ca.crt" -CAkey "$cert_dir/ca.key" -CAcreateserial \
  -extfile "$cert_dir/server.ext" -out "$cert_dir/server.crt" >/dev/null 2>&1
# The disposable server key must be readable by the container's unprivileged user.
chmod 644 "$cert_dir/server.key"
printf 'Created disposable integration certificates in %s\n' "$cert_dir"
