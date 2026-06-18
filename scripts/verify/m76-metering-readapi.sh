#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m76-metering-readapi.sh                            :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M76 — Track-B metering B1c read-back API gate. Proves the READER that sits on
# top of the durable store (B1b / migration 040): the control plane exposes
#   GET /v1/tenants/{id}/usage
# which sums public.tenant_usage per metric over an optional ?metric / ?from /
# ?to window and returns { tenant_id, window, metrics:[{metric,qty,window_count}],
# total_qty } — with the SAME admin/self auth + tenant-scoping as
# GET /v1/tenants/{id}, and tenant_id ALWAYS bound in the WHERE (defense-in-depth
# atop the table's RLS policy).
#
# Unlike a producer/consumer gate, this is a READER: there is no flag to flip —
# when metering is OFF the table is simply empty and the endpoint returns empty
# aggregates, so adding the route changes NO existing path (that IS the parity
# story, asserted in step 6 below).
#
# This gate exercises the route against tenant-control built FROM CURRENT SOURCE,
# over a throwaway postgres carrying the REAL migration 040:
#   postgres  public.tenant_usage  ← the gate SEEDS the ground truth directly here
#         │  (NO producer/consumer — the rows are independently INSERTed by the
#         ▼   gate so the HTTP response can be compared against KNOWN truth)
#   tenant-control  (Go, FROM SOURCE)  GET /v1/tenants/{id}/usage
#         │  SELECT metric, SUM(qty), COUNT(*) … WHERE tenant_id=$1 [AND metric][AND window]
#         ▼
#   HTTP JSON  ← every assertion compares this against the seeded SQL truth
#
# ISOLATED by design (mirrors m75 / m74): a scratch postgres + tenant-control on a
# PRIVATE network, every container/image/network name suffixed with $$, an EXIT-
# trap that removes EVERYTHING. It NEVER touches a mini-baas-* container/network/
# image/volume — safe while the live stack is up. The scratch postgres applies a
# MINIMAL prelude (schema_migrations + auth.current_tenant_id() + the
# authenticated/service_role roles + a minimal public.tenants that tenant-control's
# EnsureSchema requires) and then the REAL migration 040_tenant_usage.sql — so the
# gate proves that migration applies cleanly, then SEEDS tenant_usage with KNOWN
# rows:
#   tenant T : metric query.count → windows w1=3, w2=7   (sum 10)
#   tenant T : metric write.rows  → windows w1=11, w2=13 (sum 24)
#   tenant T2: metric query.count → w1=9999   (the ISOLATION foil — must NEVER
#   tenant T2: metric write.rows  → w2=8888     appear in T's response)
#
#   (POSITIVE) GET /v1/tenants/T/usage → query.count qty=10, write.rows qty=24,
#       total_qty=34, each metric window_count=2 — every number == the seeded SQL
#       truth (SELECTed back independently), never a self-reported value.
#   (FILTER metric) GET …?metric=query.count → exactly one metric, qty=10.
#   (FILTER window) GET …?from=w1&to=w2 (half-open) → only w1 rows: query.count=3,
#       write.rows=11, total=14. Asserted with BOTH RFC3339 and unix-ms bounds.
#   (ISOLATION, load-bearing) T's response NEVER carries 9999/8888; total_qty
#       stays 34. T2's own response carries ONLY 9999+8888. A 401 is returned when
#       a tenant header asks for ANOTHER tenant's id (cross-tenant self-read).
#   (PARITY) a FRESH tenant with zero usage rows → metrics:[] total_qty:0, 200 —
#       the metering-OFF shape, proving the route is additive and empty-by-default.
#
# Fails (exit≠0) on any wrong qty/total/window_count, any leaked T2 row, a missing
# metric, a wrong status, or a non-empty aggregate for an unmetered tenant. Each
# fail names the exact assertion that tripped. Output is tee'd to artifacts/b1c/m76.txt.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)" # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"      # apps/baas
GO_DIR="${INFRA_DIR}/src/control-plane"
MIGRATION_040="${INFRA_DIR}/scripts/migrations/postgresql/040_tenant_usage.sql"
LOG_SH="${BAAS_DIR}/.claude/lib/log.sh"
ART_DIR="${INFRA_DIR}/artifacts/b1c"
ART="${ART_DIR}/m76.txt"

mkdir -p "${ART_DIR}"
exec > >(tee "${ART}") 2>&1

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
step() { cyan "[M76] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[M76] FAIL — $*"
  exit 1
}

PG_IMAGE="${M76_PG_IMAGE:-postgres:16-alpine}"
TC_IMG="m76-tc-$$:scratch"
NET="m76net-$$"
PG="m76-pg-$$"
TC="m76-tc-$$"
PORT="${M76_PORT:-18983}"
PGPW="postgres"
# tenant-control refuses a placeholder/empty INTERNAL_SERVICE_TOKEN; a strong
# scratch-only value satisfies the guard and authorises the admin read path.
SVC_TOKEN="m76-scratch-service-token-$$-$(date +%s)"
DATABASE_URL_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres?sslmode=disable"
BODY_FILE="$(mktemp)" # last HTTP response body (survives cmd-subst subshells)

# Seeded ground truth (independent of any producer) — KNOWN constants the HTTP
# response must reproduce exactly.
TENANT="T-$$"
TENANT2="T2-$$"
QC_W1=3
QC_W2=7 # query.count windows → sum 10
WR_W1=11
WR_W2=13                   # write.rows  windows → sum 24
QC_SUM=$((QC_W1 + QC_W2))  # 10
WR_SUM=$((WR_W1 + WR_W2))  # 24
GRAND=$((QC_SUM + WR_SUM)) # 34
W1_SUM=$((QC_W1 + WR_W1))  # 14 (window-1 only)
T2_QC=9999
T2_WR=8888                  # the isolation foil
T2_TOTAL=$((T2_QC + T2_WR)) # 18887
# Two distinct windows; the half-open [W1,W2) selects ONLY window 1.
W1_TS="2026-06-14T10:00:00Z"
W2_TS="2026-06-14T11:00:00Z"

cleanup() {
  docker rm -fv "${TC}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${TC_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_FILE}" 2>/dev/null || true
}
trap cleanup EXIT

psql_q() { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

# GET helper: echo HTTP status, body→${BODY_FILE}. $1=path  $2..=extra curl args.
# The body is written to a FILE (not a shell var) so it survives the
# `code="$(http_get …)"` command-substitution subshell — a var set inside that
# subshell would be lost in the parent. ${BODY_FILE} is created up top.
http_get() {
  local path="$1"
  shift
  curl -s -o "${BODY_FILE}" -w '%{http_code}' "$@" "http://127.0.0.1:${PORT}${path}"
}
body() { cat "${BODY_FILE}"; }

# jq projector over the last response body.
jqv() { jq -r "$1" <"${BODY_FILE}"; }
# qty / window_count for one metric out of the response.
metric_qty() { jq -r --arg m "$1" '.metrics[] | select(.metric==$m) | .qty' <"${BODY_FILE}"; }
metric_wc() { jq -r --arg m "$1" '.metrics[] | select(.metric==$m) | .window_count' <"${BODY_FILE}"; }

# ── 0) build tenant-control FROM CURRENT SOURCE ────────────────────────────────
step "0/7 build scratch tenant-control image from CURRENT source (B1c)"
DOCKER_BUILDKIT=1 docker build -q \
  --build-arg APP=tenant-control --build-arg PORT="${PORT}" \
  -t "${TC_IMG}" "${GO_DIR}" >/dev/null ||
  fail "scratch tenant-control image build failed — gate must exercise the drafted reader (line: docker build TC)"
ok "tenant-control built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated network + postgres (prelude + REAL migration 040) ──────────────
step "1/7 boot isolated network (${NET}) + postgres (${PG})"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
# alpine entrypoint inits then restarts once — wait for the SECOND "ready".
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "scratch postgres never reached post-init steady state (line: PG ready loop)"
  sleep 0.5
done
ok "postgres up"

step "1b/7 apply the migration-040 PRELUDE (schema_migrations + auth + roles + tenants) then the REAL 040"
# Minimal stand-in for migrations 001-039: the objects 040 + tenant-control's
# EnsureSchema reference (a bare postgres lacks them). The gate then runs the
# ACTUAL 040 file so the migration itself is exercised, not a hand-built table.
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
-- Minimal public.tenants so tenant-control's EnsureSchema passes (it SELECTs the
-- table from information_schema and widens a CHECK constraint; the columns it
-- needs are id + plan).
CREATE TABLE IF NOT EXISTS public.tenants (
  id text PRIMARY KEY, slug text, name text, status text DEFAULT 'active',
  plan text, owner_user_id text, metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now(), updated_at timestamptz DEFAULT now());
SQL
}
for i in $(seq 1 20); do
  prelude && break
  [[ $i -eq 20 ]] && fail "migration prelude never committed (line: prelude loop)"
  sleep 0.5
done
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 <"${MIGRATION_040}" >/dev/null 2>&1 ||
  fail "real migration 040_tenant_usage.sql failed to apply (line: apply 040)"
APPLIED="$(psql_val "SELECT count(*) FROM public.tenant_usage")"
[[ "${APPLIED}" == "0" ]] || fail "tenant_usage should start EMPTY after migration, found '${APPLIED}' (line: 040 empty check)"
MIG="$(psql_val "SELECT version FROM public.schema_migrations WHERE version=40")"
[[ "${MIG}" == "40" ]] || fail "migration 040 did not record version=40 (line: 040 recorded)"
ok "migration 040 applied — public.tenant_usage exists and is empty"

# ── 2) SEED the KNOWN ground truth directly into tenant_usage ───────────────────
step "2/7 SEED tenant_usage: ${TENANT} (2 windows x 2 metrics) + ${TENANT2} (isolation foil)"
seed() {
  psql_q >/dev/null 2>&1 <<SQL
INSERT INTO public.tenant_usage (tenant_id, metric, window_start, qty, idempotency_key) VALUES
  ('${TENANT}','query.count','${W1_TS}', ${QC_W1}, 'm76|${TENANT}|query.count|w1'),
  ('${TENANT}','query.count','${W2_TS}', ${QC_W2}, 'm76|${TENANT}|query.count|w2'),
  ('${TENANT}','write.rows', '${W1_TS}', ${WR_W1}, 'm76|${TENANT}|write.rows|w1'),
  ('${TENANT}','write.rows', '${W2_TS}', ${WR_W2}, 'm76|${TENANT}|write.rows|w2'),
  ('${TENANT2}','query.count','${W1_TS}', ${T2_QC}, 'm76|${TENANT2}|query.count|w1'),
  ('${TENANT2}','write.rows', '${W2_TS}', ${T2_WR}, 'm76|${TENANT2}|write.rows|w2')
ON CONFLICT (idempotency_key) DO NOTHING;
SQL
}
for i in $(seq 1 20); do
  seed && break
  [[ $i -eq 20 ]] && fail "seed never committed (line: seed loop)"
  sleep 0.5
done
# Independently SELECT the seeded truth back — this is the comparison baseline.
DB_QC="$(psql_val "SELECT COALESCE(SUM(qty),0) FROM public.tenant_usage WHERE tenant_id='${TENANT}' AND metric='query.count'")"
DB_WR="$(psql_val "SELECT COALESCE(SUM(qty),0) FROM public.tenant_usage WHERE tenant_id='${TENANT}' AND metric='write.rows'")"
DB_TOT="$(psql_val "SELECT COALESCE(SUM(qty),0) FROM public.tenant_usage WHERE tenant_id='${TENANT}'")"
[[ "${DB_QC}" == "${QC_SUM}" && "${DB_WR}" == "${WR_SUM}" && "${DB_TOT}" == "${GRAND}" ]] ||
  fail "seed/SQL truth mismatch: query.count=${DB_QC}(want ${QC_SUM}) write.rows=${DB_WR}(want ${WR_SUM}) total=${DB_TOT}(want ${GRAND}) (line: SQL truth)"
ok "seeded SQL truth: query.count=${QC_SUM}, write.rows=${WR_SUM}, total=${GRAND}; ${TENANT2} carries ${T2_QC}/${T2_WR}"

# ── 3) boot tenant-control FROM SOURCE ─────────────────────────────────────────
step "3/7 boot tenant-control (FROM SOURCE) on 127.0.0.1:${PORT}"
docker run -d --name "${TC}" --network "${NET}" \
  -e DATABASE_URL="${DATABASE_URL_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TENANT_CONTROL_HOST=0.0.0.0 \
  -e TENANT_CONTROL_PORT="${PORT}" \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -p "127.0.0.1:${PORT}:${PORT}" "${TC_IMG}" >/dev/null
for i in $(seq 1 60); do
  curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/health/live" 2>/dev/null && break
  docker inspect "${TC}" >/dev/null 2>&1 || {
    red "tenant-control exited early:"
    docker logs "${TC}" 2>&1 | tail -20
    fail "tenant-control never started (line: TC ready)"
  }
  [[ $i -eq 60 ]] && {
    red "tenant-control logs:"
    docker logs "${TC}" 2>&1 | tail -20
    fail "tenant-control never became ready (line: TC ready loop)"
  }
  sleep 0.5
done
ok "tenant-control up"

# ── 4) POSITIVE: summed qty per metric == seeded truth, total == grand sum ─────
step "4/7 POSITIVE — GET /v1/tenants/${TENANT}/usage (admin token)"
code="$(http_get "/v1/tenants/${TENANT}/usage" -H "X-Service-Token: ${SVC_TOKEN}")"
[[ "${code}" == "200" ]] || fail "POSITIVE expected 200, got ${code} — $(body) (line: POSITIVE status)"
RID="$(jqv '.tenant_id')"
[[ "${RID}" == "${TENANT}" ]] || fail "POSITIVE tenant_id=${RID}, want ${TENANT} (line: POSITIVE tenant_id)"
H_QC="$(metric_qty query.count)"
H_WR="$(metric_qty write.rows)"
H_TOT="$(jqv '.total_qty')"
[[ "${H_QC}" == "${DB_QC}" ]] || fail "POSITIVE query.count qty=${H_QC} != SQL truth ${DB_QC} (line: POSITIVE qc)"
[[ "${H_WR}" == "${DB_WR}" ]] || fail "POSITIVE write.rows qty=${H_WR} != SQL truth ${DB_WR} (line: POSITIVE wr)"
[[ "${H_TOT}" == "${DB_TOT}" ]] || fail "POSITIVE total_qty=${H_TOT} != SQL truth ${DB_TOT} (line: POSITIVE total)"
[[ "$(metric_wc query.count)" == "2" && "$(metric_wc write.rows)" == "2" ]] ||
  fail "POSITIVE window_count != 2 per metric (qc=$(metric_wc query.count) wr=$(metric_wc write.rows)) (line: POSITIVE wc)"
ok "POSITIVE: query.count=${H_QC}, write.rows=${H_WR}, total_qty=${H_TOT}, window_count=2 — all == seeded SQL truth"

# ── 5) FILTER: ?metric= and ?from/&to= (RFC3339 + unix-ms) narrow correctly ────
step "5/7 FILTER — ?metric= and ?from/&to= window (half-open)"
code="$(http_get "/v1/tenants/${TENANT}/usage?metric=query.count" -H "X-Service-Token: ${SVC_TOKEN}")"
[[ "${code}" == "200" ]] || fail "FILTER metric expected 200, got ${code} (line: FILTER metric status)"
N_METRICS="$(jqv '.metrics | length')"
[[ "${N_METRICS}" == "1" && "$(metric_qty query.count)" == "${QC_SUM}" ]] ||
  fail "FILTER ?metric=query.count returned ${N_METRICS} metric(s) / qty=$(metric_qty query.count), want 1 / ${QC_SUM} (line: FILTER metric)"
# Independently confirm against SQL.
DB_W1_QC="$(psql_val "SELECT COALESCE(SUM(qty),0) FROM public.tenant_usage WHERE tenant_id='${TENANT}' AND metric='query.count' AND window_start>='${W1_TS}' AND window_start<'${W2_TS}'")"
DB_W1_WR="$(psql_val "SELECT COALESCE(SUM(qty),0) FROM public.tenant_usage WHERE tenant_id='${TENANT}' AND metric='write.rows' AND window_start>='${W1_TS}' AND window_start<'${W2_TS}'")"
DB_W1_TOT="$(psql_val "SELECT COALESCE(SUM(qty),0) FROM public.tenant_usage WHERE tenant_id='${TENANT}' AND window_start>='${W1_TS}' AND window_start<'${W2_TS}'")"
ok "FILTER ?metric=query.count → 1 metric, qty=${QC_SUM}"

# RFC3339 window [W1,W2) → window-1 rows only.
code="$(http_get "/v1/tenants/${TENANT}/usage?from=${W1_TS}&to=${W2_TS}" -H "X-Service-Token: ${SVC_TOKEN}")"
[[ "${code}" == "200" ]] || fail "FILTER window(RFC3339) expected 200, got ${code} (line: FILTER win status)"
[[ "$(metric_qty query.count)" == "${DB_W1_QC}" && "$(metric_qty write.rows)" == "${DB_W1_WR}" && "$(jqv '.total_qty')" == "${DB_W1_TOT}" ]] ||
  fail "FILTER window(RFC3339): qc=$(metric_qty query.count)/${DB_W1_QC} wr=$(metric_qty write.rows)/${DB_W1_WR} total=$(jqv '.total_qty')/${DB_W1_TOT} (line: FILTER win rfc)"
[[ "$(jqv '.total_qty')" == "${W1_SUM}" ]] || fail "FILTER window total=${W1_SUM} expected (line: FILTER win sum)"
ok "FILTER [${W1_TS},${W2_TS}) RFC3339 → window-1 only: query.count=${DB_W1_QC}, write.rows=${DB_W1_WR}, total=${DB_W1_TOT}"

# unix-ms window MUST narrow identically (the reader accepts RFC3339 or unix-ms).
W1_MS="$(date -u -d "${W1_TS}" +%s%3N)"
W2_MS="$(date -u -d "${W2_TS}" +%s%3N)"
code="$(http_get "/v1/tenants/${TENANT}/usage?from=${W1_MS}&to=${W2_MS}" -H "X-Service-Token: ${SVC_TOKEN}")"
[[ "${code}" == "200" ]] || fail "FILTER window(unix-ms) expected 200, got ${code} (line: FILTER win ms status)"
[[ "$(jqv '.total_qty')" == "${W1_SUM}" ]] ||
  fail "FILTER window(unix-ms) total=$(jqv '.total_qty') != ${W1_SUM} — unix-ms must narrow identically to RFC3339 (line: FILTER win ms)"
ok "FILTER unix-ms [${W1_MS},${W2_MS}) → total=${W1_SUM} (identical to RFC3339)"

# ── 6) ISOLATION (load-bearing): T never sees T2; cross-tenant self-read = 401 ──
step "6/7 ISOLATION — ${TENANT}'s response NEVER includes ${TENANT2}'s qty"
code="$(http_get "/v1/tenants/${TENANT}/usage" -H "X-Service-Token: ${SVC_TOKEN}")"
[[ "${code}" == "200" ]] || fail "ISOLATION fetch expected 200, got ${code} (line: ISO status)"
# Neither T2's qtys nor T2's grand total may appear ANYWHERE in T's response.
grep -q "${T2_QC}" "${BODY_FILE}" && fail "ISOLATION BREACH — ${TENANT} response contains ${TENANT2}'s qty ${T2_QC} (line: ISO leak qc)"
grep -q "${T2_WR}" "${BODY_FILE}" && fail "ISOLATION BREACH — ${TENANT} response contains ${TENANT2}'s qty ${T2_WR} (line: ISO leak wr)"
[[ "$(jqv '.total_qty')" == "${GRAND}" ]] || fail "ISOLATION — ${TENANT} total_qty=$(jqv '.total_qty') drifted from ${GRAND} (T2 contamination?) (line: ISO total)"
ok "${TENANT} total_qty=${GRAND}, no trace of ${TENANT2}'s ${T2_QC}/${T2_WR}"

# T2's OWN read returns ONLY T2's truth (proves scoping both ways).
code="$(http_get "/v1/tenants/${TENANT2}/usage" -H "X-Service-Token: ${SVC_TOKEN}")"
[[ "${code}" == "200" ]] || fail "ISOLATION ${TENANT2} fetch expected 200, got ${code} (line: ISO T2 status)"
[[ "$(jqv '.total_qty')" == "${T2_TOTAL}" ]] ||
  fail "ISOLATION ${TENANT2} total_qty=$(jqv '.total_qty') != ${T2_TOTAL} (only its own rows) (line: ISO T2 total)"
grep -q "\"qty\":${GRAND}\b" "${BODY_FILE}" && fail "ISOLATION BREACH — ${TENANT2} response shows ${TENANT}'s data (line: ISO T2 leak)"
ok "${TENANT2}'s own response carries ONLY ${T2_TOTAL} (its rows), never ${TENANT}'s"

# Self auth: a tenant header may read ITS OWN id (200) but NOT another's (401).
code="$(http_get "/v1/tenants/${TENANT}/usage" -H "X-Baas-Tenant-Id: ${TENANT}")"
[[ "${code}" == "200" ]] || fail "self-read with matching X-Baas-Tenant-Id expected 200, got ${code} (line: ISO self ok)"
code="$(http_get "/v1/tenants/${TENANT2}/usage" -H "X-Baas-Tenant-Id: ${TENANT}")"
[[ "${code}" == "401" ]] || fail "cross-tenant self-read expected 401, got ${code} — a tenant must not read ANOTHER's usage (line: ISO cross 401)"
code="$(http_get "/v1/tenants/${TENANT}/usage")"
[[ "${code}" == "401" ]] || fail "unauthenticated read expected 401, got ${code} (line: ISO noauth 401)"
ok "self-read scoping: own=200, cross-tenant=401, unauthenticated=401"

# ── 7) PARITY: an unmetered tenant returns empty aggregates (the OFF shape) ─────
step "7/7 PARITY — a tenant with ZERO usage rows returns metrics:[] total_qty:0"
FRESH="UNMETERED-$$"
DB_FRESH="$(psql_val "SELECT count(*) FROM public.tenant_usage WHERE tenant_id='${FRESH}'")"
[[ "${DB_FRESH}" == "0" ]] || fail "PARITY precondition: ${FRESH} should have 0 rows, found ${DB_FRESH} (line: PARITY precond)"
code="$(http_get "/v1/tenants/${FRESH}/usage" -H "X-Service-Token: ${SVC_TOKEN}")"
[[ "${code}" == "200" ]] || fail "PARITY unmetered tenant expected 200, got ${code} (line: PARITY status)"
[[ "$(jqv '.metrics | length')" == "0" && "$(jqv '.total_qty')" == "0" ]] ||
  fail "PARITY unmetered tenant: metrics=$(jqv '.metrics') total=$(jqv '.total_qty'), want []/0 (line: PARITY empty)"
grep -q '"metrics":\[\]' "${BODY_FILE}" ||
  fail "PARITY empty metrics must serialize as [] (got $(body)) (line: PARITY shape)"
ok "unmetered tenant → metrics:[], total_qty:0, 200 — the metering-OFF shape (route is additive, empty-by-default)"

# ── done ───────────────────────────────────────────────────────────────────────
green "[M76] POSITIVE: GET /v1/tenants/${TENANT}/usage → query.count=${QC_SUM}, write.rows=${WR_SUM}, total_qty=${GRAND} (each == seeded SQL truth)"
green "[M76] FILTER: ?metric= → 1 metric; ?from/&to= (RFC3339 + unix-ms) → window-1 only, total=${W1_SUM}"
green "[M76] ISOLATION: ${TENANT} never sees ${TENANT2}'s ${T2_QC}/${T2_WR}; cross-tenant self-read = 401"
green "[M76] PARITY: an unmetered tenant returns metrics:[] total_qty:0 (additive route, empty-by-default)"
green "[M76] ALL GATES GREEN — metering read-back API (B1c) is correct + tenant-isolated, HTTP JSON == independently-seeded SQL truth"

# Log PASS through the agent helper (JSONL; never hand-rolled).
if [[ -f "${LOG_SH}" ]]; then
  (
    cd "${BAAS_DIR}" &&
      AGENT_RUN="${AGENT_RUN:-m76-$$}" AGENT_TASK="${AGENT_TASK:-metering-readapi-b1c}" \
        AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_PHASE="${AGENT_PHASE:-PROVE}" \
        bash -c 'source .claude/lib/log.sh
      log_event REPORT --outcome PASS --gate m76=PASS \
        --ref artifacts/b1c/m76.txt \
        --msg "B1c read-back API: HTTP JSON == seeded SQL truth, tenant-isolated, empty-by-default"'
  ) >/dev/null 2>&1 || true
fi
