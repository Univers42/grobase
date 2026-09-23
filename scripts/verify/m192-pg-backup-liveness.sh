#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m192-pg-backup-liveness.sh — the backup sidecar is healthy only when it     #
#  could take a backup: PostgreSQL answers AND MinIO answers                   #
#                                                                              #
#  pg-backup's healthcheck ran `entrypoint.sh liveness`, which tested that     #
#  DATABASE_URL was non-empty and that a string with a default was non-empty:  #
#  it could not fail while the variable was set, so the sidecar reported       #
#  healthy with PostgreSQL and MinIO both gone (issue #19). Now liveness runs  #
#  pg_isready against DATABASE_URL and lists MinIO's buckets, both bounded.    #
#                                                                              #
#  Builds pg-backup from THIS tree and runs its liveness in a throwaway        #
#  container next to a throwaway PostgreSQL and MinIO:                         #
#    1 both up              -> 0                                               #
#    2 PostgreSQL stopped   -> non-zero                                        #
#    3 MinIO stopped        -> non-zero (PostgreSQL back up)                   #
#    4 both up again        -> 0                                               #
#                                                                              #
#  Mutant: M192_CONTEXT=<a tree with the previous entrypoint.sh> builds the    #
#  old liveness; step 2 then stays 0 and this gate goes red.                   #
#                                                                              #
#  Own network, containers and image tag, removed by an EXIT trap.             #
# **************************************************************************** #
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CTX="${M192_CONTEXT:-${ROOT}/infra/docker/services/pg-backup}"
PG_IMAGE="${M192_PG_IMAGE:-postgres:16-alpine}"
MINIO_IMAGE="${M192_MINIO_IMAGE:-ghcr.io/univers42/grobase-minio:latest}"
IMG="grobase-pg-backup:m192-$$"
NET="m192-net-$$"
PG="m192-pg-$$"
MINIO="m192-minio-$$"
SIDE="m192-backup-$$"
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M192] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M192] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}
cleanup() {
  docker rm -f "${SIDE}" "${PG}" "${MINIO}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${IMG}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

liveness() { timeout 20 docker exec "${SIDE}" /opt/pg-backup/entrypoint.sh liveness >/dev/null 2>&1; }
settle() { # <want: pass|fail>  -- the probe's verdict within 20 s
  local i
  for i in $(seq 1 10); do
    if liveness; then [ "$1" = pass ] && return 0; else [ "$1" = fail ] && return 0; fi
    sleep 2
  done
  return 1
}

step "0/4 build pg-backup from ${CTX#"${ROOT}"/} and start its peers"
command -v docker >/dev/null 2>&1 || fail "docker is required"
docker build -q -t "${IMG}" "${CTX}" >/dev/null || fail "could not build ${CTX}"
for img in "${PG_IMAGE}" "${MINIO_IMAGE}"; do
  docker image inspect "${img}" >/dev/null 2>&1 || docker pull -q "${img}" >/dev/null || fail "cannot get ${img}"
done
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" --network-alias m192pg -e POSTGRES_PASSWORD=m192 "${PG_IMAGE}" >/dev/null
docker run -d --name "${MINIO}" --network "${NET}" --network-alias m192minio \
  -e MINIO_ROOT_USER=m192admin -e MINIO_ROOT_PASSWORD=m192-secret-key "${MINIO_IMAGE}" server /data >/dev/null
# The sidecar's own loop is not under test: sleep, and exec its probe.
docker run -d --name "${SIDE}" --network "${NET}" --entrypoint sleep \
  -e DATABASE_URL="postgres://postgres:m192@m192pg:5432/postgres" \
  -e MINIO_ENDPOINT=http://m192minio:9000 -e MINIO_ROOT_USER=m192admin \
  -e MINIO_ROOT_PASSWORD=m192-secret-key -e PG_BACKUP_BUCKET=backups "${IMG}" 3600 >/dev/null
ok "throwaway PostgreSQL, MinIO and pg-backup (${IMG}) running"

step "1/4 both up -> healthy"
settle pass || fail "liveness never passed with PostgreSQL and MinIO up"
ok "liveness 0"

step "2/4 PostgreSQL stopped -> unhealthy"
docker stop -t 2 "${PG}" >/dev/null
settle fail || fail "PostgreSQL stopped and liveness still passes: it does not ask whether a backup could run"
ok "liveness non-zero"

step "3/4 PostgreSQL back, MinIO stopped -> unhealthy"
docker start "${PG}" >/dev/null
docker stop -t 2 "${MINIO}" >/dev/null
settle fail || fail "MinIO stopped and liveness still passes: a dump could not be uploaded"
ok "liveness non-zero"

step "4/4 both back -> healthy again"
docker start "${MINIO}" >/dev/null
settle pass || fail "liveness did not recover with both peers back"
ok "liveness 0"
