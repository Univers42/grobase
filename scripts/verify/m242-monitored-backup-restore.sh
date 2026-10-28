#!/usr/bin/env bash
# Real monitored backup -> independent readback -> isolated restore -> row check.
# Requires Docker; all names/data belong to this drill and are removed on exit.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v docker >/dev/null || { echo '[M242] Docker is required' >&2; exit 1; }
docker info >/dev/null
ID="m242-$$"
NET="${ID}-net"
PG="${ID}-pg"
STORE="${ID}-store"
IMAGE="grobase-backup:${ID}"
cleanup() {
  docker rm -f "$PG" "$STORE" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker image rm "$IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker build -q -t "$IMAGE" "${ROOT}/infra/docker/services/pg-backup" >/dev/null
docker network create "$NET" >/dev/null
docker run -d --name "$PG" --network "$NET" --network-alias pg \
  -e POSTGRES_PASSWORD=drill-only postgres:16-alpine >/dev/null
docker run -d --name "$STORE" --network "$NET" --network-alias store \
  -e MINIO_ROOT_USER=drill-user -e MINIO_ROOT_PASSWORD=drill-password \
  ghcr.io/univers42/grobase-minio:latest server /data >/dev/null
for attempt in $(seq 1 60); do
  if docker exec "$PG" pg_isready -U postgres >/dev/null 2>&1 && \
    docker run --rm --network "$NET" --entrypoint bash "$IMAGE" -c \
      'mc alias set baas http://store:9000 drill-user drill-password >/dev/null && mc ls baas/ >/dev/null' >/dev/null 2>&1; then break; fi
  [ "$attempt" != 60 ] || { echo '[M242] peers did not become ready' >&2; exit 1; }
  sleep 2
done
docker exec "$PG" psql -U postgres -v ON_ERROR_STOP=1 -c 'CREATE DATABASE source' -c 'CREATE DATABASE recovered' >/dev/null
docker exec "$PG" psql -U postgres -d source -v ON_ERROR_STOP=1 \
  -c "CREATE TABLE proof (id integer PRIMARY KEY, value text); INSERT INTO proof VALUES (42, 'restored')" >/dev/null
BACKUP_ENV=(-e DATABASE_URL=postgres://postgres:drill-only@pg:5432/source \
  -e MINIO_ENDPOINT=http://store:9000 -e MINIO_ROOT_USER=drill-user \
  -e MINIO_ROOT_PASSWORD=drill-password -e PG_BACKUP_BUCKET=backups \
  -e PG_BACKUP_PREFIX=postgres -e PG_BACKUP_MONITOR=1)
if docker run --rm --network "$NET" "${BACKUP_ENV[@]}" "$IMAGE" liveness >/dev/null 2>&1; then
  echo '[M242] missing verified backup reported healthy' >&2; exit 1
fi
docker run --rm --network "$NET" "${BACKUP_ENV[@]}" "$IMAGE" once
docker run --rm --network "$NET" "${BACKUP_ENV[@]}" "$IMAGE" liveness
KEY="$(docker run --rm --network "$NET" "${BACKUP_ENV[@]}" --entrypoint bash "$IMAGE" -c \
  'mc alias set baas "$MINIO_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null; mc ls baas/backups/postgres/logical/ | awk '\''$NF ~ /[.]dump$/ { print $NF }'\''')"
[ -n "$KEY" ] || { echo '[M242] no dump uploaded' >&2; exit 1; }
docker run --rm --network "$NET" "${BACKUP_ENV[@]}" \
  -e RESTORE_DATABASE_URL=postgres://postgres:drill-only@pg:5432/recovered \
  -e RESTORE_CONFIRM=RESTORE "$IMAGE" restore "$KEY"
RESULT="$(docker exec "$PG" psql -U postgres -d recovered -Atc 'SELECT id || '\'':'\'' || value FROM proof')"
[ "$RESULT" = '42:restored' ] || { echo '[M242] restored row differs' >&2; exit 1; }
docker run --rm --network "$NET" "${BACKUP_ENV[@]}" --entrypoint bash "$IMAGE" -c \
  'mc alias set baas "$MINIO_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null; echo 1 >/tmp/stale; mc cp /tmp/stale baas/backups/postgres/monitor/last-success >/dev/null'
if docker run --rm --network "$NET" "${BACKUP_ENV[@]}" "$IMAGE" liveness >/dev/null 2>&1; then
  echo '[M242] stale backup reported healthy' >&2; exit 1
fi
echo '[M242] verified upload, isolated restore, concrete row readback and stale detection passed'
