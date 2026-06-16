#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m82-billing-report.sh                              :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M82 — Track-B billing reporter (B3) live gate. Proves per-tenant usage is pushed
# to Stripe's billing meters end-to-end, that only BILLABLE windows of BILLED
# tenants are sent, that a re-tick is IDEMPOTENT (the local sent-ledger, not Stripe,
# guarantees no double-send), and that it is byte-parity when OFF. It CONSUMES B1's
# metering store (public.tenant_usage) + the B3 tenant→customer map
# (public.tenant_billing) — it does NOT re-meter:
#
#   control-plane BillingReporter (Go, BILLING_ENABLED=1)
#     │  every interval: SELECT un-reported usage windows (tenant_usage LEFT JOIN
#     │  billing_reported) for tenants WITH a Stripe customer (tenant_billing) and a
#     │  billable metric (BILLING_METER_*), POST one meter event per window to
#     ▼  Stripe (value = window qty, identifier = window idempotency_key), mark sent.
#   mock Stripe (records POST /v1/billing/meter_events; serves GET /_events)
#
#   (A) REPORT arm (flags ON): the mock receives EXACTLY the billable windows of the
#       BILLED tenant — right customer / value / event_name / identifier. A second
#       tick sends NOTHING new (count unchanged) = idempotent (the LOAD-BEARING
#       proof — a gate that only shows one send is vacuous). NON-billable metric
#       (query.rows, unconfigured) and a tenant WITHOUT a tenant_billing row are
#       NOT sent (the load-bearing negatives, read off the mock's wire).
#   (B) PARITY arm (BILLING_ENABLED unset): a separate mock receives ZERO events —
#       the flag-OFF path makes no Stripe call at all, the no-behavior-change base.
#
# ISOLATED by design (mirrors m80): scratch postgres (migration-040 prelude + the
# REAL 040 + the REAL 041) + a Go orchestrator built FROM CURRENT source + two
# zero-dep node mock-Stripe servers, ALL on a PRIVATE network, every name suffixed
# with $$, an EXIT-trap removing EVERYTHING. It NEVER touches a mini-baas-*
# container/network/image/volume and NEVER edits the live docker-compose.yml.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                  # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                       # apps/baas
GO_DIR="${INFRA_DIR}/go/control-plane"
MIGRATION_040="${INFRA_DIR}/scripts/migrations/postgresql/040_tenant_usage.sql"
MIGRATION_041="${INFRA_DIR}/scripts/migrations/postgresql/041_tenant_billing.sql"
MOCK_DIR="${SCRIPT_DIR}/m82-mock-stripe"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M82] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M82] FAIL — $*"; exit 1; }

PG_IMAGE="${M82_PG_IMAGE:-postgres:16-alpine}"
NODE_IMAGE="${M82_NODE_IMAGE:-node:22-alpine}"
ORCH_IMG="m82-orch-$$:scratch"
NET="m82net-$$"
PG="m82-pg-$$"
MOCK_ON="m82-mock-on-$$"
MOCK_OFF="m82-mock-off-$$"
ORCH_ON="m82-orch-on-$$"
ORCH_OFF="m82-orch-off-$$"
PORT_ON="${M82_PORT_ON:-18982}"
PORT_OFF="${M82_PORT_OFF:-18983}"
PGPW="postgres"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
INTERVAL_MS="${M82_INTERVAL_MS:-700}"
EVENT_NAME="grobase_query_count"
T1="m82-t1-$$"          # BILLED tenant (has a tenant_billing row + non-empty customer)
T2="m82-t2-$$"          # UNBILLED tenant (usage but NO tenant_billing row → skipped)
T3="m82-t3-$$"          # UNBILLED tenant (tenant_billing row but EMPTY customer → skipped)
CUS1="cus_${T1}"
K1="m82-k1-$$"; K2="m82-k2-$$"; KROWS="m82-krows-$$"; KT2="m82-kt2-$$"; KT3="m82-kt3-$$"
SVC_TOKEN="m82-internal-service-token-$$"
EVENTS_TMP="$(mktemp)"

cleanup() {
  docker rm -fv "${ORCH_ON}" "${ORCH_OFF}" "${MOCK_ON}" "${MOCK_OFF}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${ORCH_IMG}" >/dev/null 2>&1 || true
  rm -f "${EVENTS_TMP}" 2>/dev/null || true
}
trap cleanup EXIT

psql_q()   { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

# GET the mock's recorded events into EVENTS_TMP; echo the event count. The grep is
# wrapped in `|| true` so ZERO matches (the expected PARITY result) does not trip
# pipefail+set -e — counting "no events" is a normal outcome, not a failure.
mock_events() { # $1=port
  curl -s -o "${EVENTS_TMP}" "http://127.0.0.1:$1/_events" 2>/dev/null || true
  { grep -o '"identifier":"[^"]*"' "${EVENTS_TMP}" 2>/dev/null || true; } | wc -l | tr -d '[:space:]'
}

wait_log() { # $1=container $2=needle $3=tries
  local i
  for i in $(seq 1 "${3:-60}"); do
    docker logs "$1" 2>&1 | grep -q "$2" && return 0
    docker inspect "$1" >/dev/null 2>&1 || return 1
    sleep 0.5
  done
  return 1
}

# ── 0) build the scratch orchestrator FROM CURRENT (drafted) source ────────────
step "0/7 build scratch Go orchestrator from CURRENT source (the B3 BillingReporter)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=orchestrator --build-arg PORT=3060 \
  -t "${ORCH_IMG}" "${GO_DIR}" >/dev/null \
  || fail "scratch orchestrator image build failed (line: docker build ORCH)"
ok "orchestrator built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated net + postgres (prelude + REAL 040 + REAL 041) ─────────────────
step "1/7 boot isolated net (${NET}): postgres + 2 mock-stripe servers"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
docker run -d --name "${MOCK_ON}"  --network "${NET}" -e PORT=8080 -v "${MOCK_DIR}":/app:ro \
  -p "127.0.0.1:${PORT_ON}:8080"  "${NODE_IMAGE}" node /app/server.mjs >/dev/null
docker run -d --name "${MOCK_OFF}" --network "${NET}" -e PORT=8080 -v "${MOCK_DIR}":/app:ro \
  -p "127.0.0.1:${PORT_OFF}:8080" "${NODE_IMAGE}" node /app/server.mjs >/dev/null
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "scratch postgres never reached steady state (line: PG ready loop)"
  sleep 0.5
done
for i in $(seq 1 60); do
  curl -fsS -o /dev/null "http://127.0.0.1:${PORT_ON}/_health" 2>/dev/null \
    && curl -fsS -o /dev/null "http://127.0.0.1:${PORT_OFF}/_health" 2>/dev/null && break
  [[ $i -eq 60 ]] && fail "mock-stripe servers never became ready (line: mock ready loop)"
  sleep 0.5
done
ok "postgres + both mock-stripe servers up"

step "1b/7 apply migration-040 PRELUDE, then REAL 040, then REAL 041"
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
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "${MIGRATION_041}" >/dev/null 2>&1 \
  || fail "real migration 041_tenant_billing.sql failed to apply (line: apply 041)"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_billing")" == "0" ]]   || fail "tenant_billing should start EMPTY (line: 041 empty check)"
[[ "$(psql_val "SELECT count(*) FROM public.billing_reported")" == "0" ]] || fail "billing_reported should start EMPTY (line: 041 ledger empty)"
ok "migrations 040 + 041 applied — tenant_usage / tenant_billing / billing_reported exist and are empty"

# ── 2) seed: T1 billed (cus), 2 billable windows; a NON-billable metric; T2 unbilled
step "2/7 seed tenant_billing(${T1}→${CUS1}) + tenant_usage (T1 query.count×2 + T1 query.rows + T2 query.count)"
MONTH="$(date -u +%Y-%m-01)"
seed() {
  psql_q >/dev/null 2>&1 <<SQL
INSERT INTO public.tenant_billing(tenant_id, stripe_customer_id, plan) VALUES
  ('${T1}','${CUS1}','pro'),
  ('${T3}','',       'pro')   -- billing row but EMPTY customer → must be skipped
  ON CONFLICT (tenant_id) DO UPDATE SET stripe_customer_id=EXCLUDED.stripe_customer_id;
INSERT INTO public.tenant_usage(tenant_id, metric, window_start, qty, idempotency_key) VALUES
  ('${T1}','query.count','${MONTH}T00:00:00Z', 10, '${K1}'),
  ('${T1}','query.count','${MONTH}T01:00:00Z', 20, '${K2}'),
  ('${T1}','query.rows', '${MONTH}T00:00:00Z', 99, '${KROWS}'),   -- non-billable metric → must be skipped
  ('${T2}','query.count','${MONTH}T00:00:00Z', 77, '${KT2}'),     -- no tenant_billing row → must be skipped
  ('${T3}','query.count','${MONTH}T00:00:00Z', 55, '${KT3}')      -- empty customer → must be skipped
  ON CONFLICT (idempotency_key) DO NOTHING;
SQL
}
for i in $(seq 1 20); do seed && break; [[ $i -eq 20 ]] && fail "seed never committed (line: seed loop)"; sleep 0.5; done
[[ "$(psql_val "SELECT count(*) FROM public.tenant_usage")" == "5" ]] || fail "expected 5 seeded usage rows (line: verify seed)"
ok "seeded: T1 2 billable (10,20) + 1 non-billable (99); T2 usage but NO billing row (77); T3 billing row but EMPTY customer (55)"

# ── 3) (B) PARITY arm: orchestrator with BILLING_ENABLED unset → ZERO events ───
step "3/7 (B · PARITY) boot orchestrator BILLING_ENABLED unset → mock_off MUST stay at 0 events"
docker run -d --name "${ORCH_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e ORCHESTRATOR_SERVICES=billing \
  -e ORCHESTRATOR_PORT=3060 \
  -e METERING_ENABLED=1 \
  -e STRIPE_API_BASE="http://${MOCK_OFF}:8080" \
  -e STRIPE_API_KEY=sk_test_off \
  -e BILLING_METER_QUERY_COUNT="${EVENT_NAME}" \
  -e BILLING_REPORT_INTERVAL_MS="${INTERVAL_MS}" \
  -e LOG_LEVEL=debug \
  "${ORCH_IMG}" >/dev/null
wait_log "${ORCH_OFF}" "billing disabled" 60 \
  || { red "orch_off logs:"; docker logs "${ORCH_OFF}" 2>&1 | tail -20; fail "reporter did not report disabled with BILLING_ENABLED off (line: wait_log OFF disabled)"; }
sleep "$(awk "BEGIN{print (${INTERVAL_MS}*3/1000)+1}")"
OFF_COUNT="$(mock_events "${PORT_OFF}")"
[[ "${OFF_COUNT}" == "0" ]] \
  || fail "(B) PARITY: mock_off received ${OFF_COUNT} events with BILLING_ENABLED off — expected 0 (line: B zero)"
ok "(B) PARITY: BILLING_ENABLED off → zero Stripe calls = byte-parity"

# ── 4) (A) REPORT arm: orchestrator with BILLING_ENABLED=1 → exactly 2 events ──
step "4/7 (A · REPORT) boot orchestrator BILLING_ENABLED=1 → push billable windows to mock_on"
docker run -d --name "${ORCH_ON}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e ORCHESTRATOR_SERVICES=billing \
  -e ORCHESTRATOR_PORT=3060 \
  -e METERING_ENABLED=1 \
  -e BILLING_ENABLED=1 \
  -e STRIPE_API_BASE="http://${MOCK_ON}:8080" \
  -e STRIPE_API_KEY=sk_test_on \
  -e BILLING_METER_QUERY_COUNT="${EVENT_NAME}" \
  -e BILLING_REPORT_INTERVAL_MS="${INTERVAL_MS}" \
  -e LOG_LEVEL=debug \
  "${ORCH_IMG}" >/dev/null
wait_log "${ORCH_ON}" "billing enabled" 60 \
  || { red "orch_on logs:"; docker logs "${ORCH_ON}" 2>&1 | tail -20; fail "BillingReporter never enabled (line: wait_log ON enabled)"; }
ok "BillingReporter enabled — reporting un-reported windows"

step "4b/7 (A) wait for mock_on to receive EXACTLY 2 billable windows"
ON_COUNT=0
for i in $(seq 1 40); do
  ON_COUNT="$(mock_events "${PORT_ON}")"
  [[ "${ON_COUNT}" == "2" ]] && break
  sleep 0.5
done
[[ "${ON_COUNT}" == "2" ]] \
  || { red "mock_on events:"; cat "${EVENTS_TMP}"; fail "(A) expected 2 meter events, got ${ON_COUNT} (line: A count==2)"; }
ok "(A) mock_on received exactly 2 events"

step "4c/7 (A) verify the events: customer ${CUS1}, values {10,20}, event_name ${EVENT_NAME}, identifiers {K1,K2}"
mock_events "${PORT_ON}" >/dev/null    # refresh EVENTS_TMP
grep -q "\"customer\":\"${CUS1}\""        "${EVENTS_TMP}" || fail "(A) no event for customer ${CUS1} (line: A customer)"
grep -q "\"event_name\":\"${EVENT_NAME}\"" "${EVENTS_TMP}" || fail "(A) event_name ${EVENT_NAME} missing (line: A event_name)"
grep -q "\"value\":\"10\""                "${EVENTS_TMP}" || fail "(A) value 10 missing (line: A value10)"
grep -q "\"value\":\"20\""                "${EVENTS_TMP}" || fail "(A) value 20 missing (line: A value20)"
grep -q "\"identifier\":\"${K1}\""        "${EVENTS_TMP}" || fail "(A) identifier K1 missing (line: A K1)"
grep -q "\"identifier\":\"${K2}\""        "${EVENTS_TMP}" || fail "(A) identifier K2 missing (line: A K2)"
# Load-bearing NEGATIVES — non-billable metric / no-billing-row / empty-customer MUST be absent.
if grep -q "\"value\":\"99\"" "${EVENTS_TMP}"; then fail "(A) query.rows (value 99) was wrongly billed — non-billable metric leaked (line: A neg99)"; fi
if grep -q "\"value\":\"77\"" "${EVENTS_TMP}"; then fail "(A) T2 usage (value 77) was wrongly billed — tenant has no tenant_billing row (line: A neg77)"; fi
if grep -q "\"value\":\"55\"" "${EVENTS_TMP}"; then fail "(A) T3 usage (value 55) was wrongly billed — tenant_billing customer is empty (line: A neg55)"; fi
if grep -q "${T2}" "${EVENTS_TMP}"; then fail "(A) unbilled tenant T2 leaked into a meter event (line: A negT2)"; fi
if grep -q "${T3}" "${EVENTS_TMP}"; then fail "(A) empty-customer tenant T3 leaked into a meter event (line: A negT3)"; fi
ok "(A) events correct; non-billable (99), no-billing-row (77), and empty-customer (55) all correctly NOT sent"

step "4d/7 (A · IDEMPOTENT) wait 3 more intervals → mock_on count MUST STILL be 2 (no re-send)"
sleep "$(awk "BEGIN{print (${INTERVAL_MS}*3/1000)+1}")"
ON_COUNT2="$(mock_events "${PORT_ON}")"
[[ "${ON_COUNT2}" == "2" ]] \
  || fail "(A) idempotency broken — count grew to ${ON_COUNT2} after re-ticks (the sent-ledger must suppress re-sends) (line: A idempotent)"
ok "(A) IDEMPOTENT — re-ticks sent nothing new (still 2); the billing_reported ledger suppresses re-sends"

# ── 5) ledger cross-check: exactly the 2 billable windows recorded as reported ─
step "5/7 cross-check public.billing_reported = exactly {K1,K2}"
[[ "$(psql_val "SELECT count(*) FROM public.billing_reported")" == "2" ]] \
  || fail "billing_reported should have exactly 2 rows (line: ledger count)"
[[ "$(psql_val "SELECT count(*) FROM public.billing_reported WHERE idempotency_key IN ('${K1}','${K2}')")" == "2" ]] \
  || fail "billing_reported should contain exactly K1 and K2 (line: ledger members)"
[[ "$(psql_val "SELECT count(*) FROM public.billing_reported WHERE idempotency_key IN ('${KROWS}','${KT2}','${KT3}')")" == "0" ]] \
  || fail "billing_reported wrongly contains a skipped window (query.rows / T2 / T3) (line: ledger negatives)"
ok "ledger = {K1,K2}; skipped windows (query.rows, T2 no-row, T3 empty-customer) correctly absent"

# ── 6) summarize ──────────────────────────────────────────────────────────────
step "6/7 summary"
green "[M82] (A) REPORT: T1's 2 billable windows → 2 meter events (cus, value, event_name, identifier correct); re-tick → 0 new = idempotent"
green "[M82] (A) NEG:    query.rows (unconfigured) + T2 (no tenant_billing) → NOT billed"
green "[M82] (B) PARITY: BILLING_ENABLED off → 0 meter events = byte-parity"

# ── 7) emit the gate event via the kernel log helper (best-effort) ─────────────
step "7/7 log GATE m82=PASS"
emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-b3-billing-report}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m82=PASS" --outcome pass \
      --msg "B3 billing: reporter consumes tenant_usage+tenant_billing, POSTs 1 Stripe meter event per un-reported window (right cus/value/event_name/identifier), idempotent via billing_reported ledger; non-billable metric + unbilled tenant skipped; BILLING_ENABLED off -> 0 events (byte-parity)" \
      --ref "scripts/verify/m82-billing-report.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M82] ALL GATES GREEN — B3 billing reporter pushes B1 usage to Stripe meters, idempotently, billable-only, and is byte-parity when OFF"
exit 0
