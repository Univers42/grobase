#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m89-spend-caps.sh                                  :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M89 — Track-B B7.8 SPEND CAPS (+ B7.2 QUOTA_STAGE) control-plane gate. Proves the
# cloud-go-live cost-runaway guard HALTS a budget-exceeding tenant before runaway and
# is byte-parity when OFF. It CONSUMES B1's metering store (public.tenant_usage) and
# the B7.8 budgets table (public.tenant_budgets, migration 045) — it does NOT re-meter:
#
#   control-plane spend-cap Guard (Go, SPEND_CAPS_ENABLED=1)
#     │  every interval: spend_cents = Σ(tenant_usage.qty × SPEND_RATE_<metric>)
#     │  per tenant vs its tenant_budgets.budget_cents
#     │   • spend ≥ budget          → tenant ∈ Redis `spend:over` (HARD cap → data
#     │                                plane halts billable service; same cheap
#     │                                SMEMBERS-snapshot pattern as B2 quota:over)
#     │   • spend ≥ 80% of budget   → 80% ALERT fires ONCE per period (recorded in
#     ▼                                tenant_budgets.alert_fired_period)
#   redis  (the `spend:over` SET — the data plane's hot-path enforcement source)
#
#   (A) ENABLED arm (SPEND_CAPS_ENABLED=1):
#       • the OVER-budget tenant lands in `spend:over`            (LOAD-BEARING halt)
#       • the UNDER-budget tenant is ABSENT from `spend:over`     (no over-reject)
#       • the 80% ALERT fires EXACTLY ONCE (alert_fired_period stamped + 1 log line)
#         → re-evaluation does NOT re-fire (once-per-period)
#   (B) PARITY arm (SPEND_CAPS_ENABLED unset): the guard never evaluates — `spend:over`
#       is NEVER written and NO alert ever fires, regardless of the seeded budgets
#       → byte-identical to today (the no-behavior-change baseline).
#   (C) QUOTA_STAGE transition assertion (B7.2): the staged promotion ladder
#       off→shadow→warn→enforce maps an OVER-quota tenant to allow→shadow→header→402
#       in the pure decision unit, asserted via `go test` on internal/quotastage.
#
# Budget seeding is INDEPENDENT ground truth: the OVER tenant gets usage worth MORE
# than its budget; the UNDER tenant gets usage worth WELL under (but ≥80% would alert,
# so UNDER is set < 80% too). The SPEND_RATE is fixed so spend = qty × rate is exact.
#
# ISOLATED by design (mirrors m80): scratch postgres (040+045 prelude) + redis + a Go
# orchestrator built FROM CURRENT source, ALL on a PRIVATE network, names suffixed
# with $$, an EXIT-trap removing EVERYTHING. It NEVER touches a mini-baas-* container/
# network/image/volume and NEVER edits the live docker-compose.yml. The data plane is
# NOT exercised here: consuming `spend:over` in Rust is a SEPARATE slice; this gate
# proves the CONTROL-PLANE decision (the set + the alert) — exactly what B7.8 ships.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                  # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                       # apps/baas
GO_DIR="${INFRA_DIR}/go/control-plane"
MIGRATION_040="${INFRA_DIR}/scripts/migrations/postgresql/040_tenant_usage.sql"
MIGRATION_045="${INFRA_DIR}/scripts/migrations/postgresql/045_tenant_safety.sql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M89] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M89] FAIL — $*"; exit 1; }

REDIS_IMAGE="${M89_REDIS_IMAGE:-redis:7-alpine}"
PG_IMAGE="${M89_PG_IMAGE:-postgres:16-alpine}"
GO_IMAGE="${M89_GO_IMAGE:-golang:1.24}"
ORCH_IMG="m89-orch-$$:scratch"
NET="m89net-$$"
PG="m89-pg-$$"
REDIS="m89-redis-$$"
ORCH_ON="m89-orch-on-$$"     # spend-cap guard (SPEND_CAPS_ENABLED=1)
ORCH_OFF="m89-orch-off-$$"   # parity arm (flag unset)
PGPW="postgres"
TENANT_OVER="m89-over-$$"
TENANT_UNDER="m89-under-$$"
METRIC="query.count"
# Money model: 1 milli-cent / query → SPEND_RATE_QUERY_COUNT=0.001 (cents/unit).
# spend_cents = qty × 0.001. Budget = 100 cents ($1.00).
SPEND_RATE="0.001"
BUDGET_CENTS=100
# OVER: qty so spend ≥ budget → 200000 × 0.001 = 200 cents > 100.
OVER_QTY=200000
# UNDER: spend < 80% of budget → < 80 cents → < 80000 qty. Use 50000 → 50 cents.
UNDER_QTY=50000
GUARD_MS="${M89_GUARD_MS:-700}"
REDIS_INNET="redis://${REDIS}:6379"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"

cleanup() {
  docker rm -fv "${ORCH_ON}" "${ORCH_OFF}" "${PG}" "${REDIS}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${ORCH_IMG}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

psql_q()   { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
redis_cli() { docker exec -i "${REDIS}" redis-cli "$@"; }

wait_log() { # $1=container  $2=needle  $3=tries
  local i
  for i in $(seq 1 "${3:-60}"); do
    docker logs "$1" 2>&1 | grep -q "$2" && return 0
    docker inspect "$1" >/dev/null 2>&1 || return 1
    sleep 0.5
  done
  return 1
}

# ── 0) build the scratch orchestrator FROM CURRENT (drafted) source ────────────
step "0/8 build scratch Go orchestrator from CURRENT source (the B7.8 spend-cap code)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=orchestrator --build-arg PORT=3060 \
  -t "${ORCH_IMG}" "${GO_DIR}" >/dev/null \
  || fail "scratch orchestrator image build failed — gate must exercise the drafted spend-cap Guard"
ok "orchestrator built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 0b) prove the QUOTA_STAGE (B7.2) transition ladder via the unit test ───────
step "0b/8 (C) assert B7.2 QUOTA_STAGE off→shadow→warn→enforce transition (go test internal/quotastage)"
docker run --rm -v "${GO_DIR}":/src -w /src -e GOFLAGS=-mod=mod -e GOCACHE=/tmp/gc -e GOMODCACHE=/tmp/gm \
  "${GO_IMAGE}" sh -c 'go test ./internal/quotastage/... 2>&1' \
  || fail "QUOTA_STAGE transition unit test failed — staged promotion ladder is not proven"
ok "QUOTA_STAGE ladder proven: over-quota → allow(off)→shadowlog(shadow)→header(warn)→block(enforce); under-quota → allow always"

# ── 1) isolated network + redis + postgres (prelude + REAL 040 + 045) ──────────
step "1/8 boot isolated net (${NET}): redis + postgres"
docker network create "${NET}" >/dev/null
docker run -d --name "${REDIS}" --network "${NET}" "${REDIS_IMAGE}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
for i in $(seq 1 60); do redis_cli PING 2>/dev/null | grep -q PONG && break; [[ $i -eq 60 ]] && fail "scratch redis never PONGed"; sleep 0.5; done
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "scratch postgres never reached steady state"
  sleep 0.5
done
ok "redis + postgres up"

step "1b/8 apply migration prelude then the REAL 040 + 045"
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
for i in $(seq 1 20); do prelude && break; [[ $i -eq 20 ]] && fail "migration prelude never committed"; sleep 0.5; done
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "${MIGRATION_040}" >/dev/null 2>&1 \
  || fail "real migration 040_tenant_usage.sql failed to apply"
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "${MIGRATION_045}" >/dev/null 2>&1 \
  || fail "real migration 045_tenant_safety.sql failed to apply"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_budgets")" == "0" ]] || fail "tenant_budgets should start EMPTY"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_usage")"   == "0" ]] || fail "tenant_usage should start EMPTY"
ok "migrations 040 + 045 applied — tenant_usage + tenant_budgets exist and are empty"

# ── 2) seed: budgets (both \$1.00) + usage (OVER>budget, UNDER<80%) ────────────
step "2/8 seed budgets(both ${BUDGET_CENTS}c) + usage (OVER=${OVER_QTY}→200c>budget, UNDER=${UNDER_QTY}→50c<80c)"
WINDOW_NOW="$(date -u +%Y-%m-01)"
seed() {
  psql_q >/dev/null 2>&1 <<SQL
INSERT INTO public.tenant_budgets(tenant_id, budget_cents, period) VALUES
  ('${TENANT_OVER}',  ${BUDGET_CENTS}, 'month'),
  ('${TENANT_UNDER}', ${BUDGET_CENTS}, 'month')
  ON CONFLICT (tenant_id) DO UPDATE SET budget_cents = EXCLUDED.budget_cents;
INSERT INTO public.tenant_usage(tenant_id, metric, window_start, qty, idempotency_key) VALUES
  ('${TENANT_OVER}', '${METRIC}', '${WINDOW_NOW}T00:00:00Z', ${OVER_QTY},  'm89-over-$$'),
  ('${TENANT_UNDER}','${METRIC}', '${WINDOW_NOW}T00:00:00Z', ${UNDER_QTY}, 'm89-under-$$')
  ON CONFLICT (idempotency_key) DO NOTHING;
SQL
}
for i in $(seq 1 20); do seed && break; [[ $i -eq 20 ]] && fail "seed never committed"; sleep 0.5; done
[[ "$(psql_val "SELECT qty FROM public.tenant_usage WHERE tenant_id='${TENANT_OVER}'")"  == "${OVER_QTY}"  ]] || fail "OVER usage not seeded"
[[ "$(psql_val "SELECT qty FROM public.tenant_usage WHERE tenant_id='${TENANT_UNDER}'")" == "${UNDER_QTY}" ]] || fail "UNDER usage not seeded"
ok "seeded: OVER 200c (> 100c budget), UNDER 50c (< 80c alert threshold)"

# ── 3) (A) boot the spend-cap guard (SPEND_CAPS_ENABLED=1) ─────────────────────
step "3/8 (A) boot orchestrator (ORCHESTRATOR_SERVICES=spend-cap, SPEND_CAPS_ENABLED=1, rate=${SPEND_RATE}/query)"
docker run -d --name "${ORCH_ON}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e REDIS_URL="${REDIS_INNET}" \
  -e ORCHESTRATOR_SERVICES=spend-cap \
  -e ORCHESTRATOR_PORT=3060 \
  -e INTERNAL_SERVICE_TOKEN="m89-strong-internal-svc-token-not-for-prod-0123456789ab" \
  -e METERING_ENABLED=1 \
  -e SPEND_CAPS_ENABLED=1 \
  -e SPEND_CAPS_INTERVAL_MS="${GUARD_MS}" \
  -e SPEND_CAPS_ALERT_PCT=80 \
  -e SPEND_RATE_QUERY_COUNT="${SPEND_RATE}" \
  -e LOG_LEVEL=debug \
  "${ORCH_IMG}" >/dev/null
wait_log "${ORCH_ON}" "spend caps enabled" 60 \
  || { red "guard logs:"; docker logs "${ORCH_ON}" 2>&1 | tail -20; fail "spend-cap guard never enabled"; }
ok "spend-cap guard enabled — evaluating tenant_usage × rate vs budget"

# ── 4) (A) LOAD-BEARING: OVER tenant lands in spend:over, UNDER absent ─────────
step "4/8 (A) wait for spend:over to contain EXACTLY the OVER tenant (the hard-cap halt decision)"
PUBLISHED=
for i in $(seq 1 60); do
  if [[ "$(redis_cli SISMEMBER spend:over "${TENANT_OVER}" 2>/dev/null)" == "1" ]]; then PUBLISHED=1; break; fi
  sleep 0.5
done
[[ -n "${PUBLISHED}" ]] || { red "spend:over members:"; redis_cli SMEMBERS spend:over 2>&1; fail "OVER tenant never appeared in spend:over (the hard-cap decision)"; }
[[ "$(redis_cli SISMEMBER spend:over "${TENANT_UNDER}" 2>/dev/null)" == "0" ]] \
  || fail "UNDER tenant wrongly listed in spend:over — the guard over-halted"
ok "(A) spend:over = {OVER}; UNDER absent — billable service HALTS for the over-budget tenant before runaway"

# ── 5) (A) the 80% ALERT fired EXACTLY ONCE ────────────────────────────────────
step "5/8 (A) assert the 80% budget ALERT fired ONCE (alert_fired_period stamped + 1 log line)"
for i in $(seq 1 40); do
  [[ "$(psql_val "SELECT (alert_fired_period IS NOT NULL) FROM public.tenant_budgets WHERE tenant_id='${TENANT_OVER}'")" == "t" ]] && break
  sleep 0.5
done
[[ "$(psql_val "SELECT (alert_fired_period IS NOT NULL) FROM public.tenant_budgets WHERE tenant_id='${TENANT_OVER}'")" == "t" ]] \
  || fail "OVER tenant alert_fired_period never stamped — the 80% alert did not fire"
# UNDER (50c < 80c threshold) must NOT have alerted — the load-bearing reject for the alert.
[[ "$(psql_val "SELECT (alert_fired_period IS NULL) FROM public.tenant_budgets WHERE tenant_id='${TENANT_UNDER}'")" == "t" ]] \
  || fail "UNDER tenant wrongly alerted (its 50c is below the 80c threshold) — false-positive alert"
# Give the guard a few more ticks; the alert must NOT re-fire (count log lines == 1).
sleep "$(awk "BEGIN{print (${GUARD_MS}*3/1000)+1}")"
ALERT_LINES="$(docker logs "${ORCH_ON}" 2>&1 | grep -c "spend-cap budget alert" || true)"
[[ "${ALERT_LINES}" == "1" ]] \
  || { red "alert log lines: ${ALERT_LINES}"; docker logs "${ORCH_ON}" 2>&1 | grep 'budget alert'; fail "80% alert must fire EXACTLY once per period, saw ${ALERT_LINES}"; }
ok "(A) 80% alert fired exactly once for OVER; UNDER never alerted (50c<80c) — once-per-period honored"

# ── 6) (B) PARITY arm: SPEND_CAPS_ENABLED unset → spend:over NEVER written ─────
step "6/8 (B) wipe spend:over, boot orchestrator with SPEND_CAPS unset (PARITY) — same seeds"
# Stop the ENABLED guard FIRST — it evaluates every interval and would re-populate
# spend:over right after the wipe, masking the OFF arm's true (no-op) behaviour.
docker rm -f "${ORCH_ON}" >/dev/null 2>&1 || true
redis_cli DEL spend:over >/dev/null 2>&1 || true
# Reset the OVER alert mark so a re-fire (if the OFF guard wrongly evaluated) would show.
psql_q >/dev/null 2>&1 <<SQL || true
UPDATE public.tenant_budgets SET alert_fired_period = NULL WHERE tenant_id='${TENANT_OVER}';
SQL
docker run -d --name "${ORCH_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e REDIS_URL="${REDIS_INNET}" \
  -e ORCHESTRATOR_SERVICES=spend-cap \
  -e ORCHESTRATOR_PORT=3060 \
  -e INTERNAL_SERVICE_TOKEN="m89-strong-internal-svc-token-not-for-prod-0123456789ab" \
  -e LOG_LEVEL=debug \
  "${ORCH_IMG}" >/dev/null
wait_log "${ORCH_OFF}" "spend caps disabled" 60 \
  || { red "off-guard logs:"; docker logs "${ORCH_OFF}" 2>&1 | tail -20; fail "OFF guard did not report disabled (flag default not OFF?)"; }
# Give it several intervals' worth of wall-time to PROVE it never evaluates.
sleep "$(awk "BEGIN{print (${GUARD_MS}*4/1000)+2}")"
[[ "$(redis_cli EXISTS spend:over 2>/dev/null)" == "0" ]] \
  || { red "spend:over members:"; redis_cli SMEMBERS spend:over 2>&1; fail "(B) spend:over was written with the flag OFF — NOT byte-parity"; }
[[ "$(psql_val "SELECT (alert_fired_period IS NULL) FROM public.tenant_budgets WHERE tenant_id='${TENANT_OVER}'")" == "t" ]] \
  || fail "(B) an alert fired with the flag OFF — NOT byte-parity"
ALERT_OFF="$(docker logs "${ORCH_OFF}" 2>&1 | grep -c "spend-cap budget alert" || true)"
[[ "${ALERT_OFF}" == "0" ]] || fail "(B) the OFF guard emitted ${ALERT_OFF} alert log line(s) — NOT byte-parity"
ok "(B) flag OFF: spend:over never written, no alert fired — byte-identical to today"

# ── 7) cross-check + summarize ─────────────────────────────────────────────────
step "7/8 cross-check: ON halts OVER + alerts once / OFF writes nothing"
green "[M89] (A) ENABLED: spend:over={OVER} · OVER alerted once · UNDER not halted/alerted (REAL spend decision)"
green "[M89] (B) PARITY:  spend:over absent · no alert (flag OFF → guard never evaluates → byte-parity)"
green "[M89] (C) B7.2:    QUOTA_STAGE off→shadow→warn→enforce ⇒ allow→shadowlog→header→block (unit-proven)"

# ── 8) emit the gate event via the kernel log helper (best-effort) ─────────────
step "8/8 log GATE m89=PASS"
emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-b7-spend-caps}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m89=PASS" --outcome pass \
      --msg "B7.8 spend caps: guard sums tenant_usage×rate vs tenant_budgets, publishes spend:over (hard cap) + fires 80% alert once; flag OFF -> nothing written (byte-parity); B7.2 QUOTA_STAGE ladder unit-proven" \
      --ref "scripts/verify/m89-spend-caps.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M89] ALL GATES GREEN — spend-cap CONSUMES B1 usage × rate vs budget, HALTS over-budget tenants + alerts at 80% once, and is byte-parity when OFF"
exit 0
