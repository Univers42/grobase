#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m78-metering-realtime.sh                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M78 — Track-B metering B1d end-to-end gate for the REALTIME plane. Proves the
# realtime-gateway emits `realtime.connection.seconds` on WS connection CLOSE,
# aggregates it CUMULATIVELY per (tenant, metric) into a windowed counter, and
# the background flusher XADDs the FROZEN usage envelope to the single Redis
# stream `usage.events` — which the Go control-plane consumer (METERING_INGEST)
# idempotently UPSERTs into public.tenant_usage. It also proves byte-parity when
# the REALTIME_METERING sub-flag is OFF.
#
# This gate exercises the COMPLETE producer/consumer boundary, both planes built
# FROM CURRENT SOURCE, and drives the REAL public WS endpoint (no stub):
#   realtime-server   (Rust, REALTIME_METERING=1, flush=6000ms, redis XADD)
#         │  on WS CLOSE: record lifetime_secs → aggregate(tenant, metric) +=
#         │  flusher: XADD usage.events {tenant_id, metric=realtime.connection.seconds,
#         ▼            qty, ts, window_ms, idempotency_key=sha256("tenant|metric|window")}
#   redis  (the single `usage.events` stream)
#         │  XREADGROUP (consumer group "metering-ingest")
#         ▼
#   orchestrator  (Go, ORCHESTRATOR_SERVICES=metering, METERING_INGEST=1)
#         │  INSERT … ON CONFLICT (idempotency_key) DO NOTHING  (AdminExec)
#         ▼
#   postgres  public.tenant_usage   ← the gate SELECTs the ground truth from here
#
# FROZEN CONTRACT (shared with the data-plane producer, verified end-to-end):
#   • stream key  : "usage.events"  (single stream; metric is a FIELD)
#   • entry fields: tenant_id, metric, qty (int str), ts (unix ms str),
#                   window_ms (str), idempotency_key
#                   (lower-hex sha256 "<tenant>|<metric>|<window_start_ms>",
#                   window_start_ms = ts - (ts mod window_ms))
#   • store       : public.tenant_usage(tenant_id, metric, window_start, qty,
#                   idempotency_key PRIMARY KEY, updated_at). Idempotent ingest:
#                   INSERT … ON CONFLICT (idempotency_key) DO NOTHING.
#
# ISOLATED by design (mirrors m75): a scratch postgres + redis + realtime-server
# + Go orchestrator on a PRIVATE network, every container/image/network name
# suffixed with $$, an EXIT-trap that removes EVERYTHING. It NEVER touches a
# mini-baas-* container/network/image/volume nor the live docker-compose.yml.
#
# The scratch postgres applies a MINIMAL prelude (the objects migration 040
# references) then the REAL migration 040_tenant_usage.sql — so the gate also
# proves that migration applies cleanly.
#
#   (A) POSITIVE — N=3 real WS connections for tenant T of KNOWN durations
#       (D1=3s, D2=4s, D3=5s) are opened CONCURRENTLY and close within ONE flush
#       window. The CUMULATIVE total flushes ONCE (NOT 3 rows): SELECT from
#       tenant_usage MUST show metric=realtime.connection.seconds with
#       qty == D1+D2+D3 == 12 (asserted against the independently-known sum, with
#       an explicit ±1s-per-connection rounding tolerance ⇒ ±3 total). The N>=3-
#       events-sum-in-ONE-window property is the whole point: a per-event emit
#       would split into 3 idempotency_keys (or share one key and undercount),
#       so qty==12 (not 1, not duplicated) proves cumulative aggregation.
#   (B) PARITY — REALTIME_METERING UNSET, a FRESH stream + a fresh (truncated)
#       table, the SAME open/close traffic ⇒ XLEN usage.events == 0 AND
#       tenant_usage stays EMPTY (the producer is silent, no flusher spawned).
#
# Fails (exit≠0) on a wrong qty, a missing row, multiple rows for the metric, or
# ANY stream entry / table row when OFF. Each fail names the assertion that
# tripped. Output is tee'd to artifacts/b1d/m78.txt.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                 # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                       # apps/baas
RT_DIR="${INFRA_DIR}/docker/services/realtime/realtime-agnostic"
GO_DIR="${INFRA_DIR}/go/control-plane"
MIGRATION_040="${INFRA_DIR}/scripts/migrations/postgresql/040_tenant_usage.sql"
LOG_SH="${BAAS_DIR}/.claude/lib/log.sh"
ART_DIR="${INFRA_DIR}/artifacts/b1d"
ART="${ART_DIR}/m78.txt"

mkdir -p "${ART_DIR}"
exec > >(tee "${ART}") 2>&1

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M78] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M78] FAIL — $*"; exit 1; }

PG_IMAGE="${M78_PG_IMAGE:-postgres:16-alpine}"
REDIS_IMAGE="${M78_REDIS_IMAGE:-redis:7-alpine}"
NODE_IMAGE="${M78_NODE_IMAGE:-node:20-bookworm-slim}"
RT_IMG="m78-rt-$$:scratch"
ORCH_IMG="m78-orch-$$:scratch"
NET="m78net-$$"
PG="m78-pg-$$"
REDIS="m78-redis-$$"
RT_ON="m78-rt-on-$$"        # (A) POSITIVE producer (REALTIME_METERING=1)
RT_OFF="m78-rt-off-$$"      # (B) PARITY producer  (REALTIME_METERING unset)
ORCH_ON="m78-orch-on-$$"    # (A) ingest consumer (METERING_INGEST=1)
PGPW="postgres"
TENANT="m78-tenant-$$"
METRIC="realtime.connection.seconds"
# N=3 connection durations (seconds) — KNOWN truth; sum is the expected qty.
D1=3; D2=4; D3=5
SUM=$((D1 + D2 + D3))                       # 12
TOL=3                                       # ±1s per connection rounding (N=3)
# Flush window WIDER than the longest connection so all 3 closes drain in ONE
# flush ⇒ one cumulative row, one idempotency_key bucket.
FLUSH_MS="${M78_FLUSH_MS:-6000}"
RT_PORT_ON="${M78_PORT_ON:-19090}"
RT_PORT_OFF="${M78_PORT_OFF:-19091}"
REDIS_INNET="redis://${REDIS}:6379"
DATABASE_URL_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres?sslmode=disable"
SVC_TOKEN="m78-scratch-service-token-$$-$(date +%s)"
# Zero-dependency WS client (RFC 6455 over node:net + node:crypto) so the gate
# needs NO npm install / network egress — written to a temp file, mounted into a
# stock node image read-only. It drives the REAL /ws endpoint (handshake, AUTH,
# hold, CLOSE) — the genuine close path, not a stub.
WSCLIENT="$(mktemp --suffix=.js)"

cleanup() {
  docker rm -fv "${RT_ON}" "${RT_OFF}" "${ORCH_ON}" "${PG}" "${REDIS}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${RT_IMG}" "${ORCH_IMG}" >/dev/null 2>&1 || true
  rm -f "${WSCLIENT}" 2>/dev/null || true
}
trap cleanup EXIT

cat > "${WSCLIENT}" <<'JS'
// Zero-dependency WebSocket client (RFC 6455) over node:net — no npm needed.
// Opens N connections concurrently, AUTHs (token == the metered tenant, since
// NoAuth sets claims.sub = token), holds each open `dur` seconds, then sends a
// masked CLOSE frame — exercising the REAL gateway close path that meters
// realtime.connection.seconds. Prints WS_CONNS_CLOSED when ALL have closed.
const net = require("net");
const crypto = require("crypto");
const host = process.env.RT_HOST, token = process.env.TOKEN;
const durs = process.env.DURS.trim().split(/\s+/).map(Number);
function maskFrame(text) {
  const payload = Buffer.from(text, "utf8");
  const len = payload.length; // small JSON, < 126
  const mask = crypto.randomBytes(4);
  const head = Buffer.from([0x81, 0x80 | len]);
  const masked = Buffer.alloc(len);
  for (let i = 0; i < len; i++) masked[i] = payload[i] ^ mask[i % 4];
  return Buffer.concat([head, mask, masked]);
}
function closeFrame() { // masked close, code 1000
  const mask = crypto.randomBytes(4);
  const body = Buffer.from([0x03, 0xe8]);
  const masked = Buffer.alloc(2);
  for (let i = 0; i < 2; i++) masked[i] = body[i] ^ mask[i % 4];
  return Buffer.concat([Buffer.from([0x88, 0x82]), mask, masked]);
}
function oneConn(durSec) {
  return new Promise((resolve, reject) => {
    const key = crypto.randomBytes(16).toString("base64");
    const sock = net.connect(4000, host, () => {
      sock.write(
        "GET /ws HTTP/1.1\r\nHost: " + host + "\r\nUpgrade: websocket\r\n" +
        "Connection: Upgrade\r\nSec-WebSocket-Key: " + key +
        "\r\nSec-WebSocket-Version: 13\r\n\r\n");
    });
    let handshook = false;
    sock.on("data", (buf) => {
      if (!handshook && buf.toString("latin1").includes("101")) {
        handshook = true;
        sock.write(maskFrame(JSON.stringify({ type: "AUTH", token })));
        setTimeout(() => { sock.write(closeFrame()); sock.end(); }, durSec * 1000);
      }
    });
    sock.on("close", () => resolve());
    sock.on("error", (e) => reject(e));
  });
}
(async () => {
  await Promise.all(durs.map(oneConn));
  console.log("WS_CONNS_CLOSED " + durs.join(","));
})().catch((e) => { console.error("WS_ERR", e.message); process.exit(1); });
JS

psql_q()   { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
redis_cli(){ docker exec -i "${REDIS}" redis-cli "$@"; }

# Drive N real WS connections of the given durations against the realtime-server
# at ws://<host>:4000/ws, IN-NETWORK via a one-shot stock node container running
# the zero-dependency RFC-6455 client (mounted read-only — no npm, no network
# egress). Each connection: AUTH (token == TENANT ⇒ claims.sub == TENANT, the
# metered tenant), hold open `dur` seconds, then send a real CLOSE frame. Runs
# CONCURRENTLY so all closes land inside one flush window. This drives the REAL
# public WS endpoint — no stub of the emit path.
drive_ws() { # $1=rt_container  $2="d1 d2 d3"
  local rt="$1"; shift
  local durs="$*"
  docker run --rm --network "${NET}" \
    -e RT_HOST="${rt}" -e DURS="${durs}" -e TOKEN="${TENANT}" \
    -v "${WSCLIENT}":/wsclient.js:ro \
    "${NODE_IMAGE}" node /wsclient.js
}

wait_http() { # $1=container  $2=port  $3=path
  local i
  for i in $(seq 1 60); do
    curl -fsS -o /dev/null "http://127.0.0.1:$2$3" 2>/dev/null && return 0
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -15; return 1; }
    sleep 0.5
  done
  red "$1 never became ready:"; docker logs "$1" 2>&1 | tail -15; return 1
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

# ── 0) build BOTH scratch images FROM CURRENT SOURCE ───────────────────────────
step "0/8 build scratch realtime-server + Go orchestrator from CURRENT source (B1d)"
DOCKER_BUILDKIT=1 docker build -q -f "${RT_DIR}/Dockerfile" -t "${RT_IMG}" "${RT_DIR}" >/dev/null \
  || fail "scratch realtime-server image build failed — gate must exercise the drafted producer (line: docker build RT)"
DOCKER_BUILDKIT=1 docker build -q \
  --build-arg APP=orchestrator --build-arg PORT=3021 \
  -t "${ORCH_IMG}" "${GO_DIR}" >/dev/null \
  || fail "scratch orchestrator image build failed — gate must exercise the drafted consumer (line: docker build ORCH)"
ok "both scratch images built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated network + redis + postgres (prelude + REAL migration 040) ──────
step "1/8 boot isolated network (${NET}), redis (${REDIS}), postgres (${PG})"
docker network create "${NET}" >/dev/null
docker run -d --name "${REDIS}" --network "${NET}" "${REDIS_IMAGE}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null

for i in $(seq 1 60); do redis_cli PING 2>/dev/null | grep -q PONG && break; [[ $i -eq 60 ]] && fail "scratch redis never answered PING (line: redis ready)"; sleep 0.5; done
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "scratch postgres never reached post-init steady state (line: PG ready loop)"
  sleep 0.5
done
ok "redis + postgres up"

step "1b/8 apply the migration-040 PRELUDE then the REAL 040"
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
[[ "${APPLIED}" == "0" ]] || fail "tenant_usage should start EMPTY, found '${APPLIED}' (line: 040 empty check)"
MIG="$(psql_val "SELECT version FROM public.schema_migrations WHERE version=40")"
[[ "${MIG}" == "40" ]] || fail "migration 040 did not record version=40 (line: 040 recorded)"
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

# ── 3) (A) POSITIVE producer: realtime-server with metering ON ─────────────────
step "3/8 boot realtime-server REALTIME_METERING=1 (flush=${FLUSH_MS}ms) → scratch redis (A)"
docker run -d --name "${RT_ON}" --network "${NET}" \
  -e REALTIME_METERING=1 \
  -e REALTIME_METERING_REDIS_URL="${REDIS_INNET}" \
  -e REALTIME_METERING_FLUSH_MS="${FLUSH_MS}" \
  -e REALTIME_PORT=4000 \
  -e RUST_LOG=info \
  -p "127.0.0.1:${RT_PORT_ON}:4000" "${RT_IMG}" >/dev/null
wait_http "${RT_ON}" "${RT_PORT_ON}" "/v1/health" || fail "POSITIVE realtime-server not ready (line: wait_http RT_ON)"
docker logs "${RT_ON}" 2>&1 | grep -q "realtime metering ON" \
  || { red "RT_ON logs:"; docker logs "${RT_ON}" 2>&1 | tail -15; fail "realtime-server did not announce metering ON (line: RT_ON metering log)"; }
ok "POSITIVE realtime-server up (metering ON, durable XADD → scratch redis) on 127.0.0.1:${RT_PORT_ON}"

step "3b/8 open+close N=3 real WS connections for tenant=${TENANT} of durations ${D1}s,${D2}s,${D3}s"
OUT="$(drive_ws "${RT_ON}" "${D1} ${D2} ${D3}")" \
  || { red "ws driver output:"; echo "${OUT}"; fail "WS driver failed to open/close the connections (line: drive_ws A)"; }
echo "${OUT}" | grep -q "WS_CONNS_CLOSED" \
  || { red "ws driver output:"; echo "${OUT}"; fail "WS driver did not confirm all connections closed (line: drive_ws A confirm)"; }
docker logs "${RT_ON}" 2>&1 | grep -c "metered realtime.connection.seconds" >/dev/null
METERED="$(docker logs "${RT_ON}" 2>&1 | grep -c "metered realtime.connection.seconds" || true)"
[[ "${METERED}" -ge 3 ]] \
  || { red "RT_ON logs:"; docker logs "${RT_ON}" 2>&1 | tail -20; fail "expected ≥3 close-path metering records, saw ${METERED} (line: METERED < 3)"; }
ok "all 3 WS connections opened, held their durations, and closed via the REAL close path (${METERED} metered)"

# ── 4) (A) wait past flush+ingest, then ASSERT tenant_usage from the STORE ─────
step "4/8 wait flush(${FLUSH_MS}ms) + ingest, then ASSERT public.tenant_usage from the STORE"
GOT=0
for i in $(seq 1 60); do
  GOT="$(psql_val "SELECT count(*) FROM public.tenant_usage WHERE tenant_id='${TENANT}' AND metric='${METRIC}'")"
  [[ "${GOT:-0}" -ge 1 ]] && break
  sleep 0.5
done
[[ "${GOT:-0}" -ge 1 ]] \
  || fail "no tenant_usage row for ${METRIC} after ingest — stream depth=$(redis_cli XLEN usage.events), consumer tail: $(docker logs "${ORCH_ON}" 2>&1 | tail -5) (line: GOT < 1)"

# CRITICAL: exactly ONE row for (tenant, metric) — the N>=3 events for one tenant
# in one window MUST collapse to a single cumulative row, never N rows.
ROWS="$(psql_val "SELECT count(*) FROM public.tenant_usage WHERE tenant_id='${TENANT}' AND metric='${METRIC}'")"
[[ "${ROWS}" == "1" ]] \
  || fail "(A) expected EXACTLY 1 cumulative row for ${METRIC} (N events in one window), found ${ROWS} — per-event emit would split/undercount (line: A ROWS != 1)"

QTY="$(psql_val "SELECT qty FROM public.tenant_usage WHERE tenant_id='${TENANT}' AND metric='${METRIC}'")"
LO=$((SUM - TOL)); HI=$((SUM + TOL))
[[ -n "${QTY}" && "${QTY}" -ge "${LO}" && "${QTY}" -le "${HI}" ]] \
  || fail "(A) ${METRIC} qty=${QTY} not within SUM(${D1}+${D2}+${D3})=${SUM} ±${TOL} [${LO}..${HI}] — cumulative window total must equal the SUM of the N durations (line: A qty != SUM)"
ok "(A) tenant_usage ${METRIC} qty=${QTY} == SUM ${SUM} (±${TOL}s rounding) in ONE row — cumulative window proven"
green "[M78] (A) POSITIVE: 3 WS connections (${D1}s+${D2}s+${D3}s=${SUM}s) → 1 usage.events window → 1 tenant_usage row qty=${QTY}"

# ── 5) (B) PARITY: REALTIME_METERING unset → ZERO stream entries + EMPTY table ──
step "5/8 (B) PARITY — tear down ON arm, wipe stream + truncate table, start metering-OFF producer"
docker rm -fv "${RT_ON}" >/dev/null 2>&1 || true
redis_cli DEL usage.events >/dev/null 2>&1 || true
psql_q -c "TRUNCATE public.tenant_usage" >/dev/null 2>&1 || fail "could not truncate tenant_usage for B (line: B truncate)"
EMPTY0="$(psql_val "SELECT count(*) FROM public.tenant_usage")"
[[ "${EMPTY0}" == "0" ]] || fail "(B) table not empty at start, found ${EMPTY0} (line: B start empty)"
SDEPTH0="$(redis_cli XLEN usage.events 2>/dev/null | tr -d '[:space:]')"
[[ "${SDEPTH0:-0}" == "0" ]] || fail "(B) stream not empty at start, depth ${SDEPTH0} (line: B start stream empty)"

docker run -d --name "${RT_OFF}" --network "${NET}" \
  -e REALTIME_PORT=4000 \
  -e RUST_LOG=info \
  -p "127.0.0.1:${RT_PORT_OFF}:4000" "${RT_IMG}" >/dev/null
wait_http "${RT_OFF}" "${RT_PORT_OFF}" "/v1/health" || fail "(B) PARITY realtime-server not ready (line: wait_http RT_OFF)"
# With the sub-flag OFF the server must NOT announce metering ON.
docker logs "${RT_OFF}" 2>&1 | grep -q "realtime metering ON" \
  && fail "(B) realtime-server announced metering ON with REALTIME_METERING unset — NOT parity (line: B metering-on leak)"
ok "(B) realtime-server up with REALTIME_METERING unset (no metering announce) on 127.0.0.1:${RT_PORT_OFF}"

step "5b/8 (B) run the IDENTICAL open/close traffic against the OFF producer"
OUT_OFF="$(drive_ws "${RT_OFF}" "${D1} ${D2} ${D3}")" \
  || { red "ws driver output:"; echo "${OUT_OFF}"; fail "(B) WS driver failed (line: drive_ws B)"; }
echo "${OUT_OFF}" | grep -q "WS_CONNS_CLOSED" \
  || fail "(B) WS driver did not confirm all connections closed (line: drive_ws B confirm)"
ok "(B) same 3 connections opened+closed against the metering-OFF server"

step "5c/8 (B) wait several flush windows; ASSERT ZERO usage.events AND empty table"
# A metering-OFF server never spawns the flusher and never opens a Redis conn, so
# the stream MUST stay empty for identical traffic. Wait > one window + slack.
sleep "$(awk "BEGIN{printf \"%.1f\", ${FLUSH_MS}/1000 + 4}")"
SDEPTH_OFF="$(redis_cli XLEN usage.events 2>/dev/null | tr -d '[:space:]')"
[[ "${SDEPTH_OFF:-0}" == "0" ]] \
  || fail "(B) PARITY BROKEN — metering-OFF server XADDed ${SDEPTH_OFF} usage.events (expected 0) (line: B SDEPTH != 0)"
PARITY_ROWS="$(psql_val "SELECT count(*) FROM public.tenant_usage")"
[[ "${PARITY_ROWS}" == "0" ]] \
  || fail "(B) PARITY BROKEN — ${PARITY_ROWS} tenant_usage row(s) with REALTIME_METERING unset (line: B PARITY_ROWS != 0)"
ok "(B) REALTIME_METERING unset → identical open/close produced ZERO usage.events + EMPTY table = byte-parity"

# ── 6) cross-check + done ──────────────────────────────────────────────────────
step "6/8 cross-check the two arms"
green "[M78] (A) realtime CLOSE → usage.events → consumer → tenant_usage: ${METRIC} qty=${QTY} (== SUM ${SUM} ±${TOL}) in ONE row for tenant=${TENANT}"
green "[M78] (B) REALTIME_METERING unset → ZERO usage.events + empty table for identical WS traffic"

step "7/8 all B1d realtime metering assertions hold"
green "[M78] ALL GATES GREEN — realtime.connection.seconds is metered cumulatively, ingested end-to-end, and byte-parity when OFF"

step "8/8 record PASS to the agent log"
if [[ -f "${LOG_SH}" ]]; then
  # shellcheck disable=SC1090
  ( . "${LOG_SH}" \
      && AGENT_ROLE="tester" AGENT_TASK="m78-metering-realtime" \
         log_event REPORT --outcome PASS --gate m78=PASS \
         --ref "scripts/verify/m78-metering-realtime.sh" \
         --msg "B1d realtime.connection.seconds: 3 WS connections (${SUM}s) → 1 cumulative tenant_usage row qty=${QTY}; OFF=byte-parity (0 stream, empty table)" \
  ) 2>/dev/null || red "[M78] (note) log.sh helper present but log_event failed — gate result still PASS"
else
  red "[M78] (note) ${LOG_SH} not found — skipping agent-log PASS record (gate result still PASS)"
fi
green "[M78] DONE"
