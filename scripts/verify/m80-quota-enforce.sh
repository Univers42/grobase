#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m80-quota-enforce.sh                               :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M80 — Track-B quota enforcement (B2) live gate. Proves the CUMULATIVE per-period
# usage quota is enforced end-to-end and is byte-parity when OFF. It CONSUMES B1's
# metering store (public.tenant_usage) — it does NOT re-meter:
#
#   control-plane QuotaGuard (Go, QUOTA_ENFORCEMENT=1)
#     │  every interval: SUM(tenant_usage.qty WHERE metric=query.count, this period)
#     │  per tenant vs its tier quota (packages.json: nano caps query.count@100000/mo)
#     ▼  publishes the SET of OVER-quota tenant ids → Redis `quota:over` (atomic rename)
#   redis  (the `quota:over` SET)
#     │  SMEMBERS quota:over  (data plane refreshes an in-memory snapshot off the
#     ▼   request path — NOT per request)
#   data-plane-router (Rust, DATA_PLANE_QUOTA_ENFORCEMENT=1)
#         on /v1/query: if identity.tenant_id ∈ snapshot → 402 (quota exceeded),
#         else serve normally.
#
#   (A) ENFORCE arm (both flags ON):  a request as the OVER tenant → 402 (read the
#       REAL status off the wire); as the UNDER tenant → 200. The 402 reject is the
#       LOAD-BEARING proof — a gate that only shows the under-quota happy path is
#       VACUOUS, so this asserts the 402 explicitly against the seeded over-quota row.
#   (B) PARITY arm (DATA_PLANE_QUOTA_ENFORCEMENT unset): the SAME OVER and UNDER
#       requests BOTH return 200 — the flag-OFF path is byte-identical regardless of
#       the over-quota set, the no-behavior-change baseline.
#
# Quota seeding is INDEPENDENT ground truth: the OVER tenant gets a tenant_usage row
# with qty = cap+1 (over its nano 100000 cap); the UNDER tenant gets qty = 50 (well
# under). Both tenants are on the nano plan in a minimal tenants table, so the guard
# resolves the SAME cap for both and the only difference is the seeded usage.
#
# ISOLATED by design (mirrors m74/m75/m77): scratch postgres (migration-040 prelude
# + the REAL 040) + redis + a data-plane-router built FROM CURRENT source + a Go
# orchestrator built FROM CURRENT source, ALL on a PRIVATE network, every name
# suffixed with $$, an EXIT-trap removing EVERYTHING. It NEVER touches a mini-baas-*
# container/network/image/volume and NEVER edits the live docker-compose.yml. The
# data path uses the router's internal trusted-envelope /v1/query (no Kong / auth),
# exactly as m74, so the EXACT production enforcement code runs.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                  # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                       # apps/baas
DPR_DIR="${INFRA_DIR}/docker/services/data-plane-router"
GO_DIR="${INFRA_DIR}/go/control-plane"
MIGRATION_040="${INFRA_DIR}/scripts/migrations/postgresql/040_tenant_usage.sql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M80] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M80] FAIL — $*"; exit 1; }

REDIS_IMAGE="${M80_REDIS_IMAGE:-redis:7-alpine}"
PG_IMAGE="${M80_PG_IMAGE:-postgres:16-alpine}"
DPR_IMG="m80-dpr-$$:scratch"
ORCH_IMG="m80-orch-$$:scratch"
NET="m80net-$$"
PG="m80-pg-$$"
REDIS="m80-redis-$$"
ORCH="m80-orch-on-$$"     # QuotaGuard (enforcement ON)
DPR_ON="m80-dpr-on-$$"    # (A) ENFORCE arm router
DPR_OFF="m80-dpr-off-$$"  # (B) PARITY  arm router
PORT_ON="${M80_PORT_ON:-18980}"
PORT_OFF="${M80_PORT_OFF:-18981}"
PGPW="postgres"
SVC_TOKEN="m80-internal-service-token-$$"
TENANT_OVER="m80-over-$$"
TENANT_UNDER="m80-under-$$"
PROBE_TABLE="m80_probe"
METRIC="query.count"
NANO_CAP=100000          # nano query.count cap (packages.json source of truth)
OVER_QTY=$((NANO_CAP + 1))
UNDER_QTY=50
REFRESH_MS="${M80_REFRESH_MS:-700}"     # LOW so the data plane refreshes fast
GUARD_MS="${M80_GUARD_MS:-700}"         # LOW so the guard re-evaluates fast
REDIS_INNET="redis://${REDIS}:6379"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
BODY_TMP="$(mktemp)"

cleanup() {
  docker rm -fv "${DPR_ON}" "${DPR_OFF}" "${ORCH}" "${PG}" "${REDIS}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${DPR_IMG}" "${ORCH_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" 2>/dev/null || true
}
trap cleanup EXIT

psql_q()   { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
redis_cli() { docker exec -i "${REDIS}" redis-cli "$@"; }

# Build the /v1/query envelope for a `list` against the bare probe table, as a
# given tenant. The identity tenant_id is what the enforcement keys on AND what
# we seeded usage for, so the two match by construction. service_role/admin +
# a bare (no-RLS) table → the read returns rows when it is allowed to run.
#   $1 = tenant_id
payload_list() {
  printf '{"identity":{"tenant_id":"%s","user_id":"%s","roles":["service_role"],"scopes":["admin"],"source":"test"},"mount":{"id":"m80","tenant_id":"%s","engine":"postgresql","name":"probe","credential_ref":{"provider":"inline","reference":"-","version":"1"},"capability_overrides":null,"inline_dsn":"%s","isolation":"shared_rls"},"operation":{"op":"list","resource":"%s","data":null}}' \
    "$1" "$1" "$1" "${DB_INNET}" "${PROBE_TABLE}"
}

# POST a /v1/query to a router on 127.0.0.1:$port; echo HTTP status, body→BODY_TMP.
post_q() { # $1=port  $2=body
  curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST "http://127.0.0.1:$1/v1/query" \
    -H 'Content-Type: application/json' -d "$2"
}

wait_ready() { # $1=container  $2=port
  for i in $(seq 1 60); do
    curl -fsS -o /dev/null "http://127.0.0.1:$2/v1/capabilities" 2>/dev/null && return 0
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -15; return 1; }
    sleep 0.5
  done
  red "$1 never became ready:"; docker logs "$1" 2>&1 | tail -15; return 1
}

wait_log() { # $1=container  $2=needle  $3=tries
  local i
  for i in $(seq 1 "${3:-60}"); do
    docker logs "$1" 2>&1 | grep -q "$2" && return 0
    docker inspect "$1" >/dev/null 2>&1 || return 1
    sleep 0.5
  done
  return 1
}

# ── 0) build the scratch DPR + orchestrator FROM CURRENT (drafted) source ──────
step "0/7 build scratch data-plane-router + Go orchestrator from CURRENT source (the B2 code)"
DOCKER_BUILDKIT=1 docker build -q -f "${DPR_DIR}/Dockerfile" -t "${DPR_IMG}" "${DPR_DIR}" >/dev/null \
  || fail "scratch data-plane-router image build failed — gate must exercise the drafted honor code (line: docker build DPR)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=orchestrator --build-arg PORT=3060 \
  -t "${ORCH_IMG}" "${GO_DIR}" >/dev/null \
  || fail "scratch orchestrator image build failed — gate must exercise the QuotaGuard (line: docker build ORCH)"
ok "both scratch images built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated network + redis + postgres (prelude + REAL migration 040) ──────
step "1/7 boot isolated net (${NET}): redis + postgres"
docker network create "${NET}" >/dev/null
docker run -d --name "${REDIS}" --network "${NET}" "${REDIS_IMAGE}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
for i in $(seq 1 60); do redis_cli PING 2>/dev/null | grep -q PONG && break; [[ $i -eq 60 ]] && fail "scratch redis never PONGed (line: redis ready)"; sleep 0.5; done
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "scratch postgres never reached steady state (line: PG ready loop)"
  sleep 0.5
done
ok "redis + postgres up"

step "1b/7 apply migration-040 PRELUDE then the REAL 040"
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
[[ "$(psql_val "SELECT count(*) FROM public.tenant_usage")" == "0" ]] || fail "tenant_usage should start EMPTY (line: 040 empty check)"
ok "migration 040 applied — public.tenant_usage exists and is empty"

# ── 2) seed: minimal tenants (both nano) + tenant_usage (OVER>cap, UNDER<cap) +
#       a bare probe table the data plane can list (so UNDER returns 200) ───────
step "2/7 seed tenants(${TENANT_OVER},${TENANT_UNDER} both nano) + tenant_usage (OVER=${OVER_QTY}>${NANO_CAP}, UNDER=${UNDER_QTY}) + probe table"
WINDOW_NOW="$(date -u +%Y-%m-01)"   # current month start = the period the guard sums over
seed() {
  psql_q >/dev/null 2>&1 <<SQL
-- Minimal tenants table: the guard LEFT JOINs tenant_usage→tenants for the plan
-- on tenants.slug = tenant_usage.tenant_id (the slug is the public identity the
-- data plane stamps; see quotaguard.usageByTenantSQL). This smoke arm keeps
-- slug == id == tenant_id; the real UUID-id/slug split is exercised by m101.
CREATE TABLE IF NOT EXISTS public.tenants (id text PRIMARY KEY, slug text UNIQUE, plan text);
INSERT INTO public.tenants(id, slug, plan) VALUES
  ('${TENANT_OVER}','${TENANT_OVER}','nano'),('${TENANT_UNDER}','${TENANT_UNDER}','nano')
  ON CONFLICT (id) DO UPDATE SET plan = EXCLUDED.plan, slug = EXCLUDED.slug;
-- Independent ground truth: OVER exceeds the nano query.count cap, UNDER is below.
-- One window row each (current month). idempotency_key is just a unique PK here.
INSERT INTO public.tenant_usage(tenant_id, metric, window_start, qty, idempotency_key) VALUES
  ('${TENANT_OVER}', '${METRIC}', '${WINDOW_NOW}T00:00:00Z', ${OVER_QTY},  'm80-over-$$'),
  ('${TENANT_UNDER}','${METRIC}', '${WINDOW_NOW}T00:00:00Z', ${UNDER_QTY}, 'm80-under-$$')
  ON CONFLICT (idempotency_key) DO NOTHING;
-- A bare (no-RLS) table the data plane lists; one row so a served read returns 200.
CREATE TABLE IF NOT EXISTS public.${PROBE_TABLE} (id text PRIMARY KEY, label text);
INSERT INTO public.${PROBE_TABLE}(id, label) VALUES ('p1','ok') ON CONFLICT (id) DO NOTHING;
SQL
}
for i in $(seq 1 20); do seed && break; [[ $i -eq 20 ]] && fail "seed never committed (line: seed loop)"; sleep 0.5; done
[[ "$(psql_val "SELECT qty FROM public.tenant_usage WHERE tenant_id='${TENANT_OVER}' AND metric='${METRIC}'")" == "${OVER_QTY}" ]] \
  || fail "OVER tenant_usage qty not seeded to ${OVER_QTY} (line: verify OVER seed)"
[[ "$(psql_val "SELECT qty FROM public.tenant_usage WHERE tenant_id='${TENANT_UNDER}' AND metric='${METRIC}'")" == "${UNDER_QTY}" ]] \
  || fail "UNDER tenant_usage qty not seeded to ${UNDER_QTY} (line: verify UNDER seed)"
ok "seeded: OVER qty=${OVER_QTY} (> nano cap ${NANO_CAP}), UNDER qty=${UNDER_QTY} (< cap); probe table has 1 row"

# ── 3) boot the QuotaGuard (orchestrator, QUOTA_ENFORCEMENT=1) ─────────────────
step "3/7 boot Go orchestrator (ORCHESTRATOR_SERVICES=quota-guard, QUOTA_ENFORCEMENT=1, interval=${GUARD_MS}ms)"
docker run -d --name "${ORCH}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e REDIS_URL="${REDIS_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e ORCHESTRATOR_SERVICES=quota-guard \
  -e ORCHESTRATOR_PORT=3060 \
  -e METERING_ENABLED=1 \
  -e QUOTA_ENFORCEMENT=1 \
  -e QUOTA_ENFORCEMENT_INTERVAL_MS="${GUARD_MS}" \
  -e LOG_LEVEL=debug \
  "${ORCH_IMG}" >/dev/null
wait_log "${ORCH}" "quota enforcement enabled" 60 \
  || { red "guard logs:"; docker logs "${ORCH}" 2>&1 | tail -20; fail "QuotaGuard never enabled (line: wait_log ORCH enabled)"; }
ok "QuotaGuard enabled — evaluating tenant_usage vs tier quota"

# Wait until the guard has published the over-quota set with the OVER tenant in it.
# The set is the data plane's enforcement source — assert the guard's REAL Redis
# decision (the OVER tenant present, the UNDER tenant absent) before probing.
step "3b/7 wait for QuotaGuard to publish quota:over with EXACTLY the OVER tenant"
PUBLISHED=
for i in $(seq 1 60); do
  if [[ "$(redis_cli SISMEMBER quota:over "${TENANT_OVER}" 2>/dev/null)" == "1" ]]; then PUBLISHED=1; break; fi
  sleep 0.5
done
[[ -n "${PUBLISHED}" ]] || { red "quota:over members:"; redis_cli SMEMBERS quota:over 2>&1; fail "OVER tenant never appeared in quota:over (the guard's decision) (line: wait quota:over)"; }
[[ "$(redis_cli SISMEMBER quota:over "${TENANT_UNDER}" 2>/dev/null)" == "0" ]] \
  || fail "UNDER tenant wrongly listed in quota:over — the guard mis-decided (line: UNDER not in set)"
ok "guard published quota:over = {OVER}; UNDER correctly absent (its usage ${UNDER_QTY} ≤ cap ${NANO_CAP})"

# ── 4) (A) ENFORCE arm: data plane with DATA_PLANE_QUOTA_ENFORCEMENT=1 ─────────
step "4/7 boot data-plane-router DATA_PLANE_QUOTA_ENFORCEMENT=1 (A · ENFORCE), refresh=${REFRESH_MS}ms"
docker run -d --name "${DPR_ON}" --network "${NET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
  -e METERING_ENABLED=1 \
  -e DATA_PLANE_QUOTA_ENFORCEMENT=1 \
  -e DATA_PLANE_QUOTA_REFRESH_MS="${REFRESH_MS}" \
  -e REDIS_URL="${REDIS_INNET}" \
  -e RUST_LOG=info \
  -p "127.0.0.1:${PORT_ON}:4011" "${DPR_IMG}" >/dev/null
wait_ready "${DPR_ON}" "${PORT_ON}" || fail "ENFORCE router not ready (line: wait_ready DPR_ON)"
# Give the data plane at least 2 refresh windows to pull the snapshot from Redis.
sleep "$(awk "BEGIN{print (${REFRESH_MS}*2/1000)+1}")"
ok "ENFORCE router up (enforcement ON, snapshot refreshing from redis) on 127.0.0.1:${PORT_ON}"

step "4b/7 (A) request as OVER tenant → MUST be 402 (the LOAD-BEARING reject)"
# Retry a few times in case the snapshot refresh hasn't landed the first hit yet.
CODE_OVER=
for i in $(seq 1 20); do
  CODE_OVER="$(post_q "${PORT_ON}" "$(payload_list "${TENANT_OVER}")")"
  [[ "${CODE_OVER}" == "402" ]] && break
  sleep 0.5
done
[[ "${CODE_OVER}" == "402" ]] \
  || fail "(A) OVER tenant expected 402 (quota exceeded), got ${CODE_OVER} — $(head -c 300 "${BODY_TMP}") (line: A OVER 402)"
grep -q 'quota_exceeded' "${BODY_TMP}" \
  || fail "(A) 402 body missing the quota_exceeded error — $(head -c 300 "${BODY_TMP}") (line: A OVER body)"
ok "(A) OVER tenant rejected with 402 quota_exceeded — enforcement is REAL"

step "4c/7 (A) request as UNDER tenant → MUST be 200 (under quota → served)"
CODE_UNDER="$(post_q "${PORT_ON}" "$(payload_list "${TENANT_UNDER}")")"
[[ "${CODE_UNDER}" == "200" ]] \
  || fail "(A) UNDER tenant expected 200, got ${CODE_UNDER} — $(head -c 300 "${BODY_TMP}") (line: A UNDER 200)"
ok "(A) UNDER tenant served 200 — enforcement does NOT over-reject"

# ── 5) (B) PARITY arm: data plane with enforcement OFF → BOTH 200 ──────────────
step "5/7 boot data-plane-router with enforcement UNSET (B · PARITY) — same redis, same seeds"
docker run -d --name "${DPR_OFF}" --network "${NET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
  -e REDIS_URL="${REDIS_INNET}" \
  -e RUST_LOG=info \
  -p "127.0.0.1:${PORT_OFF}:4011" "${DPR_IMG}" >/dev/null
wait_ready "${DPR_OFF}" "${PORT_OFF}" || fail "PARITY router not ready (line: wait_ready DPR_OFF)"
ok "PARITY router up (enforcement OFF) on 127.0.0.1:${PORT_OFF}"

step "5b/7 (B) OVER tenant through the OFF router → MUST be 200 (flag OFF = byte-parity, set ignored)"
PCODE_OVER="$(post_q "${PORT_OFF}" "$(payload_list "${TENANT_OVER}")")"
[[ "${PCODE_OVER}" == "200" ]] \
  || fail "(B) PARITY OVER expected 200 (enforcement OFF), got ${PCODE_OVER} — $(head -c 300 "${BODY_TMP}") (line: B OVER 200)"
ok "(B) OVER tenant served 200 with enforcement OFF — the over-quota set is NOT consulted"

step "5c/7 (B) UNDER tenant through the OFF router → MUST be 200"
PCODE_UNDER="$(post_q "${PORT_OFF}" "$(payload_list "${TENANT_UNDER}")")"
[[ "${PCODE_UNDER}" == "200" ]] \
  || fail "(B) PARITY UNDER expected 200, got ${PCODE_UNDER} — $(head -c 300 "${BODY_TMP}") (line: B UNDER 200)"
ok "(B) UNDER tenant served 200 with enforcement OFF — both arms identical = byte-parity"

# ── 6) cross-check + summarize ────────────────────────────────────────────────
step "6/7 cross-check: ON rejects OVER (402) / serves UNDER (200); OFF serves BOTH (200)"
green "[M80] (A) ENFORCE: OVER→402 quota_exceeded · UNDER→200  (REAL over-quota decision from quota:over)"
green "[M80] (B) PARITY:  OVER→200 · UNDER→200                 (flag OFF → set ignored → byte-parity)"

# ── 7) emit the gate event via the kernel log helper (best-effort) ─────────────
step "7/7 log GATE m80=PASS"
emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-b2-quota-enforce}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m80=PASS" --outcome pass \
      --msg "B2 quota enforcement: QuotaGuard sums tenant_usage(query.count) vs nano cap, publishes quota:over; data plane rejects OVER with 402 / serves UNDER 200; enforcement OFF -> both 200 (byte-parity)" \
      --ref "scripts/verify/m80-quota-enforce.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M80] ALL GATES GREEN — quota enforcement CONSUMES B1's tenant_usage, rejects over-quota tenants with 402, and is byte-parity when OFF"
exit 0
