#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m75-metering-ingest.sh                             :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M75 — Track-B metering B1b end-to-end ingest gate. Proves the DURABLE path that
# sits on top of B1a (m74): the data plane's background flusher XADDs the FROZEN
# usage envelope to the single Redis stream `usage.events`, and the Go control-
# plane consumer (METERING_INGEST) idempotently UPSERTs each entry into
# public.tenant_usage — at-least-once delivery, dedup on idempotency_key, no
# double-count — and that the whole thing is byte-parity when its flags are OFF.
#
# This gate exercises the COMPLETE producer/consumer boundary, both planes built
# FROM THE CURRENT (drafted) source:
#   data-plane-router  (Rust, metering ON, flush=800ms, redis-rl XADD compiled in
#                       via the default `ratelimit-redis` feature)
#         │  XADD usage.events  {tenant_id, metric, qty, ts, window_ms,
#         ▼                       idempotency_key = sha256("tenant|metric|window")}
#   redis  (the single `usage.events` stream)
#         │  XREADGROUP (consumer group "metering-ingest")
#         ▼
#   orchestrator  (Go, ORCHESTRATOR_SERVICES=metering, METERING_INGEST=1)
#         │  INSERT … ON CONFLICT (idempotency_key) DO NOTHING  (AdminExec, superuser)
#         ▼
#   postgres  public.tenant_usage   ← the gate SELECTs the ground truth from here
#
# FROZEN CONTRACT (both planes MUST match — verified end-to-end here):
#   • stream key  : "usage.events"  (single stream; metric is a FIELD)
#   • entry fields: tenant_id, metric (query.count|query.rows|write.rows), qty
#                   (int as string), ts (unix ms str), window_ms (str),
#                   idempotency_key (lower-hex sha256 "<tenant>|<metric>|<window_start_ms>",
#                   window_start_ms = ts - (ts mod window_ms))
#   • store       : public.tenant_usage(tenant_id, metric, window_start, qty,
#                   idempotency_key PRIMARY KEY, updated_at). Idempotent ingest:
#                   INSERT … ON CONFLICT (idempotency_key) DO NOTHING.
#
# ISOLATED by design (mirrors m74 / m72 / m59): a scratch postgres + redis +
# data-plane-router + Go orchestrator, all on a PRIVATE network, every container/
# image/network name suffixed with $$, an EXIT-trap that removes EVERYTHING. It
# NEVER touches a mini-baas-* container/network/image/volume — safe while the live
# stack is up. The compose project is implicit (plain `docker run`).
#
# The scratch postgres applies a MINIMAL prelude (schema_migrations + auth schema/
# current_tenant_id() + the authenticated/service_role roles migration 040
# references) and then the REAL migration 040_tenant_usage.sql — so the gate also
# proves that migration applies cleanly, not a hand-built table.
#
#   (A) POSITIVE: a router with METERING_ENABLED=1 DATA_PLANE_METERING=1 serves ONE
#       real read (list → ROWS=5) and ONE real write (batch of M=3 inserts →
#       affected_rows=3). After the flush, `usage.events` carries the entries; the
#       consumer (METERING_INGEST=1) UPSERTs; SELECT from tenant_usage MUST show:
#         metric=query.count qty=1        (one read)
#         metric=query.rows  qty=ROWS=5   (the served row count — ground truth)
#         metric=write.rows  qty=M=3      (the batch affected_rows — ground truth)
#       each carrying tenant_id=<the probe tenant>. Every qty is asserted against
#       the INDEPENDENTLY-KNOWN truth (ROWS / M / 1), never a self-reported number.
#   (B) DEDUP:   re-XADD the EXACT SAME query.rows window entry (identical
#       idempotency_key) onto the live stream → after the consumer drains it,
#       tenant_usage STILL has exactly ONE row for that idempotency_key and qty is
#       UNCHANGED (no double-count). Proven explicitly with a before/after count.
#   (C) PARITY:  (c1) a second orchestrator with METERING_INGEST UNSET, against a
#       fresh stream + a fresh (re-migrated, empty) usage table, fed the SAME
#       traffic → tenant_usage stays EMPTY (the consumer never subscribes).
#       (c2) a data-plane-router with the metering flag OFF, fed the SAME read+
#       write → ZERO `usage.events` entries are produced (the producer is silent).
#
# Fails (exit≠0) on any wrong qty, missing row, double-count, or ANY row/stream
# entry when OFF. Each fail names the exact assertion that tripped. Output is
# tee'd to artifacts/b1b/m75.txt.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                 # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                       # apps/baas
DPR_DIR="${INFRA_DIR}/src/data-plane-router"
GO_DIR="${INFRA_DIR}/src/control-plane"
MIGRATION_040="${INFRA_DIR}/scripts/migrations/postgresql/040_tenant_usage.sql"
ART_DIR="${INFRA_DIR}/artifacts/b1b"
ART="${ART_DIR}/m75.txt"

# Tee all stdout/stderr to the artifact (mkdir first so the redirect can open it).
mkdir -p "${ART_DIR}"
exec > >(tee "${ART}") 2>&1

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M75] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M75] FAIL — $*"; exit 1; }

PG_IMAGE="${M75_PG_IMAGE:-postgres:16-alpine}"
REDIS_IMAGE="${M75_REDIS_IMAGE:-redis:7-alpine}"
DPR_IMG="m75-dpr-$$:scratch"
ORCH_IMG="m75-orch-$$:scratch"
NET="m75net-$$"
PG="m75-pg-$$"
REDIS="m75-redis-$$"
DPR_ON="m75-dpr-on-$$"       # (A) POSITIVE producer (metering ON)
DPR_OFF="m75-dpr-off-$$"     # (C2) PARITY producer  (metering OFF/unset)
ORCH_ON="m75-orch-on-$$"     # (A/B) ingest consumer (METERING_INGEST=1)
ORCH_OFF="m75-orch-off-$$"   # (C1) PARITY consumer  (METERING_INGEST unset)
PORT_ON="${M75_PORT_ON:-18981}"
PORT_OFF="${M75_PORT_OFF:-18982}"
PGPW="postgres"
# Distinct probe tables per producer arm so the OFF arm's writes can never inflate
# the ON arm's read, and each arm's read deterministically returns EXACTLY ${ROWS}.
TABLE_ON="m75_usage_probe_on"
TABLE_OFF="m75_usage_probe_off"
TENANT="m75-tenant-$$"
ROWS=5                       # exact seeded rows → query.rows qty ground truth
M=3                          # batch insert items → write.rows qty (affected_rows)
FLUSH_MS="${M75_FLUSH_MS:-800}"
DSN_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
REDIS_INNET="redis://${REDIS}:6379"
DATABASE_URL_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres?sslmode=disable"
# shared.LoadConfig refuses an empty / placeholder INTERNAL_SERVICE_TOKEN; a strong
# scratch-only value satisfies the guard (the metering consumer mounts no
# token-protected routes, so any strong value works for this isolated gate).
SVC_TOKEN="m75-scratch-service-token-$$-$(date +%s)"
BODY_TMP="$(mktemp)"

cleanup() {
  docker rm -fv "${DPR_ON}" "${DPR_OFF}" "${ORCH_ON}" "${ORCH_OFF}" "${PG}" "${REDIS}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${DPR_IMG}" "${ORCH_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" 2>/dev/null || true
}
trap cleanup EXIT

# psql / redis-cli helpers run INSIDE the scratch containers (no host client).
psql_q()  { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
redis_cli() { docker exec -i "${REDIS}" redis-cli "$@"; }

# Build the /v1/query envelope: identity + mount(inline DSN) + operation — the
# internal trusted-envelope path (identical to m72/m74).
#   $1 = op  ·  $2 = resource (table)  ·  $3 = data JSON (or the literal `null`)
payload() {
  printf '{"identity":{"tenant_id":"%s","user_id":"%s","roles":["service_role"],"scopes":["admin"],"source":"test"},"mount":{"id":"m75","tenant_id":"%s","engine":"postgresql","name":"probe","credential_ref":{"provider":"inline","reference":"-","version":"1"},"capability_overrides":null,"inline_dsn":"%s","isolation":"shared_rls"},"operation":{"op":"%s","resource":"%s","data":%s}}' \
    "${TENANT}" "${TENANT}" "${TENANT}" "${DSN_INNET}" "$1" "$2" "$3"
}

# Build the batch `data` array: M insert sub-operations into the given table.
batch_data() { # $1=table
  local t="$1" i
  printf '['
  for i in $(seq 1 "${M}"); do
    [[ $i -gt 1 ]] && printf ','
    printf '{"op":"insert","resource":"%s","data":{"id":"w%s","owner_id":"%s","tenant_id":"%s","label":"wrote%s"}}' \
      "${t}" "$i" "${TENANT}" "${TENANT}" "$i"
  done
  printf ']'
}

# POST a query to a router on 127.0.0.1:$port; echo HTTP status, body→BODY_TMP.
post_q() { # $1=port  $2=body
  curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST "http://127.0.0.1:$1/v1/query" \
    -H 'Content-Type: application/json' -d "$2"
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

# Wait for a log line to appear in a container (used to confirm the consumer
# subscribed, and to confirm an orchestrator with the flag OFF did NOT).
wait_log() { # $1=container  $2=needle  $3=tries
  local i
  for i in $(seq 1 "${3:-40}"); do
    docker logs "$1" 2>&1 | grep -q "$2" && return 0
    docker inspect "$1" >/dev/null 2>&1 || return 1
    sleep 0.5
  done
  return 1
}

# Read one field's value out of a live `usage.events` entry whose idempotency_key
# matches, for the (B) replay. `redis-cli XRANGE` prints, per entry: the id line,
# then alternating field / value lines. The field NAMED on a line is followed by
# its value on the NEXT line. We scan for `idempotency_key` + the target key in
# the same entry, and pull the requested field's value from that entry.
#   $1 = idempotency_key to match  ·  $2 = field name to extract
stream_field_for() {
  redis_cli XRANGE usage.events - + 2>/dev/null | awk -v key="$1" -v want="$2" '
    /^[0-9]+-[0-9]+$/ { delete f; prev=""; next }   # entry id → reset this entry
    prev != ""        { f[prev]=$0; prev=""; next }  # a value line for the prev field
    { prev=$0 }                                       # a field-name line
    # After each line, if this entry has both the matching key and the wanted
    # field, print and stop.
    f["idempotency_key"]==key && (want in f) { print f[want]; exit }
  '
}

# ── 0) build BOTH scratch images FROM THE CURRENT (drafted) source ─────────────
step "0/9 build scratch data-plane-router + Go orchestrator from CURRENT source (B1b)"
DOCKER_BUILDKIT=1 docker build -q -f "${DPR_DIR}/Dockerfile" -t "${DPR_IMG}" "${DPR_DIR}" >/dev/null \
  || fail "scratch data-plane-router image build failed — gate must exercise the drafted producer (line: docker build DPR)"
DOCKER_BUILDKIT=1 docker build -q \
  --build-arg APP=orchestrator --build-arg PORT=3021 \
  -t "${ORCH_IMG}" "${GO_DIR}" >/dev/null \
  || fail "scratch orchestrator image build failed — gate must exercise the drafted consumer (line: docker build ORCH)"
ok "both scratch images built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated network + redis + postgres (prelude + REAL migration 040) ──────
step "1/9 boot isolated network (${NET}), redis (${REDIS}), postgres (${PG})"
docker network create "${NET}" >/dev/null
docker run -d --name "${REDIS}" --network "${NET}" "${REDIS_IMAGE}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null

# redis readiness
for i in $(seq 1 60); do redis_cli PING 2>/dev/null | grep -q PONG && break; [[ $i -eq 60 ]] && fail "scratch redis never answered PING (line: redis ready)"; sleep 0.5; done
# postgres: the alpine entrypoint inits then restarts once — wait for the SECOND
# "ready" so a query can't land in the shutdown window.
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "scratch postgres never reached post-init steady state (line: PG ready loop)"
  sleep 0.5
done
ok "redis + postgres up"

step "1b/9 apply the migration-040 PRELUDE (schema_migrations + auth + roles) then the REAL 040"
# Minimal prelude: the objects migration 040 references but that a bare postgres
# lacks. This is the smallest stand-in for the migration framework / 001-039 — the
# gate then runs the ACTUAL 040 file so the migration itself is exercised.
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
# Apply the REAL migration 040 (proves it applies cleanly against the prelude).
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "${MIGRATION_040}" >/dev/null 2>&1 \
  || fail "real migration 040_tenant_usage.sql failed to apply (line: apply 040)"
APPLIED="$(psql_val "SELECT count(*) FROM public.tenant_usage")"
[[ "${APPLIED}" == "0" ]] || fail "tenant_usage should start EMPTY after migration, found '${APPLIED}' (line: 040 empty check)"
MIG="$(psql_val "SELECT version FROM public.schema_migrations WHERE version=40")"
[[ "${MIG}" == "40" ]] || fail "migration 040 did not record version=40 in schema_migrations (line: 040 recorded)"
ok "migration 040 applied — public.tenant_usage exists and is empty"

step "1c/9 seed ${ROWS} rows into each probe table (ON + OFF arms)"
seed() {
  psql_q >/dev/null 2>&1 <<SQL
CREATE TABLE IF NOT EXISTS public.${TABLE_ON}  (id text PRIMARY KEY, owner_id text, tenant_id text, label text);
CREATE TABLE IF NOT EXISTS public.${TABLE_OFF} (id text PRIMARY KEY, owner_id text, tenant_id text, label text);
INSERT INTO public.${TABLE_ON}(id,owner_id,tenant_id,label) VALUES
  ('r1','${TENANT}','${TENANT}','one'),('r2','${TENANT}','${TENANT}','two'),
  ('r3','${TENANT}','${TENANT}','three'),('r4','${TENANT}','${TENANT}','four'),
  ('r5','${TENANT}','${TENANT}','five') ON CONFLICT (id) DO NOTHING;
INSERT INTO public.${TABLE_OFF}(id,owner_id,tenant_id,label) VALUES
  ('r1','${TENANT}','${TENANT}','one'),('r2','${TENANT}','${TENANT}','two'),
  ('r3','${TENANT}','${TENANT}','three'),('r4','${TENANT}','${TENANT}','four'),
  ('r5','${TENANT}','${TENANT}','five') ON CONFLICT (id) DO NOTHING;
SQL
}
for i in $(seq 1 20); do seed && break; [[ $i -eq 20 ]] && fail "seed never committed (line: seed loop)"; sleep 0.5; done
for T in "${TABLE_ON}" "${TABLE_OFF}"; do
  S="$(psql_val "SELECT count(*) FROM public.${T}")"
  [[ "${S}" == "${ROWS}" ]] || fail "expected ${ROWS} seeded rows in ${T}, found '${S}' (line: SEEDED ${T})"
done
ok "each probe table seeded with EXACTLY ${ROWS} rows"

# ── 2) start the ingest consumer (METERING_INGEST=1) ───────────────────────────
step "2/9 boot Go orchestrator (ORCHESTRATOR_SERVICES=metering, METERING_INGEST=1) — the consumer"
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
# The consumer's Init logs "metering ingest connected" only when enabled+subscribed.
wait_log "${ORCH_ON}" "metering ingest connected" 60 \
  || { red "consumer logs:"; docker logs "${ORCH_ON}" 2>&1 | tail -20; fail "ingest consumer never subscribed to usage.events (line: wait_log ORCH_ON connected)"; }
ok "ingest consumer subscribed to usage.events (group metering-ingest)"

# ── 3) (A) POSITIVE producer: data plane with metering ON → real read + write ──
step "3/9 boot data-plane-router METERING_ENABLED=1 DATA_PLANE_METERING=1 → scratch redis (A)"
docker run -d --name "${DPR_ON}" --network "${NET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
  -e METERING_ENABLED=1 \
  -e DATA_PLANE_METERING=1 \
  -e DATA_PLANE_METERING_FLUSH_MS="${FLUSH_MS}" \
  -e DATA_PLANE_METERING_REDIS_URL="${REDIS_INNET}" \
  -e RUST_LOG=info \
  -p "127.0.0.1:${PORT_ON}:4011" "${DPR_IMG}" >/dev/null
wait_http "${DPR_ON}" "${PORT_ON}" "/v1/capabilities" || fail "POSITIVE router not ready (line: wait_http DPR_ON)"
ok "POSITIVE router up (metering ON, durable XADD → scratch redis) on 127.0.0.1:${PORT_ON}"

step "3b/9 fire ONE real read (list → ${ROWS} rows) + ONE real write (batch ${M}) through it"
code="$(post_q "${PORT_ON}" "$(payload list "${TABLE_ON}" null)")"
[[ "${code}" == "200" ]] || fail "POSITIVE list expected 200, got ${code} — $(head -c 300 "${BODY_TMP}") (line: POSITIVE read status)"
SERVED="$(grep -o '"label"' "${BODY_TMP}" | wc -l | tr -d '[:space:]')"
[[ "${SERVED}" == "${ROWS}" ]] || fail "POSITIVE list returned ${SERVED} rows, expected ${ROWS} (line: SERVED count)"
code="$(post_q "${PORT_ON}" "$(payload batch "${TABLE_ON}" "$(batch_data "${TABLE_ON}")")")"
[[ "${code}" == "200" ]] || fail "POSITIVE batch write expected 200, got ${code} — $(head -c 400 "${BODY_TMP}") (line: POSITIVE write status)"
WROTE="$(psql_val "SELECT count(*) FROM public.${TABLE_ON} WHERE id LIKE 'w%'")"
[[ "${WROTE}" == "${M}" ]] || fail "POSITIVE batch wrote ${WROTE} rows, expected ${M} (line: WROTE count)"
ok "read served ${ROWS} rows (query.rows truth); write affected ${M} rows (write.rows truth)"

# ── 4) (A) wait past flush+ingest, then ASSERT tenant_usage from the STORE ──────
step "4/9 wait flush(${FLUSH_MS}ms) + ingest, then ASSERT public.tenant_usage rows == ground truth"
# Poll the STORE (not logs): the producer flushes every ${FLUSH_MS}, the consumer
# drains within METERING_INGEST_BLOCK_MS. Wait until all three metric rows land
# (or time out). This is the true end-to-end assertion: rows in the table.
GOT=0
for i in $(seq 1 40); do
  GOT="$(psql_val "SELECT count(*) FROM public.tenant_usage WHERE tenant_id='${TENANT}'")"
  [[ "${GOT}" -ge 3 ]] && break
  sleep 0.5
done
[[ "${GOT}" -ge 3 ]] \
  || fail "expected ≥3 tenant_usage rows after ingest, found ${GOT} — stream depth=$(redis_cli XLEN usage.events), consumer tail: $(docker logs "${ORCH_ON}" 2>&1 | tail -5) (line: GOT < 3)"

# Assert each metric's stored qty == the independently-known truth.
assert_stored() { # $1=metric  $2=want-qty
  local metric="$1" want="$2" got
  got="$(psql_val "SELECT qty FROM public.tenant_usage WHERE tenant_id='${TENANT}' AND metric='${metric}'")"
  [[ -n "${got}" ]] \
    || fail "(A) metric=${metric}: NO row in tenant_usage for tenant=${TENANT} (line: assert_stored ${metric} missing)"
  [[ "${got}" == "${want}" ]] \
    || fail "(A) metric=${metric}: stored qty=${got} != ground truth ${want} (line: assert_stored ${metric} qty)"
  ok "(A) tenant_usage metric=${metric} qty=${want} — UPSERTed from the stream, matches the known truth"
}
assert_stored "query.count" 1
assert_stored "query.rows"  "${ROWS}"
assert_stored "write.rows"  "${M}"
ok "(A) POSITIVE: all three metrics flowed data-plane → usage.events → consumer → tenant_usage with exact qty"

# ── 5) (B) DEDUP: replay the EXACT SAME stream entry → exactly ONE row, no double ─
step "5/9 (B) DEDUP — re-XADD the SAME query.rows window (same idempotency_key)"
# Read the live query.rows entry's own fields off the stream so the replay is the
# EXACT contract window (same tenant|metric|window_start → same idempotency_key).
# XRANGE returns: id, [field, value, …]. Pull the one with metric=query.rows.
IDEM_BEFORE="$(psql_val "SELECT idempotency_key FROM public.tenant_usage WHERE tenant_id='${TENANT}' AND metric='query.rows'")"
QTY_BEFORE="$(psql_val "SELECT qty FROM public.tenant_usage WHERE idempotency_key='${IDEM_BEFORE}'")"
ROWS_BEFORE="$(psql_val "SELECT count(*) FROM public.tenant_usage WHERE idempotency_key='${IDEM_BEFORE}'")"
[[ "${ROWS_BEFORE}" == "1" && -n "${IDEM_BEFORE}" ]] \
  || fail "(B) precondition: expected exactly 1 row for the query.rows idem-key before replay, found ${ROWS_BEFORE} (line: B precondition)"

# Recover the entry's ts + window_ms from the stream (the producer stamped them);
# we need them to re-emit an IDENTICAL envelope. They are pulled from the live
# entry whose idempotency_key matches the stored row, so the replay is byte-exact.
REPLAY_TS="$(stream_field_for "${IDEM_BEFORE}" ts)"
REPLAY_WIN="$(stream_field_for "${IDEM_BEFORE}" window_ms)"
# Fallback: if the live entry is gone/unparsable, reconstruct ts from the stored
# window_start (any ts in [ws, ws+win) reproduces the same idempotency_key) and
# window_ms from the flush cadence — the replay still hits the same dedup key.
[[ -z "${REPLAY_WIN}" ]] && REPLAY_WIN="${FLUSH_MS}"
if [[ -z "${REPLAY_TS}" ]]; then
  WS_MS="$(psql_val "SELECT (extract(epoch FROM window_start)*1000)::bigint FROM public.tenant_usage WHERE idempotency_key='${IDEM_BEFORE}'")"
  REPLAY_TS="${WS_MS}"
fi
[[ -n "${REPLAY_TS}" && -n "${REPLAY_WIN}" ]] \
  || fail "(B) could not recover ts/window_ms to replay the identical window (line: B replay fields)"

# Re-XADD the EXACT SAME window: same tenant, metric, qty, ts, window_ms,
# idempotency_key. A correct consumer ON CONFLICT (idempotency_key) DO NOTHING ⇒
# no new row, qty unchanged. (We deliberately send a different qty value in the
# replay would NOT matter — DO NOTHING ignores it; but we keep qty identical to be
# a true "re-delivery", the at-least-once case the contract guards.)
redis_cli XADD usage.events '*' \
  tenant_id "${TENANT}" metric "query.rows" qty "${QTY_BEFORE}" \
  ts "${REPLAY_TS}" window_ms "${REPLAY_WIN}" idempotency_key "${IDEM_BEFORE}" >/dev/null \
  || fail "(B) failed to re-XADD the duplicate window (line: B re-xadd)"
ok "(B) re-XADDed the identical window (idempotency_key=${IDEM_BEFORE:0:12}…, qty=${QTY_BEFORE})"

step "5b/9 wait for the consumer to drain the replay, then ASSERT no double-count"
# Wait until the stream is fully consumed (pending drains), then assert the row
# count + qty for that idem-key are UNCHANGED.
for i in $(seq 1 40); do
  PENDING="$(redis_cli XPENDING usage.events metering-ingest 2>/dev/null | head -1 | tr -d '[:space:]')"
  # XLEN keeps growing (entries are acked, not trimmed); the dedup proof is the
  # ROW COUNT, not stream length. Give the consumer a few cycles to process.
  sleep 0.5
  [[ $i -ge 6 ]] && break
done
ROWS_AFTER="$(psql_val "SELECT count(*) FROM public.tenant_usage WHERE idempotency_key='${IDEM_BEFORE}'")"
QTY_AFTER="$(psql_val "SELECT qty FROM public.tenant_usage WHERE idempotency_key='${IDEM_BEFORE}'")"
[[ "${ROWS_AFTER}" == "1" ]] \
  || fail "(B) DOUBLE-COUNT — after replay, ${ROWS_AFTER} rows for idempotency_key=${IDEM_BEFORE} (expected exactly 1) (line: B rows_after != 1)"
[[ "${QTY_AFTER}" == "${QTY_BEFORE}" ]] \
  || fail "(B) qty drifted on replay — before=${QTY_BEFORE} after=${QTY_AFTER} (ON CONFLICT must DO NOTHING) (line: B qty drift)"
DEDUP_PROOF="idempotency_key=${IDEM_BEFORE}: rows ${ROWS_BEFORE}→${ROWS_AFTER} (==1), qty ${QTY_BEFORE}→${QTY_AFTER} (unchanged) after re-delivering the identical window"
ok "(B) DEDUP proven: ${DEDUP_PROOF}"

# ── 6) (C1) PARITY consumer: METERING_INGEST unset → table stays EMPTY ─────────
step "6/9 (C1) PARITY consumer — fresh stream + re-migrated empty table, METERING_INGEST UNSET"
# Stop the active consumer + producer; wipe the stream and the table so this arm
# starts from a clean slate (so a leftover row can't masquerade as parity-broken
# or parity-ok). Re-running migration 040 is a no-op (DO NOTHING on version 40), so
# truncate the table explicitly.
docker rm -fv "${DPR_ON}" "${ORCH_ON}" >/dev/null 2>&1 || true
redis_cli DEL usage.events >/dev/null 2>&1 || true
psql_q -c "TRUNCATE public.tenant_usage" >/dev/null 2>&1 || fail "could not truncate tenant_usage for C1 (line: C1 truncate)"
EMPTY0="$(psql_val "SELECT count(*) FROM public.tenant_usage")"
[[ "${EMPTY0}" == "0" ]] || fail "(C1) table not empty at start, found ${EMPTY0} (line: C1 start empty)"

# Consumer with the ingest flag UNSET (master ON, sub-flag OFF ⇒ disabled).
docker run -d --name "${ORCH_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DATABASE_URL_INNET}" \
  -e REDIS_URL="${REDIS_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e ORCHESTRATOR_SERVICES=metering \
  -e ORCHESTRATOR_PORT=3021 \
  -e METERING_ENABLED=1 \
  -e LOG_LEVEL=debug \
  "${ORCH_IMG}" >/dev/null
# It must announce it is DISABLED and must NOT announce it connected.
wait_log "${ORCH_OFF}" "metering ingest disabled" 40 \
  || { red "C1 consumer logs:"; docker logs "${ORCH_OFF}" 2>&1 | tail -20; fail "(C1) consumer did not report itself disabled with METERING_INGEST unset (line: C1 disabled log)"; }
docker logs "${ORCH_OFF}" 2>&1 | grep -q "metering ingest connected" \
  && fail "(C1) consumer SUBSCRIBED with METERING_INGEST unset — NOT parity! (line: C1 connected leak)"
ok "(C1) consumer reports disabled; never created a consumer group"

# Re-boot the ON producer (metering ON) so REAL usage.events ARE produced — the
# only thing different from arm (A) is the consumer's flag. If a row appears, the
# OFF consumer wrongly ingested.
docker run -d --name "${DPR_ON}" --network "${NET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
  -e METERING_ENABLED=1 -e DATA_PLANE_METERING=1 \
  -e DATA_PLANE_METERING_FLUSH_MS="${FLUSH_MS}" \
  -e DATA_PLANE_METERING_REDIS_URL="${REDIS_INNET}" \
  -e RUST_LOG=info \
  -p "127.0.0.1:${PORT_ON}:4011" "${DPR_IMG}" >/dev/null
wait_http "${DPR_ON}" "${PORT_ON}" "/v1/capabilities" || fail "(C1) producer not ready (line: C1 wait_http)"
post_q "${PORT_ON}" "$(payload list "${TABLE_ON}" null)" >/dev/null
post_q "${PORT_ON}" "$(payload batch "${TABLE_ON}" "$(batch_data "${TABLE_ON}")")" >/dev/null
# Confirm the producer DID emit (so the table-empty result is real parity, not a
# silent producer). Wait for entries on the stream. The exact count depends on how
# the read's two metrics + the write's one fall across flush windows (2 or 3
# entries); ANY entry proves the producer is live — the parity proof is the EMPTY
# table below, not the entry count. Require ≥2 (read alone emits two metrics) and
# wait several windows so the write's window has certainly flushed too.
for i in $(seq 1 30); do
  SDEPTH="$(redis_cli XLEN usage.events 2>/dev/null | tr -d '[:space:]')"
  [[ "${SDEPTH:-0}" -ge 2 ]] && break
  sleep 0.5
done
[[ "${SDEPTH:-0}" -ge 2 ]] \
  || fail "(C1) producer did not emit usage.events (depth=${SDEPTH:-0}) — cannot prove the consumer abstained (line: C1 producer silent)"
# Give a generous window for any (wrongly-subscribed) consumer to ingest.
sleep "$(awk "BEGIN{printf \"%.1f\", ${FLUSH_MS}/1000*4 + 2}")"
PARITY_ROWS="$(psql_val "SELECT count(*) FROM public.tenant_usage")"
[[ "${PARITY_ROWS}" == "0" ]] \
  || fail "(C1) PARITY BROKEN — ${PARITY_ROWS} tenant_usage row(s) with METERING_INGEST unset (stream had ${SDEPTH} entries) (line: C1 PARITY_ROWS != 0)"
ok "(C1) ${SDEPTH} usage.events on the stream, METERING_INGEST unset → tenant_usage EMPTY = byte-parity"

# ── 7) (C2) PARITY producer: data-plane metering OFF → ZERO usage.events ────────
step "7/9 (C2) PARITY producer — data-plane metering OFF, same read+write → ZERO usage.events"
docker rm -fv "${DPR_ON}" >/dev/null 2>&1 || true
redis_cli DEL usage.events >/dev/null 2>&1 || true
docker run -d --name "${DPR_OFF}" --network "${NET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
  -e DATA_PLANE_METERING_REDIS_URL="${REDIS_INNET}" \
  -e RUST_LOG=info \
  -p "127.0.0.1:${PORT_OFF}:4011" "${DPR_IMG}" >/dev/null
wait_http "${DPR_OFF}" "${PORT_OFF}" "/v1/capabilities" || fail "(C2) PARITY router not ready (line: C2 wait_http)"
code="$(post_q "${PORT_OFF}" "$(payload list "${TABLE_OFF}" null)")"
[[ "${code}" == "200" ]] || fail "(C2) list expected 200, got ${code} (read must still work) (line: C2 read status)"
SERVED_OFF="$(grep -o '"label"' "${BODY_TMP}" | wc -l | tr -d '[:space:]')"
[[ "${SERVED_OFF}" == "${ROWS}" ]] || fail "(C2) list returned ${SERVED_OFF} rows, expected ${ROWS} (line: C2 served)"
code="$(post_q "${PORT_OFF}" "$(payload batch "${TABLE_OFF}" "$(batch_data "${TABLE_OFF}")")")"
[[ "${code}" == "200" ]] || fail "(C2) batch write expected 200, got ${code} (line: C2 write status)"
# Wait several flush windows; a metering-OFF producer never spawns the flusher, so
# it can never XADD. The stream MUST stay at depth 0.
sleep "$(awk "BEGIN{printf \"%.1f\", ${FLUSH_MS}/1000*4 + 2}")"
SDEPTH_OFF="$(redis_cli XLEN usage.events 2>/dev/null | tr -d '[:space:]')"
[[ "${SDEPTH_OFF:-0}" == "0" ]] \
  || fail "(C2) PARITY BROKEN — metering-OFF producer XADDed ${SDEPTH_OFF} usage.events (expected 0) (line: C2 SDEPTH_OFF != 0)"
ok "(C2) metering OFF → identical read+write produced ZERO usage.events = byte-parity producer"

# ── 8) cross-check + done ──────────────────────────────────────────────────────
step "8/9 cross-check: ON ingested 3 metrics + deduped a replay; OFF (both flags) left the store empty"
green "[M75] (A) data-plane→usage.events→consumer→tenant_usage: query.count=1, query.rows=${ROWS}, write.rows=${M} (each = known truth) for tenant=${TENANT}"
green "[M75] (B) DEDUP: ${DEDUP_PROOF}"
green "[M75] (C1) METERING_INGEST unset → ${SDEPTH} stream entries IGNORED, tenant_usage empty"
green "[M75] (C2) DATA_PLANE_METERING off → ZERO usage.events produced for identical traffic"

step "9/9 all B1b ingest assertions hold"
green "[M75] ALL GATES GREEN — durable metering pipeline (B1b) is correct end-to-end and byte-parity when OFF"
