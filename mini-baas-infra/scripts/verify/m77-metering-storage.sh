#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m77-metering-storage.sh                            :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M77 — Track-B metering B1d-storage gate. Proves the storage-router (NestJS/TS)
# emits the `storage.bytes` usage metric through the FROZEN producer/consumer
# boundary: on a SUCCESSFUL object upload it adds the object's byte size to a
# per-(tenant, metric) windowed CUMULATIVE aggregate, the background flusher
# XADDs the running window total ONCE per window to the single Redis stream
# `usage.events`, and the B1b Go control-plane consumer (METERING_INGEST)
# idempotently UPSERTs it into public.tenant_usage — and that the whole thing is
# byte-parity when STORAGE_METERING is OFF.
#
#   storage-router (TS, STORAGE_METERING=1, small FLUSH_MS)
#         │  PUT /storage/v1/object/<bucket>/<key>  (real bytes → minio)
#         │  on success: meter.record(tenant, byteLength)  [cumulative per window]
#         ▼  flusher every window: XADD usage.events {tenant_id, metric=storage.bytes,
#            qty, ts, window_ms, idempotency_key = sha256("tenant|metric|window")}
#   redis  (the single `usage.events` stream)
#         │  XREADGROUP (consumer group "metering-ingest")
#         ▼
#   orchestrator (Go, ORCHESTRATOR_SERVICES=metering, METERING_INGEST=1)
#         │  INSERT … ON CONFLICT (idempotency_key) DO NOTHING
#         ▼
#   postgres  public.tenant_usage   ← the gate SELECTs the ground truth from here
#
# FROZEN CONTRACT (the storage-router MUST match usage.rs + migration 040 + the
# Go store — verified end-to-end here):
#   • stream key  : "usage.events"  (single stream; metric is a FIELD)
#   • entry fields: tenant_id, metric (storage.bytes), qty (int as string),
#                   ts (unix ms str), window_ms (str), idempotency_key
#                   (lower-hex sha256 "<tenant>|<metric>|<window_start_ms>")
#   • store       : public.tenant_usage(... idempotency_key PRIMARY KEY ...);
#                   INSERT … ON CONFLICT (idempotency_key) DO NOTHING.
#
# ISOLATED by design (mirrors m75): a scratch postgres + redis + minio +
# storage-router + Go orchestrator on a PRIVATE network, every container/image/
# network suffixed with $$, an EXIT-trap that removes EVERYTHING. It NEVER
# touches a mini-baas-* container/network/image/volume — safe while the live
# stack is up. The scratch postgres applies the migration-040 prelude then the
# REAL 040 so the migration itself is exercised.
#
#   (A) POSITIVE: STORAGE_METERING=1 storage-router uploads N=3 objects of KNOWN
#       sizes for ONE tenant T inside ONE window → after flush+ingest,
#       public.tenant_usage (T, storage.bytes) qty == SUM(the N sizes) — the
#       CUMULATIVE window total, NOT 1, NOT duplicated. This is the teeth: a
#       per-event (non-cumulative) emitter would store only the FIRST size and
#       fail the SUM assertion. qty is read from the STORE, never self-reported.
#   (B) PARITY:  STORAGE_METERING UNSET → the SAME N uploads still succeed (200)
#       but ZERO usage.events are produced (XLEN usage.events == 0) AND
#       public.tenant_usage stays EMPTY.
#
# Fails (exit≠0) on any wrong qty, missing row, or ANY stream entry / table row
# when OFF. Each fail names the exact assertion that tripped. Output is tee'd to
# artifacts/b1d/m77.txt.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                 # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                       # apps/baas
SRC_DIR="${INFRA_DIR}/src"                                      # storage-router build context
GO_DIR="${INFRA_DIR}/go/control-plane"
MIGRATION_040="${INFRA_DIR}/scripts/migrations/postgresql/040_tenant_usage.sql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/../.claude" 2>/dev/null && pwd || true)"
ART_DIR="${INFRA_DIR}/artifacts/b1d"
ART="${ART_DIR}/m77.txt"

mkdir -p "${ART_DIR}"
exec > >(tee "${ART}") 2>&1

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M77] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M77] FAIL — $*"; exit 1; }

PG_IMAGE="${M77_PG_IMAGE:-postgres:16-alpine}"
REDIS_IMAGE="${M77_REDIS_IMAGE:-redis:7-alpine}"
MINIO_IMAGE="${M77_MINIO_IMAGE:-minio/minio:RELEASE.2025-09-07T16-13-09Z-cpuv1}"
STOR_IMG="m77-stor-$$:scratch"
ORCH_IMG="m77-orch-$$:scratch"
NET="m77net-$$"
PG="m77-pg-$$"
REDIS="m77-redis-$$"
MINIO="m77-minio-$$"
STOR_ON="m77-stor-on-$$"      # (A) POSITIVE producer (STORAGE_METERING=1)
STOR_OFF="m77-stor-off-$$"    # (B) PARITY producer  (STORAGE_METERING unset)
ORCH_ON="m77-orch-on-$$"      # (A) ingest consumer  (METERING_INGEST=1)
ORCH_OFF="m77-orch-off-$$"    # (B) PARITY consumer  (METERING_INGEST unset)
PORT_ON="${M77_PORT_ON:-18991}"
PORT_OFF="${M77_PORT_OFF:-18992}"
PGPW="postgres"
MINIO_USER="minioadmin"
MINIO_PW="minioadmin"
BUCKET="m77b$$"
METRIC="storage.bytes"
TENANT="m77-tenant-$$"
FLUSH_MS="${M77_FLUSH_MS:-800}"
# Three KNOWN object sizes (bytes). Their SUM is the ground truth the stored qty
# MUST equal — distinct sizes so a partial sum can't accidentally match.
S1=111; S2=2222; S3=33333
SUM=$(( S1 + S2 + S3 ))
DATABASE_URL_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres?sslmode=disable"
REDIS_INNET="redis://${REDIS}:6379"
# shared.LoadConfig (Go orchestrator) refuses an empty/placeholder service token.
SVC_TOKEN="m77-scratch-service-token-$$-$(date +%s)"
# storage-router AuthGuard compat mode reads X-User-Id (legacy header) and
# X-Baas-Tenant-Id; we set both so the tenant dimension is a distinct value.
TMP="$(mktemp -d)"

cleanup() {
  docker rm -fv "${STOR_ON}" "${STOR_OFF}" "${ORCH_ON}" "${ORCH_OFF}" \
    "${MINIO}" "${PG}" "${REDIS}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${STOR_IMG}" "${ORCH_IMG}" >/dev/null 2>&1 || true
  rm -rf "${TMP}" 2>/dev/null || true
}
trap cleanup EXIT

psql_q()   { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
redis_cli(){ docker exec -i "${REDIS}" redis-cli "$@"; }

# Upload a KNOWN-size object as TENANT. $1=key  $2=size-bytes  $3=port → http code
upload() {
  local key="$1" size="$2" port="$3" file="${TMP}/$1.bin"
  mkdir -p "$(dirname "${file}")"
  head -c "${size}" /dev/zero > "${file}"
  curl -s -o /dev/null -w '%{http_code}' -X PUT \
    "http://127.0.0.1:${port}/storage/v1/object/${BUCKET}/${key}" \
    -H "X-User-Id: ${TENANT}" \
    -H "X-Baas-Tenant-Id: ${TENANT}" \
    -H "X-User-Role: authenticated" \
    -H 'Content-Type: application/octet-stream' \
    --data-binary @"${file}"
}

create_bucket() { # $1=port
  curl -s -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:$1/storage/v1/bucket/${BUCKET}" \
    -H "X-User-Id: ${TENANT}" -H "X-Baas-Tenant-Id: ${TENANT}" -H "X-User-Role: authenticated"
}

wait_http() { # $1=container  $2=port  $3=path
  local i
  for i in $(seq 1 80); do
    curl -fsS -o /dev/null "http://127.0.0.1:$2$3" 2>/dev/null && return 0
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -20; return 1; }
    sleep 0.5
  done
  red "$1 never became ready:"; docker logs "$1" 2>&1 | tail -20; return 1
}

wait_log() { # $1=container  $2=needle  $3=tries
  local i
  for i in $(seq 1 "${3:-40}"); do
    docker logs "$1" 2>&1 | grep -q "$2" && return 0
    docker inspect "$1" >/dev/null 2>&1 || return 1
    sleep 0.5
  done
  return 1
}

# Common storage-router env (S3 → scratch minio). $1 = "on"|"off" toggles the flag.
stor_env_args() {
  local mode="$1"
  set -- \
    -e PORT=3040 \
    -e IDENTITY_HEADER_MODE=compat \
    -e JWT_SECRET="m77-jwt-secret-$$" \
    -e S3_ENDPOINT="http://${MINIO}:9000" \
    -e S3_REGION=us-east-1 \
    -e S3_ACCESS_KEY="${MINIO_USER}" \
    -e S3_SECRET_KEY="${MINIO_PW}" \
    -e LOG_LEVEL=debug
  if [[ "${mode}" == "on" ]]; then
    set -- "$@" \
      -e STORAGE_METERING=1 \
      -e STORAGE_METERING_FLUSH_MS="${FLUSH_MS}" \
      -e STORAGE_METERING_REDIS_URL="${REDIS_INNET}"
  fi
  printf '%s\n' "$@"
}

# ── 0) build scratch storage-router + Go orchestrator FROM CURRENT source ───────
step "0/8 build scratch storage-router (TS) + Go orchestrator from CURRENT source"
DOCKER_BUILDKIT=1 docker build -q -f "${SRC_DIR}/Dockerfile" \
  --build-arg APP=storage-router -t "${STOR_IMG}" "${SRC_DIR}" >/dev/null \
  || fail "scratch storage-router image build failed — gate must exercise the drafted producer (line: docker build STOR)"
DOCKER_BUILDKIT=1 docker build -q \
  --build-arg APP=orchestrator --build-arg PORT=3021 \
  -t "${ORCH_IMG}" "${GO_DIR}" >/dev/null \
  || fail "scratch orchestrator image build failed — gate must exercise the B1b consumer (line: docker build ORCH)"
ok "both scratch images built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated network + redis + postgres (prelude + REAL migration 040) + minio
step "1/8 boot isolated net (${NET}): redis, postgres, minio"
docker network create "${NET}" >/dev/null
docker run -d --name "${REDIS}" --network "${NET}" "${REDIS_IMAGE}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
docker run -d --name "${MINIO}" --network "${NET}" \
  -e "MINIO_ROOT_USER=${MINIO_USER}" -e "MINIO_ROOT_PASSWORD=${MINIO_PW}" \
  "${MINIO_IMAGE}" server /data >/dev/null

for i in $(seq 1 60); do redis_cli PING 2>/dev/null | grep -q PONG && break; [[ $i -eq 60 ]] && fail "scratch redis never answered PING (line: redis ready)"; sleep 0.5; done
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "scratch postgres never reached steady state (line: PG ready loop)"
  sleep 0.5
done
ok "redis + postgres + minio up"

step "1b/8 apply migration-040 PRELUDE then the REAL 040"
prelude() {
  psql_q >/dev/null 2>&1 <<'SQL'
CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS text
  LANGUAGE sql STABLE AS $fn$ SELECT current_setting('request.tenant_id', true) $fn$;
DO $r$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role')  THEN CREATE ROLE service_role;  END IF;
END $r$;
SQL
}
for i in $(seq 1 20); do prelude && break; [[ $i -eq 20 ]] && fail "migration prelude never committed (line: prelude loop)"; sleep 0.5; done
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "${MIGRATION_040}" >/dev/null 2>&1 \
  || fail "real migration 040_tenant_usage.sql failed to apply (line: apply 040)"
APPLIED="$(psql_val "SELECT count(*) FROM public.tenant_usage")"
[[ "${APPLIED}" == "0" ]] || fail "tenant_usage should start EMPTY after migration, found '${APPLIED}' (line: 040 empty check)"
ok "migration 040 applied — public.tenant_usage exists and is empty"

# ── 2) start the ingest consumer (METERING_INGEST=1) ───────────────────────────
step "2/8 boot Go orchestrator (ORCHESTRATOR_SERVICES=metering, METERING_INGEST=1) — the consumer"
docker run -d --name "${ORCH_ON}" --network "${NET}" \
  -e DATABASE_URL="${DATABASE_URL_INNET}" \
  -e REDIS_URL="${REDIS_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e ORCHESTRATOR_SERVICES=metering \
  -e ORCHESTRATOR_PORT=3021 \
  -e METERING_ENABLED=1 \
  -e METERING_INGEST=1 \
  -e METERING_INGEST_BLOCK_MS=500 \
  -e LOG_LEVEL=debug \
  "${ORCH_IMG}" >/dev/null
wait_log "${ORCH_ON}" "metering ingest connected" 60 \
  || { red "consumer logs:"; docker logs "${ORCH_ON}" 2>&1 | tail -20; fail "ingest consumer never subscribed to usage.events (line: wait_log ORCH_ON connected)"; }
ok "ingest consumer subscribed to usage.events (group metering-ingest)"

# ── 3) (A) POSITIVE producer: storage-router metering ON ───────────────────────
step "3/8 boot storage-router STORAGE_METERING=1 (flush=${FLUSH_MS}ms) → scratch redis (A)"
mapfile -t ON_ENV < <(stor_env_args on)
docker run -d --name "${STOR_ON}" --network "${NET}" \
  "${ON_ENV[@]}" -p "127.0.0.1:${PORT_ON}:3040" "${STOR_IMG}" >/dev/null
wait_http "${STOR_ON}" "${PORT_ON}" "/health/live" || fail "POSITIVE storage-router not ready (line: wait_http STOR_ON)"
ok "POSITIVE storage-router up (metering ON, durable XADD → scratch redis) on 127.0.0.1:${PORT_ON}"

step "3b/8 create bucket + upload N=3 KNOWN-size objects (${S1}+${S2}+${S3}=${SUM} bytes) for ONE tenant in ONE window"
bc="$(create_bucket "${PORT_ON}")"
[[ "${bc}" == "200" || "${bc}" == "201" ]] || fail "createBucket expected 200/201, got ${bc} (line: A create bucket)"
# Fire all three uploads back-to-back so they land inside one flush window → ONE
# idempotency_key → the stored qty MUST be the SUM (cumulative), not 1.
c1="$(upload o1 "${S1}" "${PORT_ON}")"; c2="$(upload o2 "${S2}" "${PORT_ON}")"; c3="$(upload o3 "${S3}" "${PORT_ON}")"
[[ "${c1}" == "200" && "${c2}" == "200" && "${c3}" == "200" ]] \
  || fail "POSITIVE uploads expected 200/200/200, got ${c1}/${c2}/${c3} (line: A upload status)"
ok "3 objects uploaded (200×3); known total ${SUM} bytes for tenant=${TENANT}"

# ── 4) (A) wait past flush+ingest, then ASSERT tenant_usage qty == SUM ─────────
step "4/8 wait flush(${FLUSH_MS}ms)+ingest, then ASSERT public.tenant_usage (T, storage.bytes) qty == ${SUM}"
GOT=0
for i in $(seq 1 60); do
  GOT="$(psql_val "SELECT count(*) FROM public.tenant_usage WHERE tenant_id='${TENANT}' AND metric='${METRIC}'")"
  [[ "${GOT}" -ge 1 ]] && break
  sleep 0.5
done
[[ "${GOT}" -ge 1 ]] \
  || fail "no tenant_usage row after ingest — stream depth=$(redis_cli XLEN usage.events), consumer tail: $(docker logs "${ORCH_ON}" 2>&1 | tail -5) (line: A no row)"

# Read the stored qty from the STORE (never self-reported). Sum across any rows
# for this (tenant, metric) — within one window there is exactly one, and the
# cumulative qty MUST equal the byte SUM. A per-event emitter would store S1 (the
# first event) and this assertion would trip.
STORED_QTY="$(psql_val "SELECT COALESCE(SUM(qty),0) FROM public.tenant_usage WHERE tenant_id='${TENANT}' AND metric='${METRIC}'")"
[[ "${STORED_QTY}" == "${SUM}" ]] \
  || fail "(A) storage.bytes qty=${STORED_QTY} != SUM of the ${S1}+${S2}+${S3}=${SUM} known sizes — a per-event (non-cumulative) emitter would store ${S1}, not the sum (line: A qty != SUM)"
ROWS_CNT="$(psql_val "SELECT count(*) FROM public.tenant_usage WHERE tenant_id='${TENANT}' AND metric='${METRIC}'")"
ok "(A) tenant_usage (${TENANT}, ${METRIC}) qty=${STORED_QTY} == SUM(${S1},${S2},${S3})=${SUM} across ${ROWS_CNT} window row(s) — CUMULATIVE, from the store"

# ── 5) (B) PARITY: STORAGE_METERING unset → ZERO usage.events, EMPTY table ──────
step "5/8 (B) PARITY — STORAGE_METERING UNSET: identical uploads succeed but emit NOTHING"
# Stop the ON producer + the consumer; wipe the stream + table so this arm starts
# clean and a leftover row can't masquerade as either result.
docker rm -fv "${STOR_ON}" "${ORCH_ON}" >/dev/null 2>&1 || true
redis_cli DEL usage.events >/dev/null 2>&1 || true
psql_q -c "TRUNCATE public.tenant_usage" >/dev/null 2>&1 || fail "could not truncate tenant_usage for B (line: B truncate)"
EMPTY0="$(psql_val "SELECT count(*) FROM public.tenant_usage")"
[[ "${EMPTY0}" == "0" ]] || fail "(B) table not empty at start, found ${EMPTY0} (line: B start empty)"

# A consumer is STILL running (METERING_INGEST=1) so that if the OFF producer DID
# leak any entry it would be ingested — making the empty-table result load-bearing.
docker run -d --name "${ORCH_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DATABASE_URL_INNET}" \
  -e REDIS_URL="${REDIS_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e ORCHESTRATOR_SERVICES=metering \
  -e ORCHESTRATOR_PORT=3021 \
  -e METERING_ENABLED=1 -e METERING_INGEST=1 -e METERING_INGEST_BLOCK_MS=500 \
  -e LOG_LEVEL=debug \
  "${ORCH_IMG}" >/dev/null
wait_log "${ORCH_OFF}" "metering ingest connected" 60 \
  || fail "(B) watchdog consumer never subscribed (line: B consumer connect)"

# PARITY producer: STORAGE_METERING UNSET (the default).
mapfile -t OFF_ENV < <(stor_env_args off)
docker run -d --name "${STOR_OFF}" --network "${NET}" \
  "${OFF_ENV[@]}" -p "127.0.0.1:${PORT_OFF}:3040" "${STOR_IMG}" >/dev/null
wait_http "${STOR_OFF}" "${PORT_OFF}" "/health/live" || fail "(B) PARITY storage-router not ready (line: B wait_http)"
bc="$(create_bucket "${PORT_OFF}")"
[[ "${bc}" == "200" || "${bc}" == "201" ]] || fail "(B) createBucket expected 200/201, got ${bc} (line: B create bucket)"
c1="$(upload o1 "${S1}" "${PORT_OFF}")"; c2="$(upload o2 "${S2}" "${PORT_OFF}")"; c3="$(upload o3 "${S3}" "${PORT_OFF}")"
[[ "${c1}" == "200" && "${c2}" == "200" && "${c3}" == "200" ]] \
  || fail "(B) uploads must STILL succeed with metering OFF, got ${c1}/${c2}/${c3} (line: B upload status)"
ok "(B) identical 3 uploads succeeded (200×3) with STORAGE_METERING unset"

# Wait several flush windows; a metering-OFF storage-router never constructs the
# meter, never spawns the interval, never XADDs. The stream MUST stay at depth 0
# and the table MUST stay empty.
sleep "$(awk "BEGIN{printf \"%.1f\", ${FLUSH_MS}/1000*5 + 2}")"
SDEPTH_OFF="$(redis_cli XLEN usage.events 2>/dev/null | tr -d '[:space:]')"
[[ "${SDEPTH_OFF:-0}" == "0" ]] \
  || fail "(B) PARITY BROKEN — metering-OFF storage-router XADDed ${SDEPTH_OFF} usage.events (expected 0) (line: B XLEN != 0)"
PARITY_ROWS="$(psql_val "SELECT count(*) FROM public.tenant_usage")"
[[ "${PARITY_ROWS}" == "0" ]] \
  || fail "(B) PARITY BROKEN — ${PARITY_ROWS} tenant_usage row(s) with STORAGE_METERING unset (line: B rows != 0)"
ok "(B) STORAGE_METERING unset → XLEN usage.events == 0 AND tenant_usage EMPTY = byte-parity"

# ── 6) cross-check + done ──────────────────────────────────────────────────────
step "6/8 cross-check: ON summed N writes into one window row; OFF emitted nothing"
green "[M77] (A) storage upload → usage.events → consumer → tenant_usage: (${TENANT}, ${METRIC}) qty=${SUM} == SUM(${S1},${S2},${S3}) [CUMULATIVE, one window]"
green "[M77] (B) STORAGE_METERING unset → identical uploads, ZERO usage.events, EMPTY tenant_usage"

# ── 7) emit the gate event via the kernel log helper (best-effort) ─────────────
step "7/8 log GATE m77=PASS"
emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-b1d-storage}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m77=PASS" --outcome pass \
      --msg "B1d storage-router storage.bytes: N=3 uploads in one window -> tenant_usage qty == SUM(sizes) cumulative; STORAGE_METERING off -> 0 usage.events + empty table (byte-parity)" \
      --ref "scripts/verify/m77-metering-storage.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

step "8/8 all B1d-storage assertions hold"
green "[M77] ALL GATES GREEN — storage-router emits cumulative-per-window storage.bytes through the FROZEN usage.events contract; byte-parity when STORAGE_METERING is OFF"
exit 0
