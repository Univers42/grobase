#!/usr/bin/env bash
# Real monitored backup -> independent readback -> isolated restore -> row check.
# Requires Docker; all names/data belong to this drill and are removed on exit.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v docker >/dev/null || {
  echo '[M242] Docker is required' >&2
  exit 1
}
docker info >/dev/null
command -v openssl >/dev/null || {
  echo "[M242] OpenSSL is required" >&2
  exit 1
}
umask 077
TLS="$(mktemp -d)"
source "${ROOT}/scripts/verify/recovery-drill-tls.sh"
ID="m242-$$"
NET="${ID}-net"
PG="${ID}-pg"
STORE="${ID}-store"
IMAGE="grobase-backup:${ID}"
cleanup() {
  docker rm -f "$PG" "$STORE" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker image rm "$IMAGE" >/dev/null 2>&1 || true
  rm -rf "$TLS"
}
trap cleanup EXIT
create_drill_tls "$TLS"
docker build -q -t "$IMAGE" "${ROOT}/infra/docker/services/pg-backup" >/dev/null
docker network create "$NET" >/dev/null
docker run -d --name "$PG" --network "$NET" --network-alias pg \
  --env-file "$TLS/pg.env" -v "$TLS/pg:/tls:ro" \
  -v "$TLS/require-tls.sh:/docker-entrypoint-initdb.d/require-tls.sh:ro" \
  --entrypoint sh postgres:16-alpine -c \
  'cp /tls/private.key /var/lib/postgresql/server.key; chown postgres:postgres /var/lib/postgresql/server.key; chmod 600 /var/lib/postgresql/server.key; exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/tls/public.crt -c ssl_key_file=/var/lib/postgresql/server.key' >/dev/null
docker run -d --name "$STORE" --network "$NET" --network-alias store \
  --env-file "$TLS/store.env" -v "$TLS/store:/tls:ro" \
  ghcr.io/univers42/grobase-minio:latest server /data --certs-dir /tls >/dev/null
source "$TLS/pg.env"
source "$TLS/store.env"
BACKUP_ENV=(--env-file "$TLS/store.env" -e "PGPASSWORD=$POSTGRES_PASSWORD"
  -e PGSSLROOTCERT=/tls/ca.crt -v "$TLS/ca.crt:/tls/ca.crt:ro"
  -v "$TLS/client:/root/.mc/certs:ro"
  -e 'DATABASE_URL=postgresql://postgres@pg:5432/source?sslmode=verify-full'
  -e MINIO_ENDPOINT=https://store:9000 -e PG_BACKUP_BUCKET=backups
  -e PG_BACKUP_PREFIX=postgres -e PG_BACKUP_MONITOR=1)
for attempt in $(seq 1 60); do
  if docker exec "$PG" pg_isready -U postgres >/dev/null 2>&1 &&
    docker run --rm --network "$NET" "${BACKUP_ENV[@]}" --entrypoint bash "$IMAGE" -c \
      'mc alias set baas "$MINIO_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null && mc ls baas/ >/dev/null' >/dev/null 2>&1; then break; fi
  [[ "$attempt" != 60 ]] || {
    echo '[M242] peers did not become ready' >&2
    exit 1
  }
  sleep 2
done
docker exec "$PG" psql -U postgres -v ON_ERROR_STOP=1 -c 'CREATE DATABASE source' -c 'CREATE DATABASE recovered' >/dev/null
docker exec "$PG" psql -U postgres -d source -v ON_ERROR_STOP=1 \
  -c "CREATE TABLE proof (id integer PRIMARY KEY, value text); INSERT INTO proof VALUES (42, 'restored')" >/dev/null
docker run --rm --network "$NET" "${BACKUP_ENV[@]}" --entrypoint bash "$IMAGE" -euc \
  'test "$(psql "$DATABASE_URL" -Atc "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()")" = t; if psql "${DATABASE_URL/verify-full/disable}" -Atc "SELECT 1" >/dev/null 2>&1; then exit 1; fi; if PGSSLROOTCERT=/missing-ca psql "$DATABASE_URL" -Atc "SELECT 1" >/dev/null 2>&1; then exit 1; fi'
if docker run --rm --network "$NET" "${BACKUP_ENV[@]}" "$IMAGE" liveness >/dev/null 2>&1; then
  echo '[M242] missing verified backup reported healthy' >&2
  exit 1
fi
docker run --rm --network "$NET" "${BACKUP_ENV[@]}" "$IMAGE" once
docker run --rm --network "$NET" "${BACKUP_ENV[@]}" "$IMAGE" liveness
KEY="$(docker run --rm --network "$NET" "${BACKUP_ENV[@]}" --entrypoint bash "$IMAGE" -c \
  'mc alias set baas "$MINIO_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null; mc ls baas/backups/postgres/logical/ | awk '\''$NF ~ /[.]dump$/ { print $NF }'\''')"
[[ -n "$KEY" ]] || {
  echo '[M242] no dump uploaded' >&2
  exit 1
}
docker run --rm --network "$NET" "${BACKUP_ENV[@]}" \
  -e 'RESTORE_DATABASE_URL=postgresql://postgres@pg:5432/recovered?sslmode=verify-full' \
  -e RESTORE_CONFIRM=RESTORE "$IMAGE" restore "$KEY"
RESULT="$(docker exec "$PG" psql -U postgres -d recovered -Atc 'SELECT id || '\'':'\'' || value FROM proof')"
[[ "$RESULT" = '42:restored' ]] || {
  echo '[M242] restored row differs' >&2
  exit 1
}
docker run --rm --network "$NET" "${BACKUP_ENV[@]}" --entrypoint bash "$IMAGE" -c \
  'mc alias set baas "$MINIO_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null; echo 1 >/tmp/stale; mc cp /tmp/stale baas/backups/postgres/monitor/last-success >/dev/null'
if docker run --rm --network "$NET" "${BACKUP_ENV[@]}" "$IMAGE" liveness >/dev/null 2>&1; then
  echo '[M242] stale backup reported healthy' >&2
  exit 1
fi
echo '[M242] verified upload, isolated restore, concrete row readback and stale detection passed'
