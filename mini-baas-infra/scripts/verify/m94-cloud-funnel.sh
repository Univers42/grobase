#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m94-cloud-funnel.sh                                :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M94 — Grobase CLOUD EDITION end-to-end FUNNEL gate (acceptance bar 4: "100%
# cloud infrastructure, usable, runnable on local docker"). m74–m90 prove each
# managed-cloud COMPONENT unit-by-unit; m94 proves they COMPOSE into a working
# product when ALL the cloud flags are ON together, on ONE isolated local stack.
# It mirrors the isolation discipline of m80/m82/m83/m84/m89/m90 EXACTLY.
#
# A stranger's whole journey, all flags ON (config/cloud/flags.env.cloud):
#
#   POSITIVE funnel (all off the wire, never from logs):
#     1. PROVISION a tenant (POST /v1/tenants, X-Service-Token).
#     2. ISSUE an API key (POST /v1/tenants/{id}/keys) → an mbk_ key.
#     3. CRUD N reads via the router /v1/query (trusted envelope, like m80) → 200.
#     4. B1: public.tenant_usage SUM(query.count) == N (producer flushed → ingest
#        drained); seeded EMPTY first so the count is the funnel's own work.
#     5. B4a: GET /v1/tenants/me/usage (the key) returns the SAME query.count total.
#     6. B3: stripe-mock /_events shows ≥1 meter event (right event_name/customer/
#        value); a re-tick adds NOTHING (idempotent — the billing_reported ledger).
#     7. B4b: Kong route ~/v1/tenants/me → 200 (the public buyer-facing surface is
#        wired, not just the internal port).
#
#   LOAD-BEARING REJECTS (each at its HONEST layer — the gate PRINTS which layer;
#   a gate whose only outcome is the happy path is VACUOUS, kernel #4):
#     R1 · quota 402 (B2, END-TO-END on the DATA PATH): an over-cap tenant's
#          /v1/query returns a REAL 402 off the wire after the data-plane refresh.
#     R2 · spend cap (B7.8, CONTROL-PLANE boundary): an over-budget tenant ∈ Redis
#          `spend:over`, an under-budget tenant ABSENT. The gate PRINTS that the
#          data-plane spend reject (DATA_PLANE_SPEND_CAPS) is a SEPARATE slice — so
#          the claim stays honest (the data plane consumes only quota:over today).
#     R3 · abuse (B7.9): the 4th POST /v1/abuse/admit {project_create} with
#          ABUSE_VELOCITY_MAX=3 → 403 velocity_exceeded AND the tenant flips to
#          Redis `tenant:suspended`.
#
#   FLAG-OFF PARITY (a SECOND scratch stack, cloud env file OMITTED): the SAME
#   calls → CRUD still 200, tenant_usage ZERO rows, over-cap /v1/query still 200, a
#   FRESH stripe-mock /_events count==0, /v1/abuse/admit 404, spend:over never
#   written. This is the proof the cloud edition is OPT-IN and the default stack is
#   byte-untouched (kernel #5).
#
# ALL ground truth is seeded INDEPENDENTLY (direct INSERTs for the over-cap/over-
# budget/safety rows) — the system under test is NEVER its own oracle. Every wait
# is POLL-WITH-TIMEOUT, never a bare sleep on a behaviour assertion.
#
# ISOLATED by design: a PRIVATE network per stack (m94-net-<RUNID>), scratch
# postgres (prelude + REAL 005 + 032 + 040 + 041 + 045) + scratch redis +
# data-plane-router + orchestrator + tenant-control built FROM CURRENT source + the
# m82 stripe-mock + a Kong 3.8 DBLESS container, ALL suffixed with $$, an EXIT trap
# removing EVERYTHING. It NEVER touches a mini-baas-* container/network/image/volume
# and NEVER edits the live docker-compose.yml.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                  # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                       # apps/baas
DPR_DIR="${INFRA_DIR}/docker/services/data-plane-router"
GO_DIR="${INFRA_DIR}/go/control-plane"
MIG_DIR="${INFRA_DIR}/scripts/migrations/postgresql"
MIGRATION_005="${MIG_DIR}/005_add_tenant_table.sql"
MIGRATION_032="${MIG_DIR}/032_tenants.sql"
MIGRATION_035="${MIG_DIR}/035_widen_tenant_plan_check.sql"
MIGRATION_040="${MIG_DIR}/040_tenant_usage.sql"
MIGRATION_041="${MIG_DIR}/041_tenant_billing.sql"
MIGRATION_045="${MIG_DIR}/045_tenant_safety.sql"
MOCK_DIR="${SCRIPT_DIR}/m82-mock-stripe"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
dim()   { printf '\033[0;90m%s\033[0m\n' "$*"; }
step()  { cyan "[M94] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M94] FAIL — $*"; exit 1; }

RUNID=$$
PG_IMAGE="${M94_PG_IMAGE:-postgres:16-alpine}"
REDIS_IMAGE="${M94_REDIS_IMAGE:-redis:7-alpine}"
NODE_IMAGE="${M94_NODE_IMAGE:-node:20-alpine}"
KONG_IMAGE="${M94_KONG_IMAGE:-kong:3.8}"
DPR_IMG="m94-dpr-${RUNID}:scratch"
ORCH_IMG="m94-orch-${RUNID}:scratch"
TC_IMG="m94-tc-${RUNID}:scratch"

# ── ENABLED stack (all cloud flags ON) ─────────────────────────────────────── #
NET="m94-net-${RUNID}"
PG="m94-pg-${RUNID}"
REDIS="m94-redis-${RUNID}"
DPR="m94-dpr-on-${RUNID}"
ORCH="m94-orch-on-${RUNID}"
TC="m94-tc-on-${RUNID}"           # network-alias tenant-control (so kong upstream resolves)
MOCK="m94-mock-${RUNID}"
KONG="m94-kong-${RUNID}"
# ── PARITY stack (cloud env OMITTED) ───────────────────────────────────────── #
PNET="m94-pnet-${RUNID}"
PPG="m94-ppg-${RUNID}"
PREDIS="m94-predis-${RUNID}"
PDPR="m94-pdpr-${RUNID}"
PORCH="m94-porch-${RUNID}"
PTC="m94-ptc-${RUNID}"
PMOCK="m94-pmock-${RUNID}"

# Host-published ports (high range to avoid collisions).
PORT_DPR="${M94_PORT_DPR:-18940}"
PORT_TC="${M94_PORT_TC:-18941}"
PORT_MOCK="${M94_PORT_MOCK:-18942}"
PORT_KONG="${M94_PORT_KONG:-18943}"
PORT_PDPR="${M94_PORT_PDPR:-18945}"
PORT_PTC="${M94_PORT_PTC:-18946}"
PORT_PMOCK="${M94_PORT_PMOCK:-18947}"

PGPW="postgres"
TC_PORT=3022                      # matches the canonical kong.yml upstream url
# STRONG, non-placeholder INTERNAL_SERVICE_TOKEN — the orchestrator AND tenant-
# control REFUSE to boot on empty or "dev-service-token-change-me" (shared/config.go).
SVC_TOKEN="m94-strong-internal-svc-token-not-for-prod-${RUNID}-0123456789ab"

# Funnel constants.
N_QUERIES="${M94_N_QUERIES:-7}"   # CRUD reads → query.count must total exactly this
PROBE_TABLE="m94_probe"
NANO_CAP=100000                   # nano query.count cap (packages.json source of truth)
OVER_QTY=$((NANO_CAP + 1))        # R1 over-cap seed
EVENT_NAME="grobase_query_count"  # must equal flags.env.cloud BILLING_METER_QUERY_COUNT
VELOCITY_MAX=3                    # R3: the 4th project_create breaches

# Tenants (the id IS the slug — what the key resolves to AND what /v1/query stamps).
T_FUNNEL="m94-funnel-${RUNID}"    # the journey tenant (provision→key→CRUD→usage→bill)
T_OVERQ="m94-overq-${RUNID}"      # R1 over-quota tenant
T_OVERB="m94-overb-${RUNID}"      # R2 over-budget tenant
T_UNDERB="m94-underb-${RUNID}"    # R2 under-budget tenant (must be ABSENT from spend:over)
T_ABUSE="m94-abuse-${RUNID}"      # R3 abuse tenant (verified, gets suspended)
PRINCIPAL="api-key:m94-principal-${RUNID}"
CUS="cus_m94_${RUNID}"            # the funnel tenant's Stripe customer

BODY_TMP="$(mktemp)"
EVENTS_TMP="$(mktemp)"
KONG_YML="$(mktemp /tmp/m94-kong-${RUNID}.XXXXXX.yml)"

cleanup() {
  docker rm -fv "${KONG}" "${DPR}" "${ORCH}" "${TC}" "${MOCK}" "${PG}" "${REDIS}" >/dev/null 2>&1 || true
  docker rm -fv "${PDPR}" "${PORCH}" "${PTC}" "${PMOCK}" "${PPG}" "${PREDIS}" >/dev/null 2>&1 || true
  docker network rm "${NET}" "${PNET}" >/dev/null 2>&1 || true
  docker image rm -f "${DPR_IMG}" "${ORCH_IMG}" "${TC_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" "${EVENTS_TMP}" "${KONG_YML}" 2>/dev/null || true
}
trap cleanup EXIT

# ── helpers (scoped to a postgres/redis container passed as $1) ─────────────── #
pg_q()    { docker exec -i "$1" psql -U postgres -d postgres -v ON_ERROR_STOP=1; }     # stdin SQL
pg_val()  { docker exec -i "$1" psql -U postgres -d postgres -tAc "$2" 2>/dev/null | tr -d '[:space:]'; }  # $1=pg $2=sql
rcli()    { docker exec -i "$1" redis-cli "${@:2}"; }                                  # $1=redis, rest=args

# Apply a migration the way `make migrate` does: strip the leading 42-header (#) lines.
apply_migration() { # $1=pg-container $2=file
  sed '/^#/d' "$2" | docker exec -i "$1" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1
}

# Admin (service-token) request against tenant-control → status, body→BODY_TMP.
admin_req() { # $1=method $2=port $3=path $4(opt)=json
  local m="$1" p="$2" path="$3" body="${4:-}"
  if [[ -n "${body}" ]]; then
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "X-Service-Token: ${SVC_TOKEN}" -H 'Content-Type: application/json' -d "${body}"
  else
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "X-Service-Token: ${SVC_TOKEN}"
  fi
}

# Self-service (tenant API-key) request → status, body→BODY_TMP.
me_req() { # $1=method $2=port $3=path $4=api-key
  curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "$1" "http://127.0.0.1:$2$3" -H "X-API-Key: $4"
}

# POST /v1/abuse/admit (service token) → status, body→BODY_TMP.
admit() { # $1=port $2=tenant $3=action
  curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST "http://127.0.0.1:$1/v1/abuse/admit" \
    -H 'Content-Type: application/json' -H "X-Service-Token: ${SVC_TOKEN}" \
    -d "{\"principal\":\"${PRINCIPAL}\",\"tenant_id\":\"$2\",\"tier\":\"nano\",\"action\":\"$3\"}"
}

# /v1/query trusted-envelope list as a tenant (m80 pattern). $1=dsn-innet $2=tenant.
payload_list() { # $1=db-innet $2=tenant
  printf '{"identity":{"tenant_id":"%s","user_id":"%s","roles":["service_role"],"scopes":["admin"],"source":"test"},"mount":{"id":"m94","tenant_id":"%s","engine":"postgresql","name":"probe","credential_ref":{"provider":"inline","reference":"-","version":"1"},"capability_overrides":null,"inline_dsn":"%s","isolation":"shared_rls"},"operation":{"op":"list","resource":"%s","data":null}}' \
    "$2" "$2" "$2" "$1" "${PROBE_TABLE}"
}
post_q() { # $1=port $2=body
  curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST "http://127.0.0.1:$1/v1/query" \
    -H 'Content-Type: application/json' -d "$2"
}

json_str() { { grep -o "\"$1\":\"[^\"]*\"" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*://; s/"//g'; }

wait_pg() { # $1=container
  for i in $(seq 1 80); do
    [[ "$(docker logs "$1" 2>&1 | grep -c 'database system is ready to accept connections' || true)" -ge 2 ]] && return 0
    sleep 0.5
  done
  return 1
}
wait_redis() { for i in $(seq 1 60); do rcli "$1" PING 2>/dev/null | grep -q PONG && return 0; sleep 0.5; done; return 1; }

wait_http() { # $1=container $2=url
  for i in $(seq 1 60); do
    curl -fsS -o /dev/null "$2" 2>/dev/null && return 0
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -20; return 1; }
    sleep 0.5
  done
  red "$1 never became ready ($2):"; docker logs "$1" 2>&1 | tail -20; return 1
}
wait_tc()  { wait_http "$1" "http://127.0.0.1:$2/health/live"; }
wait_dpr() { wait_http "$1" "http://127.0.0.1:$2/v1/capabilities"; }
wait_mock(){ wait_http "$1" "http://127.0.0.1:$2/_health"; }

wait_log() { # $1=container $2=needle $3=tries
  for i in $(seq 1 "${3:-60}"); do
    docker logs "$1" 2>&1 | grep -q "$2" && return 0
    docker inspect "$1" >/dev/null 2>&1 || return 1
    sleep 0.5
  done
  return 1
}
wait_kong_route() { # $1=container $2=port
  local code
  for i in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2/v1/tenants/me" 2>/dev/null || true)"
    case "${code}" in 200|401|403|404) return 0 ;; esac
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -20; return 1; }
    sleep 0.5
  done
  red "$1 never routed (last='${code}'):"; docker logs "$1" 2>&1 | tail -20; return 1
}

# Count meter events on a stripe-mock by host port (tolerates zero — the PARITY result).
mock_events() { # $1=port
  curl -s -o "${EVENTS_TMP}" "http://127.0.0.1:$1/_events" 2>/dev/null || true
  { grep -o '"identifier":"[^"]*"' "${EVENTS_TMP}" 2>/dev/null || true; } | wc -l | tr -d '[:space:]'
}

# Apply prelude + the REAL 005/032/040/041/045 to a fresh postgres ($1).
seed_schema() { # $1=pg-container
  local PGC="$1"
  prelude() {
    pg_q "${PGC}" >/dev/null 2>&1 <<'SQL'
CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS text
  LANGUAGE sql STABLE AS $fn$ SELECT current_setting('request.tenant_id', true) $fn$;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
DO $r$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role')  THEN CREATE ROLE service_role;  END IF;
END $r$;
SQL
  }
  for i in $(seq 1 20); do prelude && break; [[ $i -eq 20 ]] && return 1; sleep 0.5; done
  apply_migration "${PGC}" "${MIGRATION_005}" || return 1
  apply_migration "${PGC}" "${MIGRATION_032}" || return 1
  apply_migration "${PGC}" "${MIGRATION_035}" || return 1
  apply_migration "${PGC}" "${MIGRATION_040}" || return 1
  apply_migration "${PGC}" "${MIGRATION_041}" || return 1
  apply_migration "${PGC}" "${MIGRATION_045}" || return 1
}

# Seed the bare probe table the /v1/query list reads (so a served read is 200).
seed_probe() { # $1=pg-container
  pg_q "$1" >/dev/null 2>&1 <<SQL
CREATE TABLE IF NOT EXISTS public.${PROBE_TABLE} (id text PRIMARY KEY, label text);
INSERT INTO public.${PROBE_TABLE}(id, label) VALUES ('p1','ok') ON CONFLICT (id) DO NOTHING;
SQL
}

# ── 0) build the three scratch images FROM CURRENT source ──────────────────────
step "0/14 build data-plane-router + orchestrator + tenant-control FROM CURRENT source (the cloud code)"
DOCKER_BUILDKIT=1 docker build -q -f "${DPR_DIR}/Dockerfile" -t "${DPR_IMG}" "${DPR_DIR}" >/dev/null \
  || fail "data-plane-router image build failed (the metering producer + quota-402 code)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=orchestrator --build-arg PORT=3060 \
  -t "${ORCH_IMG}" "${GO_DIR}" >/dev/null \
  || fail "orchestrator image build failed (metering-ingest + quota-guard + billing + spend-cap)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT="${TC_PORT}" \
  -t "${TC_IMG}" "${GO_DIR}" >/dev/null \
  || fail "tenant-control image build failed (self-serve + abuse-guard)"
ok "all three built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ══════════════════════════════════════════════════════════════════════════════
#  STACK A — the ENABLED cloud stack (all flags ON)
# ══════════════════════════════════════════════════════════════════════════════
step "1/14 [ENABLED] boot isolated net (${NET}): redis + postgres"
docker network create "${NET}" >/dev/null
docker run -d --name "${REDIS}" --network "${NET}" "${REDIS_IMAGE}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
wait_redis "${REDIS}" || fail "scratch redis never PONGed"
wait_pg "${PG}" || fail "scratch postgres never reached steady state"
ok "redis + postgres up"

step "1b/14 [ENABLED] apply prelude + REAL 005 + 032 + 040 + 041 + 045 + the probe table"
seed_schema "${PG}" || fail "migrations failed to apply on the ENABLED stack"
seed_probe "${PG}"   || fail "probe table seed failed on the ENABLED stack"
# Independent ground truth must START empty for the funnel's B1 count to be meaningful.
[[ "$(pg_val "${PG}" "SELECT count(*) FROM public.tenant_usage")"   == "0" ]] || fail "tenant_usage must start EMPTY"
[[ "$(pg_val "${PG}" "SELECT count(*) FROM public.tenant_billing")" == "0" ]] || fail "tenant_billing must start EMPTY"
[[ "$(pg_val "${PG}" "SELECT count(*) FROM public.tenants")"        == "0" ]] || fail "tenants must start EMPTY"
ok "schema applied; tenant_usage / tenant_billing / tenants all start EMPTY (the oracle is independent)"

DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
REDIS_INNET="redis://${REDIS}:6379"

# Seed the INDEPENDENT ground truth the reject arms need (never via the SUT).
step "2/14 [ENABLED] seed INDEPENDENT ground truth: over-quota usage, budgets+usage, a verified abuse tenant, the funnel Stripe customer"
WINDOW_NOW="$(date -u +%Y-%m-01)"
pg_q "${PG}" >/dev/null 2>&1 <<SQL || fail "ground-truth seed failed"
-- R1: a real tenants row for T_OVERQ on the nano tier (slug = tenant_id, the public
--     identity the data plane stamps) + an OVER-quota usage row (qty > nano cap). The
--     QuotaGuard joins tenants.slug = tenant_usage.tenant_id (see quotaguard.go) to
--     resolve the nano cap and publish quota:over. WITHOUT the tenants row the slug
--     join falls back to the essential default cap (2,000,000) and never enforces —
--     the m94-R1 bug this seed fixes. Migration 035 widens the plan CHECK to accept 'nano'.
INSERT INTO public.tenants(id, name, slug, plan) VALUES
  (gen_random_uuid(), '${T_OVERQ}', '${T_OVERQ}', 'nano')
  ON CONFLICT (slug) DO UPDATE SET plan = EXCLUDED.plan;
INSERT INTO public.tenant_usage(tenant_id, metric, window_start, qty, idempotency_key) VALUES
  ('${T_OVERQ}', 'query.count', '${WINDOW_NOW}T00:00:00Z', ${OVER_QTY}, 'm94-overq-${RUNID}')
  ON CONFLICT (idempotency_key) DO NOTHING;
-- R2: budgets (both \$1.00) + usage so T_OVERB is over budget (200c>100c) and
--     T_UNDERB is well under (< 80c → not even alerted). Rate = 0.001c/query
--     (flags.env.cloud SPEND_RATE_QUERY_COUNT) → spend_cents = qty × 0.001.
INSERT INTO public.tenant_budgets(tenant_id, budget_cents, period) VALUES
  ('${T_OVERB}',  100, 'month'),
  ('${T_UNDERB}', 100, 'month')
  ON CONFLICT (tenant_id) DO UPDATE SET budget_cents = EXCLUDED.budget_cents;
INSERT INTO public.tenant_usage(tenant_id, metric, window_start, qty, idempotency_key) VALUES
  ('${T_OVERB}',  'query.count', '${WINDOW_NOW}T00:00:00Z', 200000, 'm94-overb-${RUNID}'),
  ('${T_UNDERB}', 'query.count', '${WINDOW_NOW}T00:00:00Z',  50000, 'm94-underb-${RUNID}')
  ON CONFLICT (idempotency_key) DO NOTHING;
-- R3: a verified, not-suspended safety row for the abuse tenant so the KYC gate
--     admits and the velocity breach is the only failure mode under test.
INSERT INTO public.tenant_safety(tenant_id, email_verified, suspended) VALUES
  ('${T_ABUSE}', true, false)
  ON CONFLICT (tenant_id) DO UPDATE SET email_verified=true, suspended=false;
SQL
ok "seeded over-quota usage, over/under budgets+usage, a verified abuse tenant"

# ── 3) boot the data-plane-router (cloud flags ON: metering producer + quota 402) ─
step "3/14 [ENABLED] boot data-plane-router (DATA_PLANE_METERING=1 + DATA_PLANE_QUOTA_ENFORCEMENT=1, fast flush/refresh)"
docker run -d --name "${DPR}" --network "${NET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
  -e METERING_ENABLED=1 \
  -e DATA_PLANE_METERING=1 \
  -e DATA_PLANE_METERING_FLUSH_MS=1500 \
  -e DATA_PLANE_QUOTA_ENFORCEMENT=1 \
  -e DATA_PLANE_QUOTA_REFRESH_MS=1500 \
  -e DATA_PLANE_TENANT_OBS=1 \
  -e REDIS_URL="${REDIS_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e RUST_LOG=info \
  -p "127.0.0.1:${PORT_DPR}:4011" "${DPR_IMG}" >/dev/null
wait_dpr "${DPR}" "${PORT_DPR}" || fail "ENABLED data-plane-router not ready"
ok "data-plane-router up (metering producer + quota enforcement ON) on :${PORT_DPR}"

# ── 4) boot the orchestrator (cloud flags ON: ingest + quota-guard + billing + spend-cap) ─
step "4/14 [ENABLED] boot orchestrator (metering-ingest + quota-guard + billing → stripe-mock + spend-cap)"
docker run -d --name "${MOCK}" --network "${NET}" -e PORT=8080 -v "${MOCK_DIR}":/app:ro \
  -p "127.0.0.1:${PORT_MOCK}:8080" "${NODE_IMAGE}" node /app/server.mjs >/dev/null
wait_mock "${MOCK}" "${PORT_MOCK}" || fail "stripe-mock not ready"
docker run -d --name "${ORCH}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e REDIS_URL="${REDIS_INNET}" \
  -e ORCHESTRATOR_SERVICES="metering,quota-guard,billing,spend-cap" \
  -e ORCHESTRATOR_PORT=3060 \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e METERING_ENABLED=1 \
  -e METERING_INGEST=1 \
  -e QUOTA_ENFORCEMENT=1 \
  -e QUOTA_ENFORCEMENT_INTERVAL_MS=1500 \
  -e BILLING_ENABLED=1 \
  -e BILLING_REPORT_INTERVAL_MS=1500 \
  -e STRIPE_API_BASE="http://${MOCK}:8080" \
  -e STRIPE_API_KEY=sk_test_local_mock \
  -e BILLING_METER_QUERY_COUNT="${EVENT_NAME}" \
  -e SPEND_CAPS_ENABLED=1 \
  -e SPEND_CAPS_INTERVAL_MS=1500 \
  -e SPEND_CAPS_ALERT_PCT=80 \
  -e SPEND_RATE_QUERY_COUNT=0.001 \
  -e LOG_LEVEL=debug \
  "${ORCH_IMG}" >/dev/null
wait_log "${ORCH}" "metering ingest connected" 80 \
  || { red "orch logs:"; docker logs "${ORCH}" 2>&1 | tail -25; fail "metering ingest never connected (B1 drain)"; }
wait_log "${ORCH}" "billing enabled"   60 || { docker logs "${ORCH}" 2>&1 | tail -25; fail "BillingReporter never enabled"; }
wait_log "${ORCH}" "spend caps enabled" 60 || { docker logs "${ORCH}" 2>&1 | tail -25; fail "spend-cap guard never enabled"; }
wait_log "${ORCH}" "quota enforcement enabled" 60 || { docker logs "${ORCH}" 2>&1 | tail -25; fail "QuotaGuard never enabled"; }
ok "orchestrator up — all four cloud sub-services enabled (ingest, quota-guard, billing, spend-cap)"

# ── 5) boot tenant-control (cloud flags ON: self-serve + abuse-guard) + Kong ──
step "5/14 [ENABLED] boot tenant-control (TENANT_SELFSERVE_ENABLED=1 + ABUSE_GUARD_ENABLED=1) under alias tenant-control"
docker run -d --name "${TC}" --network "${NET}" --network-alias tenant-control \
  -e DATABASE_URL="${DB_INNET}" \
  -e REDIS_URL="${REDIS_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TENANT_CONTROL_PORT="${TC_PORT}" \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e TENANT_SELFSERVE_ENABLED=1 \
  -e BILLING_ENABLED=1 \
  -e ABUSE_GUARD_ENABLED=1 \
  -e ABUSE_VELOCITY_MAX="${VELOCITY_MAX}" \
  -e ABUSE_VELOCITY_WINDOW_MS=3600000 \
  -e ABUSE_AUTO_SUSPEND=1 \
  -e ABUSE_REQUIRE_NANO=email \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_TC}:${TC_PORT}" "${TC_IMG}" >/dev/null
wait_tc "${TC}" "${PORT_TC}" || fail "ENABLED tenant-control not ready"
docker logs "${TC}" 2>&1 | grep -q "abuse guard enabled" \
  || { docker logs "${TC}" 2>&1 | tail -20; fail "abuse guard never reported enabled"; }
ok "tenant-control up (self-serve + abuse guard mounted)"

step "5b/14 [ENABLED] write minimal kong.yml (the tenant-selfserve route) + boot Kong DBLESS → tenant-control:${TC_PORT}"
cat > "${KONG_YML}" <<'YAML'
_format_version: "3.0"
services:
  - name: tenant-selfserve
    url: http://tenant-control:3022
    routes:
      - name: tenant-selfserve
        paths:
          - ~/v1/tenants/me$
          - ~/v1/tenants/me/.*
        strip_path: false
YAML
docker run -d --name "${KONG}" --network "${NET}" \
  -e KONG_DATABASE=off -e KONG_DECLARATIVE_CONFIG=/kong.yml \
  -e KONG_PROXY_ACCESS_LOG=/dev/stdout -e KONG_PROXY_ERROR_LOG=/dev/stderr \
  -e KONG_ADMIN_LISTEN=off -e KONG_NGINX_WORKER_PROCESSES=1 -e KONG_MEM_CACHE_SIZE=32m \
  -v "${KONG_YML}:/kong.yml:ro" -p "127.0.0.1:${PORT_KONG}:8000" "${KONG_IMAGE}" >/dev/null
wait_kong_route "${KONG}" "${PORT_KONG}" || fail "Kong never routed to tenant-control"
ok "Kong up + routing the public /v1/tenants/me* surface → tenant-control:${TC_PORT}"

# ══════════════════════════════════════════════════════════════════════════════
#  POSITIVE FUNNEL
# ══════════════════════════════════════════════════════════════════════════════
step "6/14 [POSITIVE 1-2] PROVISION tenant ${T_FUNNEL} + ISSUE an API key (X-Service-Token)"
C="$(admin_req POST "${PORT_TC}" /v1/tenants "{\"id\":\"${T_FUNNEL}\",\"name\":\"funnel\",\"plan\":\"nano\"}")"
[[ "${C}" == "201" ]] || fail "provision expected 201, got ${C} — $(head -c 300 "${BODY_TMP}")"
C="$(admin_req POST "${PORT_TC}" "/v1/tenants/${T_FUNNEL}/keys" "{\"name\":\"m94-key-${RUNID}\",\"scopes\":[\"read\",\"write\",\"admin\"]}")"
[[ "${C}" == "201" ]] || fail "issue key expected 201, got ${C} — $(head -c 300 "${BODY_TMP}")"
KEY="$(json_str key)"
[[ "${KEY}" == mbk_* ]] || fail "key not returned as a full mbk_ key — got '${KEY}'"
ok "provisioned ${T_FUNNEL} (nano) + issued an mbk_ API key"

# A Stripe customer row so the BillingReporter has a tenant→customer map for B3.
pg_q "${PG}" >/dev/null 2>&1 <<SQL || fail "tenant_billing seed failed"
INSERT INTO public.tenant_billing(tenant_id, stripe_customer_id, plan) VALUES ('${T_FUNNEL}','${CUS}','nano')
  ON CONFLICT (tenant_id) DO UPDATE SET stripe_customer_id=EXCLUDED.stripe_customer_id;
SQL

step "7/14 [POSITIVE 3] CRUD ${N_QUERIES} reads via the router /v1/query (trusted envelope) → all 200"
for n in $(seq 1 "${N_QUERIES}"); do
  C="$(post_q "${PORT_DPR}" "$(payload_list "${DB_INNET}" "${T_FUNNEL}")")"
  [[ "${C}" == "200" ]] || fail "CRUD read #${n} expected 200, got ${C} — $(head -c 300 "${BODY_TMP}")"
done
ok "${N_QUERIES} reads served 200 — each records query.count+=1 keyed on identity.tenant_id"

step "8/14 [POSITIVE 4 · B1 LOAD-BEARING] poll public.tenant_usage until SUM(query.count) == ${N_QUERIES}"
GOT=
for i in $(seq 1 60); do
  GOT="$(pg_val "${PG}" "SELECT COALESCE(SUM(qty),0) FROM public.tenant_usage WHERE tenant_id='${T_FUNNEL}' AND metric='query.count'")"
  [[ "${GOT}" == "${N_QUERIES}" ]] && break
  sleep 0.5
done
[[ "${GOT}" == "${N_QUERIES}" ]] \
  || fail "B1: tenant_usage SUM(query.count) for ${T_FUNNEL} = '${GOT}', expected ${N_QUERIES} (producer flush → ingest drain)"
ok "B1: data plane flushed → ingest drained → tenant_usage SUM(query.count) == ${N_QUERIES} (exact, the funnel's own work)"

step "9/14 [POSITIVE 5 · B4a] GET /v1/tenants/me/usage (the key) returns the SAME query.count total"
C="$(me_req GET "${PORT_TC}" /v1/tenants/me/usage "${KEY}")"
[[ "${C}" == "200" ]] || fail "B4a: GET /me/usage expected 200, got ${C} — $(head -c 300 "${BODY_TMP}")"
# The /me/usage body is shape-identical to {id}/usage: a per-metric "qty" sum. Assert
# the query.count metric's qty equals N (it is the only metered metric beyond rows).
grep -q "\"metric\":\"query.count\"" "${BODY_TMP}" \
  || fail "B4a: /me/usage body has no query.count metric — $(head -c 400 "${BODY_TMP}")"
grep -Eq "\"qty\":${N_QUERIES}\b" "${BODY_TMP}" \
  || fail "B4a: /me/usage query.count qty != ${N_QUERIES} — $(head -c 400 "${BODY_TMP}")"
ok "B4a: GET /v1/tenants/me/usage → 200; query.count qty == ${N_QUERIES} (self-serve read matches the DB)"

step "10/14 [POSITIVE 6 · B3] poll stripe-mock /_events for ≥1 meter event (right event_name/customer); re-tick adds nothing (idempotent)"
EV=0
for i in $(seq 1 60); do
  EV="$(mock_events "${PORT_MOCK}")"
  [[ "${EV}" -ge 1 ]] && break
  sleep 0.5
done
[[ "${EV}" -ge 1 ]] || { red "events:"; cat "${EVENTS_TMP}"; fail "B3: stripe-mock received 0 meter events (BillingReporter never reported the funnel window)"; }
mock_events "${PORT_MOCK}" >/dev/null   # refresh EVENTS_TMP
grep -q "\"event_name\":\"${EVENT_NAME}\"" "${EVENTS_TMP}" || fail "B3: no event with event_name ${EVENT_NAME} — $(head -c 400 "${EVENTS_TMP}")"
grep -q "\"customer\":\"${CUS}\""          "${EVENTS_TMP}" || fail "B3: no event for customer ${CUS} — $(head -c 400 "${EVENTS_TMP}")"
# A value > 0 (the window qty). The window may be one or more (each ≥1); the SUM seen
# across events for this customer must be > 0 — assert at least one non-zero value.
grep -Eq "\"value\":\"[1-9][0-9]*\"" "${EVENTS_TMP}" || fail "B3: every meter event had value 0 — $(head -c 400 "${EVENTS_TMP}")"
BEFORE="$(mock_events "${PORT_MOCK}")"
sleep "$(awk 'BEGIN{print (1500*3/1000)+1}')"   # ≥3 report intervals
AFTER="$(mock_events "${PORT_MOCK}")"
[[ "${AFTER}" == "${BEFORE}" ]] \
  || fail "B3: idempotency broken — events grew ${BEFORE}→${AFTER} after re-ticks (the billing_reported ledger must suppress re-sends)"
ok "B3: ≥1 meter event (event_name=${EVENT_NAME}, customer=${CUS}, value>0); re-tick added nothing (${BEFORE}→${AFTER}) = idempotent"

step "11/14 [POSITIVE 7 · B4b] Kong route ~/v1/tenants/me (the key) → 200 (public buyer-facing surface wired)"
C="$(curl -s -o "${BODY_TMP}" -w '%{http_code}' "http://127.0.0.1:${PORT_KONG}/v1/tenants/me" -H "Authorization: Bearer ${KEY}")"
[[ "${C}" == "200" ]] || fail "B4b: Kong GET /v1/tenants/me expected 200, got ${C} — $(head -c 300 "${BODY_TMP}")"
grep -q "\"id\":\"${T_FUNNEL}\"" "${BODY_TMP}" || fail "B4b: Kong /me did not resolve to ${T_FUNNEL} — $(head -c 300 "${BODY_TMP}")"
ok "B4b: Kong forwarded the Bearer key → tenant-control resolved ${T_FUNNEL} (200) — the public console route is live"

# ══════════════════════════════════════════════════════════════════════════════
#  LOAD-BEARING REJECTS
# ══════════════════════════════════════════════════════════════════════════════
step "12/14 [REJECT R1 · DATA PATH] over-cap tenant's /v1/query → REAL 402 off the wire (B2, end-to-end)"
dim "      layer: DATA PLANE — the strongest reject (a real HTTP 402 on the request path)"
# Wait until the QuotaGuard has published the over-quota tenant to quota:over, then
# probe the data plane (which refreshes its snapshot every DATA_PLANE_QUOTA_REFRESH_MS).
for i in $(seq 1 60); do
  [[ "$(rcli "${REDIS}" SISMEMBER quota:over "${T_OVERQ}")" == "1" ]] && break
  sleep 0.5
done
[[ "$(rcli "${REDIS}" SISMEMBER quota:over "${T_OVERQ}")" == "1" ]] \
  || { red "quota:over:"; rcli "${REDIS}" SMEMBERS quota:over; fail "R1: QuotaGuard never published ${T_OVERQ} to quota:over"; }
CODE=
for i in $(seq 1 30); do
  CODE="$(post_q "${PORT_DPR}" "$(payload_list "${DB_INNET}" "${T_OVERQ}")")"
  [[ "${CODE}" == "402" ]] && break
  sleep 0.5
done
[[ "${CODE}" == "402" ]] || fail "R1: over-cap tenant expected 402 (data path), got ${CODE} — $(head -c 300 "${BODY_TMP}")"
grep -q 'quota_exceeded' "${BODY_TMP}" || fail "R1: 402 body missing quota_exceeded — $(head -c 300 "${BODY_TMP}")"
ok "R1: over-cap /v1/query → 402 quota_exceeded off the wire (B2 enforced end-to-end on the data path)"

step "13/14 [REJECT R2 · CONTROL PLANE] over-budget tenant ∈ Redis spend:over; under-budget tenant ABSENT (B7.8)"
dim "      layer: CONTROL PLANE — the data-plane spend reject (DATA_PLANE_SPEND_CAPS) is a SEPARATE slice; the data plane consumes only quota:over today, so this claim stays honest"
for i in $(seq 1 60); do
  [[ "$(rcli "${REDIS}" SISMEMBER spend:over "${T_OVERB}")" == "1" ]] && break
  sleep 0.5
done
[[ "$(rcli "${REDIS}" SISMEMBER spend:over "${T_OVERB}")" == "1" ]] \
  || { red "spend:over:"; rcli "${REDIS}" SMEMBERS spend:over; fail "R2: spend-cap never published ${T_OVERB} to spend:over (the hard-cap decision)"; }
[[ "$(rcli "${REDIS}" SISMEMBER spend:over "${T_UNDERB}")" == "0" ]] \
  || fail "R2: under-budget ${T_UNDERB} wrongly listed in spend:over — the guard over-halted"
ok "R2: spend:over = {over-budget}; under-budget ABSENT (control-plane halt decision; data-plane reject is a separate slice)"

step "14/14 [REJECT R3 · ABUSE] the 4th project_create (VELOCITY_MAX=${VELOCITY_MAX}) → 403 velocity_exceeded + tenant:suspended (B7.9)"
dim "      layer: CONTROL PLANE — /v1/abuse/admit decision + Redis tenant:suspended"
for n in $(seq 1 "${VELOCITY_MAX}"); do
  C="$(admit "${PORT_TC}" "${T_ABUSE}" project_create)"
  [[ "${C}" == "200" ]] || fail "R3: admit #${n} expected 200, got ${C} — $(head -c 300 "${BODY_TMP}")"
  grep -q '"admit":true' "${BODY_TMP}" || fail "R3: admit #${n} not admit:true — $(head -c 300 "${BODY_TMP}")"
done
C="$(admit "${PORT_TC}" "${T_ABUSE}" project_create)"   # the (MAX+1)th
[[ "${C}" == "403" ]] || fail "R3: the $((VELOCITY_MAX+1))th admit expected 403, got ${C} — $(head -c 300 "${BODY_TMP}")"
grep -q 'velocity_exceeded' "${BODY_TMP}" || fail "R3: 403 body missing velocity_exceeded — $(head -c 300 "${BODY_TMP}")"
for i in $(seq 1 20); do
  [[ "$(pg_val "${PG}" "SELECT suspended FROM public.tenant_safety WHERE tenant_id='${T_ABUSE}'")" == "t" ]] && break
  sleep 0.3
done
[[ "$(pg_val "${PG}" "SELECT suspended FROM public.tenant_safety WHERE tenant_id='${T_ABUSE}'")" == "t" ]] \
  || fail "R3: ${T_ABUSE} not suspended in tenant_safety after the velocity breach"
[[ "$(rcli "${REDIS}" SISMEMBER tenant:suspended "${T_ABUSE}")" == "1" ]] \
  || { red "tenant:suspended:"; rcli "${REDIS}" SMEMBERS tenant:suspended; fail "R3: ${T_ABUSE} absent from Redis tenant:suspended"; }
ok "R3: 4th project_create → 403 velocity_exceeded + tenant auto-suspended (DB + Redis tenant:suspended)"

green "[M94] ── ENABLED stack: POSITIVE funnel (1-7) + REJECTS (R1 data-402 · R2 spend:over · R3 abuse-suspend) ALL GREEN ──"

# ══════════════════════════════════════════════════════════════════════════════
#  STACK B — FLAG-OFF PARITY (the SAME calls, cloud env file OMITTED)
# ══════════════════════════════════════════════════════════════════════════════
step "P1/6 [PARITY] boot a SECOND isolated net (${PNET}) with the SAME images but NO cloud env"
docker network create "${PNET}" >/dev/null
docker run -d --name "${PREDIS}" --network "${PNET}" "${REDIS_IMAGE}" >/dev/null
docker run -d --name "${PPG}" --network "${PNET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
wait_redis "${PREDIS}" || fail "[PARITY] redis never PONGed"
wait_pg "${PPG}" || fail "[PARITY] postgres never reached steady state"
seed_schema "${PPG}" || fail "[PARITY] migrations failed"
seed_probe "${PPG}"  || fail "[PARITY] probe table seed failed"
# Seed the SAME over-cap usage so the parity arm proves the OFF path ignores it.
pg_q "${PPG}" >/dev/null 2>&1 <<SQL || fail "[PARITY] over-cap seed failed"
INSERT INTO public.tenant_usage(tenant_id, metric, window_start, qty, idempotency_key) VALUES
  ('${T_OVERQ}', 'query.count', '${WINDOW_NOW}T00:00:00Z', ${OVER_QTY}, 'm94-poverq-${RUNID}')
  ON CONFLICT (idempotency_key) DO NOTHING;
INSERT INTO public.tenant_budgets(tenant_id, budget_cents, period) VALUES ('${T_OVERB}', 100, 'month')
  ON CONFLICT (tenant_id) DO UPDATE SET budget_cents = EXCLUDED.budget_cents;
SQL
ok "[PARITY] second stack net + redis + postgres (same schema, same over-cap seed)"

PDB_INNET="postgres://postgres:${PGPW}@${PPG}:5432/postgres"
PREDIS_INNET="redis://${PREDIS}:6379"

step "P2/6 [PARITY] boot data-plane-router + orchestrator + tenant-control + a FRESH stripe-mock — cloud flags UNSET"
# data-plane: NO DATA_PLANE_METERING / NO DATA_PLANE_QUOTA_ENFORCEMENT (defaults OFF).
docker run -d --name "${PDPR}" --network "${PNET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
  -e REDIS_URL="${PREDIS_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e RUST_LOG=info \
  -p "127.0.0.1:${PORT_PDPR}:4011" "${DPR_IMG}" >/dev/null
# orchestrator: registered sub-services but ALL cloud flags unset (METERING_ENABLED
# unset → ingest/quota/billing/spend all no-op). Still needs the strong token.
docker run -d --name "${PMOCK}" --network "${PNET}" -e PORT=8080 -v "${MOCK_DIR}":/app:ro \
  -p "127.0.0.1:${PORT_PMOCK}:8080" "${NODE_IMAGE}" node /app/server.mjs >/dev/null
docker run -d --name "${PORCH}" --network "${PNET}" \
  -e DATABASE_URL="${PDB_INNET}" \
  -e REDIS_URL="${PREDIS_INNET}" \
  -e ORCHESTRATOR_SERVICES="metering,quota-guard,billing,spend-cap" \
  -e ORCHESTRATOR_PORT=3060 \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e STRIPE_API_BASE="http://${PMOCK}:8080" \
  -e LOG_LEVEL=debug \
  "${ORCH_IMG}" >/dev/null
# tenant-control: NO TENANT_SELFSERVE_ENABLED, NO ABUSE_GUARD_ENABLED.
docker run -d --name "${PTC}" --network "${PNET}" \
  -e DATABASE_URL="${PDB_INNET}" \
  -e REDIS_URL="${PREDIS_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TENANT_CONTROL_PORT="${TC_PORT}" \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_PTC}:${TC_PORT}" "${TC_IMG}" >/dev/null
wait_dpr "${PDPR}" "${PORT_PDPR}" || fail "[PARITY] data-plane-router not ready"
wait_tc  "${PTC}"  "${PORT_PTC}"  || fail "[PARITY] tenant-control not ready"
wait_mock "${PMOCK}" "${PORT_PMOCK}" || fail "[PARITY] stripe-mock not ready"
docker logs "${PTC}" 2>&1 | grep -q "abuse guard disabled" \
  || { docker logs "${PTC}" 2>&1 | tail -20; fail "[PARITY] tenant-control did not report abuse guard disabled (flag default not OFF?)"; }
docker logs "${PORCH}" 2>&1 | grep -q "billing disabled" \
  || { docker logs "${PORCH}" 2>&1 | tail -20; fail "[PARITY] orchestrator did not report billing disabled (flag default not OFF?)"; }
ok "[PARITY] all four services up with cloud flags UNSET (the byte-parity baseline)"

step "P3/6 [PARITY · CRUD still 200] provision a tenant + N reads → 200, then tenant_usage stays ZERO"
C="$(admin_req POST "${PORT_PTC}" /v1/tenants "{\"id\":\"${T_FUNNEL}\",\"name\":\"funnel\",\"plan\":\"nano\"}")"
[[ "${C}" == "201" ]] || fail "[PARITY] provision expected 201, got ${C} — $(head -c 300 "${BODY_TMP}")"
for n in $(seq 1 "${N_QUERIES}"); do
  C="$(post_q "${PORT_PDPR}" "$(payload_list "${PDB_INNET}" "${T_FUNNEL}")")"
  [[ "${C}" == "200" ]] || fail "[PARITY] CRUD read #${n} expected 200, got ${C} — $(head -c 300 "${BODY_TMP}")"
done
# Give the (never-spawned) flusher + (no-op) ingest several windows; usage must stay 0.
sleep "$(awk 'BEGIN{print (1500*3/1000)+1}')"
[[ "$(pg_val "${PPG}" "SELECT count(*) FROM public.tenant_usage WHERE tenant_id='${T_FUNNEL}'")" == "0" ]] \
  || fail "[PARITY] tenant_usage has rows with metering OFF — NOT byte-parity"
ok "[PARITY] CRUD 200 with metering OFF; tenant_usage has ZERO rows for the funnel tenant = byte-parity"

step "P4/6 [PARITY · over-cap still 200] over-cap tenant's /v1/query → 200 (no quota:over written; enforcement OFF)"
[[ "$(rcli "${PREDIS}" EXISTS quota:over)" == "0" ]] \
  || { red "quota:over:"; rcli "${PREDIS}" SMEMBERS quota:over; fail "[PARITY] quota:over was written with the guard OFF — NOT byte-parity"; }
C="$(post_q "${PORT_PDPR}" "$(payload_list "${PDB_INNET}" "${T_OVERQ}")")"
[[ "${C}" == "200" ]] || fail "[PARITY] over-cap tenant expected 200 (enforcement OFF), got ${C} — $(head -c 300 "${BODY_TMP}")"
ok "[PARITY] over-cap /v1/query → 200 (quota:over never written, set never consulted) = byte-parity"

step "P5/6 [PARITY · zero billing + spend OFF] fresh stripe-mock /_events count==0; spend:over never written"
sleep "$(awk 'BEGIN{print (1500*3/1000)+1}')"
PEV="$(mock_events "${PORT_PMOCK}")"
[[ "${PEV}" == "0" ]] || { cat "${EVENTS_TMP}"; fail "[PARITY] stripe-mock received ${PEV} events with BILLING_ENABLED off — expected 0"; }
[[ "$(rcli "${PREDIS}" EXISTS spend:over)" == "0" ]] \
  || { red "spend:over:"; rcli "${PREDIS}" SMEMBERS spend:over; fail "[PARITY] spend:over was written with the guard OFF — NOT byte-parity"; }
ok "[PARITY] zero Stripe meter events; spend:over never written (billing + spend-cap OFF) = byte-parity"

step "P6/6 [PARITY · abuse 404] POST /v1/abuse/admit → 404 (routes not mounted)"
C="$(admit "${PORT_PTC}" "${T_ABUSE}" project_create)"
[[ "${C}" == "404" ]] || fail "[PARITY] /v1/abuse/admit expected 404 with the flag OFF, got ${C} — $(head -c 200 "${BODY_TMP}")"
ok "[PARITY] /v1/abuse/admit → 404 (route not mounted) = byte-parity"

green "[M94] ── PARITY stack: CRUD 200 + tenant_usage 0 · over-cap 200 · 0 billing · spend:over absent · abuse 404 ALL GREEN ──"

# ══════════════════════════════════════════════════════════════════════════════
#  Summary + gate event
# ══════════════════════════════════════════════════════════════════════════════
step "summary"
green "[M94] POSITIVE: provision→key→CRUD(${N_QUERIES})→tenant_usage SUM==${N_QUERIES} (B1)→/me/usage matches (B4a)→stripe-mock meter event + idempotent (B3)→Kong /me 200 (B4b)"
green "[M94] REJECTS:  R1 quota 402 ON THE DATA PATH (B2) · R2 spend:over set at the CONTROL PLANE (B7.8; data-plane reject is a separate slice) · R3 4th project_create → 403 + tenant:suspended (B7.9)"
green "[M94] PARITY:   cloud env omitted → CRUD 200 / tenant_usage 0 / over-cap 200 / 0 billing / spend:over absent / abuse 404 = the default stack is byte-untouched (kernel #5)"

emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-cloud-edition-funnel}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m94=PASS" --outcome pass \
      --msg "Cloud edition funnel: all cloud flags ON on one isolated local stack — provision→key→CRUD→tenant_usage SUM==N (B1)→/me/usage matches (B4a)→stripe-mock meter event + idempotent (B3)→Kong /me 200 (B4b); rejects R1 quota 402 on the data path (B2), R2 spend:over at the control plane (B7.8; data-plane reject a separate slice), R3 4th project_create 403+tenant:suspended (B7.9); flag-OFF second stack -> CRUD 200, tenant_usage 0, over-cap 200, 0 billing, spend:over absent, abuse 404 (byte-parity)" \
      --ref "scripts/verify/m94-cloud-funnel.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M94] ALL GATES GREEN — the cloud edition is a working, runnable-on-local-docker managed-cloud product; flag-OFF is byte-parity"
exit 0
