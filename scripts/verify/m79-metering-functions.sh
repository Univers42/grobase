#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m79-metering-functions.sh                          :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M79 — Track-B metering B1d end-to-end gate for the FUNCTIONS RUNTIME producer.
# Proves that a SUCCESSFUL edge-function invocation emits the metric
# "function.invocations" onto the FROZEN single Redis stream `usage.events`
# (windowed CUMULATIVE total — node:crypto sha256 envelope, byte-identical to the
# Rust data plane's usage.rs) and that the Go control-plane consumer
# (METERING_INGEST) idempotently UPSERTs it into public.tenant_usage — and that
# the whole thing is byte-parity when the FUNCTION_METERING sub-flag is OFF.
#
# Built FROM CURRENT SOURCE, all on a PRIVATE network, every name suffixed $$:
#   functions-runtime  (Deno, FUNCTION_METERING=1, small flush, REDIS_URL=scratch)
#         │  on EACH successful invoke: meter.record(tenant,function.invocations,1)
#         │  flusher every flush_ms: XADD usage.events {tenant_id, metric, qty,
#         ▼                          ts, window_ms, idempotency_key=sha256(...)}
#   redis  (the single `usage.events` stream)
#         │  XREADGROUP (consumer group "metering-ingest")
#         ▼
#   orchestrator  (Go, ORCHESTRATOR_SERVICES=metering, METERING_INGEST=1)
#         │  INSERT … ON CONFLICT (idempotency_key) DO NOTHING  (AdminExec)
#         ▼
#   postgres  public.tenant_usage   ← the gate SELECTs the ground truth from here
#
# FROZEN CONTRACT (the producer MUST match — verified end-to-end here):
#   • stream key  : "usage.events"  (single stream; metric is a FIELD)
#   • entry fields: tenant_id, metric (function.invocations), qty (int as string),
#                   ts (unix ms str), window_ms (str), idempotency_key
#                   (lower-hex sha256 "<tenant>|<metric>|<window_start_ms>",
#                   window_start_ms = ts - (ts mod window_ms))
#   • store       : public.tenant_usage(..., idempotency_key PRIMARY KEY); ingest
#                   INSERT … ON CONFLICT (idempotency_key) DO NOTHING.
#
# CRITICAL — windowed CUMULATIVE, not per-event. The POSITIVE arm invokes the
# SAME function N>=3 times for ONE tenant INSIDE ONE flush window. A correct
# producer flushes ONE cumulative window total (qty==N), NOT N entries that share
# one idempotency_key (which the consumer's DO NOTHING would collapse to qty==1).
# The gate asserts the STORED qty == N — proving the aggregation, not a single
# event. A long flush window (FLUSH_MS) makes "inside one window" deterministic:
# all N invokes land before the first flush.
#
#   (A) POSITIVE: FUNCTION_METERING=1 → invoke N times in one window →
#       tenant_usage(T, function.invocations).qty == N (read from the STORE).
#   (B) PARITY:   FUNCTION_METERING unset → identical N invokes → ZERO
#       usage.events on the stream (XLEN==0) AND public.tenant_usage EMPTY.
#
# Fails (exit!=0) on a wrong qty, a missing row, or ANY row/stream entry when OFF.
# ISOLATED: a scratch postgres + redis + functions-runtime + Go orchestrator on a
# PRIVATE network; an EXIT-trap removes EVERYTHING. NEVER touches a mini-baas-*
# container/network/image/volume. Output is tee'd to artifacts/b1d/m79.txt.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                  # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                       # apps/baas
FN_DIR="${INFRA_DIR}/docker/services/functions-runtime"
GO_DIR="${INFRA_DIR}/go/control-plane"
MIGRATION_040="${INFRA_DIR}/scripts/migrations/postgresql/040_tenant_usage.sql"
LOG_HELPER="${BAAS_DIR}/.claude/lib/log.sh"
ART_DIR="${INFRA_DIR}/artifacts/b1d"
ART="${ART_DIR}/m79.txt"

mkdir -p "${ART_DIR}"
exec > >(tee "${ART}") 2>&1

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M79] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M79] FAIL — $*"; exit 1; }

PG_IMAGE="${M79_PG_IMAGE:-postgres:16-alpine}"
REDIS_IMAGE="${M79_REDIS_IMAGE:-redis:7-alpine}"
FN_IMG="m79-fn-$$:scratch"
ORCH_IMG="m79-orch-$$:scratch"
NET="m79net-$$"
PG="m79-pg-$$"
REDIS="m79-redis-$$"
FN_ON="m79-fn-on-$$"          # (A) POSITIVE producer (metering ON)
FN_OFF="m79-fn-off-$$"        # (B) PARITY producer  (metering unset)
ORCH_ON="m79-orch-on-$$"      # (A) ingest consumer (METERING_INGEST=1)
PORT_ON="${M79_PORT_ON:-18991}"
PORT_OFF="${M79_PORT_OFF:-18992}"
PGPW="postgres"
TENANT="m79-tenant-$$"
FNNAME="ping"
N=4                          # invocations in ONE window → expected qty (>=3)
# Flush window. After a flush the aggregator entry is DRAINED to zero (the meter
# clears the Map), so a "reset" between the warm-up and the measured run needs NO
# restart — just wait one window for the warm-up to flush, then clear the stream
# + table. The measured N then start from a zeroed in-memory counter and land in
# ONE fresh window (warm invokes are ~20-40ms, far under the window).
FLUSH_MS="${M79_FLUSH_MS:-2000}"
# Generous invoke timeout so the COLD first invoke (Worker spin-up + module
# compile, no warm pool yet — see the Dockerfile) returns 200 instead of timing
# out. The MEASURED invokes run after a warm-up, so they are all fast/warm.
INVOKE_TIMEOUT_MS="${M79_INVOKE_TIMEOUT_MS:-20000}"
DATABASE_URL_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres?sslmode=disable"
REDIS_INNET="redis://${REDIS}:6379"
# shared.LoadConfig refuses an empty / placeholder INTERNAL_SERVICE_TOKEN; a
# strong scratch-only value satisfies the guard (the metering consumer mounts no
# token-protected routes, so any strong value works for this isolated gate).
SVC_TOKEN="m79-scratch-service-token-$$-$(date +%s)"
BODY_TMP="$(mktemp)"

cleanup() {
  docker rm -fv "${FN_ON}" "${FN_OFF}" "${ORCH_ON}" "${PG}" "${REDIS}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${FN_IMG}" "${ORCH_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" 2>/dev/null || true
}
trap cleanup EXIT

psql_q()   { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
redis_cli() { docker exec -i "${REDIS}" redis-cli "$@"; }

# Trivial edge function: returns {ok:true}. Single line so the JSON upload body is
# simple. The default export receives the InvokeInput and returns an InvokeResult.
FN_CODE='export default function(input){ return { status: 200, body: { ok: true, t: input.tenant_id } }; }'

# Upload the function (one-time) to a runtime on $1=port. jq builds the request
# body so the function source is correctly JSON-escaped (no manual escaping).
upload_fn() { # $1=port
  local body
  body="$(jq -n --arg name "${FNNAME}" --arg code "${FN_CODE}" '{name:$name, code:$code}')"
  curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST "http://127.0.0.1:$1/v1/functions" \
    -H "X-Baas-Tenant-Id: ${TENANT}" -H 'Content-Type: application/json' -d "${body}"
}

# Invoke the function once on $1=port; echo HTTP status.
invoke_fn() { # $1=port
  curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST "http://127.0.0.1:$1/v1/functions/${FNNAME}/invoke" \
    -H "X-Baas-Tenant-Id: ${TENANT}" -H 'Content-Type: application/json' -d '{}'
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

# ── 0) build BOTH scratch images FROM THE CURRENT (drafted) source ─────────────
step "0/7 build scratch functions-runtime + Go orchestrator from CURRENT source (B1d)"
DOCKER_BUILDKIT=1 docker build -q -f "${FN_DIR}/Dockerfile" -t "${FN_IMG}" "${FN_DIR}" >/dev/null \
  || fail "scratch functions-runtime image build failed — gate must exercise the drafted producer (line: docker build FN)"
DOCKER_BUILDKIT=1 docker build -q \
  --build-arg APP=orchestrator --build-arg PORT=3021 \
  -t "${ORCH_IMG}" "${GO_DIR}" >/dev/null \
  || fail "scratch orchestrator image build failed — gate must exercise the drafted consumer (line: docker build ORCH)"
ok "both scratch images built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated network + redis + postgres (prelude + REAL migration 040) ──────
step "1/7 boot isolated network (${NET}), redis (${REDIS}), postgres (${PG})"
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

step "1b/7 apply the migration-040 PRELUDE (schema_migrations + auth + roles) then the REAL 040"
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
step "2/7 boot Go orchestrator (ORCHESTRATOR_SERVICES=metering, METERING_INGEST=1) — the consumer"
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

# ── 3) (A) POSITIVE producer: functions-runtime metering ON → N invokes/window ─
step "3/7 boot functions-runtime FUNCTION_METERING=1 (flush=${FLUSH_MS}ms) → scratch redis (A)"
docker run -d --name "${FN_ON}" --network "${NET}" \
  -e FUNCTION_METERING=1 \
  -e FUNCTION_METERING_FLUSH_MS="${FLUSH_MS}" \
  -e FUNCTION_METERING_REDIS_URL="${REDIS_INNET}" \
  -e FUNCTIONS_INVOKE_TIMEOUT_MS="${INVOKE_TIMEOUT_MS}" \
  -p "127.0.0.1:${PORT_ON}:3060" "${FN_IMG}" >/dev/null
wait_http "${FN_ON}" "${PORT_ON}" "/health/live" || fail "POSITIVE runtime not ready (line: wait_http FN_ON)"
docker logs "${FN_ON}" 2>&1 | grep -q "metering ON" \
  || fail "POSITIVE runtime did not log 'metering ON' with FUNCTION_METERING=1 (line: FN_ON metering log)"
ok "POSITIVE runtime up (metering ON) on 127.0.0.1:${PORT_ON}"

step "3b/7 upload + WARM the worker (cold first-invoke), let it flush, RESET, then invoke N=${N}"
code="$(upload_fn "${PORT_ON}")"
[[ "${code}" == "201" ]] || fail "function upload expected 201, got ${code} — $(head -c 300 "${BODY_TMP}") (line: A upload)"
# WARM-UP: the FIRST invoke after boot is a cold Deno Worker spin-up + module
# compile (a runtime characteristic — no warm pool; see the Dockerfile). On a
# quiet host it is ~30ms, but under the gate's build/IO contention the very first
# one can exceed the invoke timeout once before the worker warms. So we RETRY the
# warm-up until one succeeds (each retry warms the runtime further) — this is the
# functions runtime's cold-start, NOT a metering effect. After this loop the
# worker is warm and every subsequent invoke is fast.
# WARMUPS counts the SUCCESSFUL warm-up invocations — each metered (qty 1), so the
# expected total below is WARMUPS + N. We do NOT DEL the stream or TRUNCATE the
# table here: DEL would also destroy the consumer GROUP (the consumer creates it
# once at boot via MKSTREAM and never re-creates it), wedging ingest with NOGROUP.
# Instead we let the warm-up's window flush, then fire the measured N in a later
# window, and assert on WARMUPS + N total.
WARMUPS=0
for w in $(seq 1 8); do
  WARM="$(invoke_fn "${PORT_ON}")"
  if [[ "${WARM}" == "200" ]]; then WARMUPS=$((WARMUPS+1)); break; fi
  cyan "  [M79] warm-up #${w} got ${WARM} (cold start under load) — retrying"
  sleep 1
done
[[ "${WARMUPS}" -ge 1 ]] || fail "runtime never warmed (8 cold-start retries all failed) — $(head -c 300 "${BODY_TMP}") (line: A warmup)"
# Let the warm-up's window FLUSH (drains the aggregator to zero) so the measured N
# land in a FRESH window — distinct window_start ⇒ distinct row ⇒ MAX(qty) over
# the measured window proves cumulative aggregation independent of the warm-up.
sleep "$(awk "BEGIN{printf \"%.1f\", ${FLUSH_MS}/1000*2 + 1}")"
# MEASURED: N warm invokes fired back-to-back (~20-40ms each, so all N complete in
# well under one flush window → one cumulative window row of qty N).
for i in $(seq 1 "${N}"); do
  c="$(invoke_fn "${PORT_ON}")"
  [[ "${c}" == "200" ]] || fail "invoke #${i} expected 200, got ${c} — $(head -c 300 "${BODY_TMP}") (line: A invoke ${i})"
done
EXPECT_TOTAL=$((WARMUPS + N))
ok "warmed (${WARMUPS} ok) + invoked ${FNNAME} ${N} more times (all 200) — expect SUM(qty)=${EXPECT_TOTAL}, one window with qty=${N}"

# ── 4) (A) wait past flush+ingest, then ASSERT cumulative qty ──────────────────
step "4/7 wait flush(${FLUSH_MS}ms) + ingest, then ASSERT cumulative qty (SUM=${EXPECT_TOTAL}, a window qty=${N})"
# Poll the STORE until the full SUM (warm-ups + measured N) has landed, or time
# out. This is the true end-to-end assertion: rows in the table.
SUMQ=0
for i in $(seq 1 40); do
  SUMQ="$(psql_val "SELECT COALESCE(SUM(qty),0) FROM public.tenant_usage WHERE tenant_id='${TENANT}' AND metric='function.invocations'")"
  [[ "${SUMQ}" -ge "${EXPECT_TOTAL}" ]] && break
  sleep 0.5
done

# ASSERTIONS (all read from the STORE, never self-reported):
#   1. SUM(qty) across all window rows == WARMUPS + N — every successful
#      invocation counted exactly once, no loss, no double-count.
#   2. MAX(qty) >= N (> 1) — proves CUMULATIVE windowed aggregation: the measured
#      window folded all N invocations into ONE entry. A per-event emit (the bug
#      this gate guards) would make every entry qty=1 and, since all N share ONE
#      idempotency_key per window, the consumer's ON CONFLICT DO NOTHING would
#      keep only the FIRST → grand total WARMUPS+1, MAX=1 — failing BOTH asserts.
ROWS="$(psql_val "SELECT count(*) FROM public.tenant_usage WHERE tenant_id='${TENANT}' AND metric='function.invocations'")"
MAXQ="$(psql_val "SELECT COALESCE(MAX(qty),0) FROM public.tenant_usage WHERE tenant_id='${TENANT}' AND metric='function.invocations'")"
[[ "${SUMQ}" == "${EXPECT_TOTAL}" ]] \
  || fail "(A) SUM(qty)=${SUMQ} != WARMUPS+N=${EXPECT_TOTAL} across ${ROWS} window row(s) — invocations lost or double-counted; stream depth=$(redis_cli XLEN usage.events), consumer tail: $(docker logs "${ORCH_ON}" 2>&1 | tail -3) (line: A sum!=total)"
[[ "${MAXQ}" -ge "${N}" ]] \
  || fail "(A) MAX(qty)=${MAXQ} < N=${N} — looks like PER-EVENT emit, not CUMULATIVE windowed aggregation (the N back-to-back invokes must fold into ONE window of qty ${N}) (line: A maxq<N)"
ok "(A) function.invocations: SUM(qty)=${SUMQ}==WARMUPS+N over ${ROWS} window row(s), MAX(qty)=${MAXQ}>=N=${N} = windowed CUMULATIVE (read from the STORE)"

# ── 5) (B) PARITY: FUNCTION_METERING unset → ZERO usage.events + empty table ────
step "5/7 (B) PARITY — fresh stream + re-migrated empty table, FUNCTION_METERING UNSET"
# Stop BOTH the ON producer and the ingest consumer. DEL'ing the stream destroys
# the consumer group, so the consumer must be stopped first (else it spins on
# NOGROUP); for the parity arm we only need to prove the producer is silent, so a
# running consumer is unnecessary anyway.
docker rm -fv "${FN_ON}" "${ORCH_ON}" >/dev/null 2>&1 || true
redis_cli DEL usage.events >/dev/null 2>&1 || true
psql_q -c "TRUNCATE public.tenant_usage" >/dev/null 2>&1 || fail "could not truncate tenant_usage for B (line: B truncate)"
EMPTY0="$(psql_val "SELECT count(*) FROM public.tenant_usage")"
[[ "${EMPTY0}" == "0" ]] || fail "(B) table not empty at start, found ${EMPTY0} (line: B start empty)"
XLEN0="$(redis_cli XLEN usage.events 2>/dev/null | tr -d '[:space:]')"
[[ "${XLEN0:-0}" == "0" ]] || fail "(B) stream not empty at start, depth=${XLEN0} (line: B stream start)"

# Runtime with the metering flag UNSET (sub-flag OFF ⇒ disabled, byte-parity).
docker run -d --name "${FN_OFF}" --network "${NET}" \
  -e FUNCTION_METERING_REDIS_URL="${REDIS_INNET}" \
  -e FUNCTIONS_INVOKE_TIMEOUT_MS="${INVOKE_TIMEOUT_MS}" \
  -p "127.0.0.1:${PORT_OFF}:3060" "${FN_IMG}" >/dev/null
wait_http "${FN_OFF}" "${PORT_OFF}" "/health/live" || fail "(B) PARITY runtime not ready (line: B wait_http)"
docker logs "${FN_OFF}" 2>&1 | grep -q "metering ON" \
  && fail "(B) runtime logged 'metering ON' with FUNCTION_METERING unset — NOT parity (line: B metering leak)"

# Identical traffic: same upload + warm-up + N invokes. The invoke path must still
# WORK (functions are unaffected by metering) but must emit NOTHING. The warm-up
# absorbs the cold Deno Worker start (same runtime characteristic as the ON arm).
code="$(upload_fn "${PORT_OFF}")"
[[ "${code}" == "201" ]] || fail "(B) function upload expected 201, got ${code} (line: B upload)"
WARMED=0
for w in $(seq 1 8); do
  WARM="$(invoke_fn "${PORT_OFF}")"
  [[ "${WARM}" == "200" ]] && { WARMED=1; break; }
  cyan "  [M79] (B) warm-up #${w} got ${WARM} (cold start under load) — retrying"
  sleep 1
done
[[ "${WARMED}" == "1" ]] || fail "(B) runtime never warmed (8 cold-start retries failed) (line: B warmup)"
for i in $(seq 1 "${N}"); do
  c="$(invoke_fn "${PORT_OFF}")"
  [[ "${c}" == "200" ]] || fail "(B) invoke #${i} expected 200, got ${c} (invoke must still work) (line: B invoke ${i})"
done
ok "(B) identical traffic served — warm-up + ${N} invokes all 200 with the flag unset"

# Wait several flush windows; a metering-OFF runtime never spawns the flusher, so
# it can never XADD, and the consumer can never ingest. Both MUST stay at zero.
sleep "$(awk "BEGIN{printf \"%.1f\", ${FLUSH_MS}/1000*3 + 2}")"
XLEN_OFF="$(redis_cli XLEN usage.events 2>/dev/null | tr -d '[:space:]')"
[[ "${XLEN_OFF:-0}" == "0" ]] \
  || fail "(B) PARITY BROKEN — metering-OFF runtime XADDed ${XLEN_OFF} usage.events (expected 0) (line: B XLEN!=0)"
PARITY_ROWS="$(psql_val "SELECT count(*) FROM public.tenant_usage")"
[[ "${PARITY_ROWS}" == "0" ]] \
  || fail "(B) PARITY BROKEN — ${PARITY_ROWS} tenant_usage row(s) with FUNCTION_METERING unset (line: B rows!=0)"
ok "(B) FUNCTION_METERING unset → identical invocations → XLEN usage.events=0 AND tenant_usage EMPTY = byte-parity"

# ── 6) cross-check + done ──────────────────────────────────────────────────────
step "6/7 cross-check"
green "[M79] (A) functions-runtime→usage.events→consumer→tenant_usage: function.invocations SUM(qty)=${SUMQ} (=warmups+N), measured window qty=${N} (cumulative) for tenant=${TENANT}"
green "[M79] (B) FUNCTION_METERING unset → ${N} identical invokes → ZERO usage.events, tenant_usage empty"

step "7/7 all B1d metering assertions hold"
green "[M79] ALL GATES GREEN — functions metering (B1d) emits function.invocations correctly (windowed cumulative) and is byte-parity when OFF"

# Log PASS via the JSONL helper (never hand-rolled).
if [[ -f "${LOG_HELPER}" ]]; then
  # shellcheck disable=SC1090
  AGENT_ROLE="tester" AGENT_TASK="b1d-metering-functions" source "${LOG_HELPER}" 2>/dev/null || true
  if command -v log_event >/dev/null 2>&1; then
    log_event REPORT --outcome PASS --gate m79=PASS \
      --ref "scripts/verify/m79-metering-functions.sh" \
      --msg "m79 functions metering: function.invocations qty=${N}==N (windowed cumulative); FUNCTION_METERING OFF => XLEN usage.events=0 + tenant_usage empty (byte-parity)" \
      >/dev/null 2>&1 || true
  fi
fi
