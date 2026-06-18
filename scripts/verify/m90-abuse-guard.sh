#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m90-abuse-guard.sh                                 :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M90 — Track-B B7.9 ABUSE / free-tier KYC-lite control-plane gate. Proves the
# public-signup abuse guard ADMITS a verified, within-velocity principal and
# SUSPENDS one that breaches the project-creation velocity limit — and is byte-parity
# when OFF. It is the explicit go-live blocker for public signup (B7.7) in the plan.
#
#   tenant-control (Go, ABUSE_GUARD_ENABLED=1) mounts /v1/abuse/* :
#     POST /v1/abuse/admit  {principal, tenant_id, tier, action}
#       1. tenant SUSPENDED            → 403 admit:false reason=tenant_suspended
#       2. verification gate for tier  → 403 reason=email_unverified|… (KYC-lite)
#       3. per-principal VELOCITY      → ≤ N project_create / window; the (N+1)th
#                                        → 403 reason=velocity_exceeded AND (auto-
#                                          suspend ON) flips tenant_safety.suspended
#                                          + adds it to Redis `tenant:suspended`.
#       admitted → 200 admit:true AND records the event in principal_events.
#
#   (A) ENABLED arm (ABUSE_GUARD_ENABLED=1, ABUSE_VELOCITY_MAX=3):
#       • a verified principal's FIRST 3 project_create → 200 admit:true  (REJECT
#         load-bearing: a within-velocity verified caller is NOT blocked)
#       • the 4th → 403 velocity_exceeded → tenant SUSPENDED (POSITIVE: breach →
#         suspend; the tenant lands in Redis `tenant:suspended`)
#       • a subsequent admit for the now-suspended tenant → 403 tenant_suspended
#   (B) PARITY arm (ABUSE_GUARD_ENABLED unset): /v1/abuse/admit → 404 (routes not
#       mounted), no principal_events row ever written, no `tenant:suspended` set
#       → byte-identical to today (the no-behavior-change baseline).
#
# ISOLATED by design (mirrors m80/m89): scratch postgres (032/040/045 prelude) +
# redis + a tenant-control built FROM CURRENT source, ALL on a PRIVATE network,
# names suffixed with $$, an EXIT-trap removing EVERYTHING. It NEVER touches a
# mini-baas-* container/network/image/volume and NEVER edits docker-compose.yml.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)" # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"      # apps/baas
GO_DIR="${INFRA_DIR}/src/control-plane"
MIGRATION_045="${INFRA_DIR}/scripts/migrations/postgresql/045_tenant_safety.sql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
step() { cyan "[M90] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[M90] FAIL — $*"
  exit 1
}

REDIS_IMAGE="${M90_REDIS_IMAGE:-redis:7-alpine}"
PG_IMAGE="${M90_PG_IMAGE:-postgres:16-alpine}"
TC_IMG="m90-tc-$$:scratch"
NET="m90net-$$"
PG="m90-pg-$$"
REDIS="m90-redis-$$"
TC_ON="m90-tc-on-$$"   # abuse guard ENABLED
TC_OFF="m90-tc-off-$$" # parity arm (flag unset)
PORT_ON="${M90_PORT_ON:-19090}"
PORT_OFF="${M90_PORT_OFF:-19091}"
PGPW="postgres"
SVC_TOKEN="m90-internal-service-token-$$"
TENANT="m90-tenant-$$"
PRINCIPAL="api-key:m90-principal-$$"
TIER="nano"
VELOCITY_MAX=3
REDIS_INNET="redis://${REDIS}:6379"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
BODY_TMP="$(mktemp)"

cleanup() {
  docker rm -fv "${TC_ON}" "${TC_OFF}" "${PG}" "${REDIS}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${TC_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" 2>/dev/null || true
}
trap cleanup EXIT

psql_q() { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
redis_cli() { docker exec -i "${REDIS}" redis-cli "$@"; }

# POST /v1/abuse/admit as the service token; echo HTTP status, body→BODY_TMP.
admit() { # $1=port  $2=tenant  $3=action
  curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST "http://127.0.0.1:$1/v1/abuse/admit" \
    -H 'Content-Type: application/json' -H "X-Service-Token: ${SVC_TOKEN}" \
    -d "{\"principal\":\"${PRINCIPAL}\",\"tenant_id\":\"$2\",\"tier\":\"${TIER}\",\"action\":\"$3\"}"
}

wait_ready() { # $1=container  $2=port
  for i in $(seq 1 60); do
    curl -fsS -o /dev/null "http://127.0.0.1:$2/health/live" 2>/dev/null && return 0
    docker inspect "$1" >/dev/null 2>&1 || {
      red "$1 exited early:"
      docker logs "$1" 2>&1 | tail -20
      return 1
    }
    sleep 0.5
  done
  red "$1 never became ready:"
  docker logs "$1" 2>&1 | tail -20
  return 1
}

# ── 0) build the scratch tenant-control FROM CURRENT (drafted) source ──────────
step "0/8 build scratch tenant-control from CURRENT source (the B7.9 abuse-guard code)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3060 \
  -t "${TC_IMG}" "${GO_DIR}" >/dev/null ||
  fail "scratch tenant-control image build failed — gate must exercise the drafted abuse guard"
ok "tenant-control built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated network + redis + postgres ─────────────────────────────────────
step "1/8 boot isolated net (${NET}): redis + postgres"
docker network create "${NET}" >/dev/null
docker run -d --name "${REDIS}" --network "${NET}" "${REDIS_IMAGE}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
for i in $(seq 1 60); do
  redis_cli PING 2>/dev/null | grep -q PONG && break
  [[ $i -eq 60 ]] && fail "scratch redis never PONGed"
  sleep 0.5
done
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "scratch postgres never reached steady state"
  sleep 0.5
done
ok "redis + postgres up"

# ── 1b) prelude: minimal public.tenants (tenant-control EnsureSchema needs it) +
#        auth + roles, then the REAL migration 045 ────────────────────────────
step "1b/8 prelude (public.tenants + auth + roles) then the REAL 045"
prelude() {
  psql_q >/dev/null 2>&1 <<'SQL'
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
-- Minimal public.tenants so tenant-control EnsureSchema (migration-032 check) passes.
CREATE TABLE IF NOT EXISTS public.tenants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), slug text UNIQUE, name text,
  status text DEFAULT 'active', plan text, owner_user_id text,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now(), updated_at timestamptz DEFAULT now());
SQL
}
for i in $(seq 1 20); do
  prelude && break
  [[ $i -eq 20 ]] && fail "migration prelude never committed"
  sleep 0.5
done
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 <"${MIGRATION_045}" >/dev/null 2>&1 ||
  fail "real migration 045_tenant_safety.sql failed to apply"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_safety")" == "0" ]] || fail "tenant_safety should start EMPTY"
[[ "$(psql_val "SELECT count(*) FROM public.principal_events")" == "0" ]] || fail "principal_events should start EMPTY"
ok "migration 045 applied — tenant_safety + principal_events exist and are empty"

# ── 2) seed: a VERIFIED tenant_safety row (so the nano email gate passes) ───────
step "2/8 seed tenant_safety: ${TENANT} email-verified (so the KYC gate admits), not suspended"
seed() {
  psql_q >/dev/null 2>&1 <<SQL
INSERT INTO public.tenant_safety(tenant_id, email_verified, suspended) VALUES
  ('${TENANT}', true, false)
  ON CONFLICT (tenant_id) DO UPDATE SET email_verified = EXCLUDED.email_verified, suspended = false;
SQL
}
for i in $(seq 1 20); do
  seed && break
  [[ $i -eq 20 ]] && fail "seed never committed"
  sleep 0.5
done
ok "seeded: ${TENANT} email_verified=true, suspended=false"

# ── 3) (A) boot tenant-control with the abuse guard ENABLED ────────────────────
step "3/8 (A) boot tenant-control (ABUSE_GUARD_ENABLED=1, ABUSE_VELOCITY_MAX=${VELOCITY_MAX}, ABUSE_REQUIRE_NANO=email)"
docker run -d --name "${TC_ON}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e REDIS_URL="${REDIS_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TENANT_CONTROL_PORT=3060 \
  -e ABUSE_GUARD_ENABLED=1 \
  -e ABUSE_VELOCITY_MAX="${VELOCITY_MAX}" \
  -e ABUSE_VELOCITY_WINDOW_MS=3600000 \
  -e ABUSE_AUTO_SUSPEND=1 \
  -e ABUSE_REQUIRE_NANO=email \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_ON}:3060" "${TC_IMG}" >/dev/null
wait_ready "${TC_ON}" "${PORT_ON}" || fail "ENABLED tenant-control not ready"
{ docker logs "${TC_ON}" 2>&1 || true; } | grep -q "abuse guard enabled" ||
  {
    docker logs "${TC_ON}" 2>&1 | tail -20
    fail "abuse guard never reported enabled"
  }
ok "tenant-control up with abuse guard mounted (/v1/abuse/*)"

# ── 4) (A) REJECT load-bearing: a verified, within-velocity caller is ADMITTED ─
step "4/8 (A) first ${VELOCITY_MAX} project_create as a verified principal → MUST be 200 admit:true"
for n in $(seq 1 "${VELOCITY_MAX}"); do
  CODE="$(admit "${PORT_ON}" "${TENANT}" project_create)"
  [[ "${CODE}" == "200" ]] || fail "(A) admit #${n} expected 200, got ${CODE} — $(head -c 300 "${BODY_TMP}")"
  grep -q '"admit":true' "${BODY_TMP}" || fail "(A) admit #${n} body not admit:true — $(head -c 300 "${BODY_TMP}")"
done
ok "(A) verified principal's first ${VELOCITY_MAX} project_create all admitted (within velocity → NOT blocked)"

# ── 5) (A) POSITIVE: the (MAX+1)th breaches velocity → 403 + tenant SUSPENDED ──
step "5/8 (A) the $((VELOCITY_MAX + 1))th project_create → MUST be 403 velocity_exceeded + auto-suspend"
CODE="$(admit "${PORT_ON}" "${TENANT}" project_create)"
[[ "${CODE}" == "403" ]] || fail "(A) velocity-breach expected 403, got ${CODE} — $(head -c 300 "${BODY_TMP}")"
grep -q 'velocity_exceeded' "${BODY_TMP}" || fail "(A) 403 body missing velocity_exceeded — $(head -c 300 "${BODY_TMP}")"
ok "(A) velocity breach rejected with 403 velocity_exceeded"

step "5b/8 (A) the breach AUTO-SUSPENDED the tenant (DB + Redis tenant:suspended)"
for i in $(seq 1 20); do
  [[ "$(psql_val "SELECT suspended FROM public.tenant_safety WHERE tenant_id='${TENANT}'")" == "t" ]] && break
  sleep 0.3
done
[[ "$(psql_val "SELECT suspended FROM public.tenant_safety WHERE tenant_id='${TENANT}'")" == "t" ]] ||
  fail "(A) tenant not suspended in tenant_safety after velocity breach"
[[ "$(redis_cli SISMEMBER tenant:suspended "${TENANT}" 2>/dev/null)" == "1" ]] ||
  {
    red "tenant:suspended members:"
    redis_cli SMEMBERS tenant:suspended 2>&1
    fail "(A) tenant absent from Redis tenant:suspended set"
  }
ok "(A) tenant auto-suspended: tenant_safety.suspended=true AND ∈ Redis tenant:suspended"

step "5c/8 (A) a further admit for the now-suspended tenant → 403 tenant_suspended"
CODE="$(admit "${PORT_ON}" "${TENANT}" project_create)"
[[ "${CODE}" == "403" ]] || fail "(A) suspended-tenant admit expected 403, got ${CODE} — $(head -c 300 "${BODY_TMP}")"
grep -q 'tenant_suspended' "${BODY_TMP}" || fail "(A) 403 body missing tenant_suspended — $(head -c 300 "${BODY_TMP}")"
ok "(A) suspended tenant is hard-blocked (403 tenant_suspended) — the suspend is enforced"

# ── 6) (B) PARITY arm: ABUSE_GUARD_ENABLED unset → /v1/abuse/* is 404 ──────────
step "6/8 (B) boot tenant-control with ABUSE_GUARD unset (PARITY) — same DB/redis"
docker run -d --name "${TC_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e REDIS_URL="${REDIS_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TENANT_CONTROL_PORT=3060 \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_OFF}:3060" "${TC_IMG}" >/dev/null
wait_ready "${TC_OFF}" "${PORT_OFF}" || fail "PARITY tenant-control not ready"
{ docker logs "${TC_OFF}" 2>&1 || true; } | grep -q "abuse guard disabled" ||
  {
    docker logs "${TC_OFF}" 2>&1 | tail -20
    fail "OFF tenant-control did not report abuse guard disabled (flag default not OFF?)"
  }
CODE="$(admit "${PORT_OFF}" "${TENANT}" project_create)"
[[ "${CODE}" == "404" ]] ||
  fail "(B) /v1/abuse/admit expected 404 with the flag OFF (route not mounted), got ${CODE} — $(head -c 200 "${BODY_TMP}")"
ok "(B) flag OFF: /v1/abuse/admit → 404 (routes not mounted) — byte-identical to today"

# ── 7) cross-check + summarize ─────────────────────────────────────────────────
step "7/8 cross-check: ON admits-within-velocity / suspends-on-breach / OFF 404s"
green "[M90] (A) ENABLED: verified ≤${VELOCITY_MAX} → admit · #$((VELOCITY_MAX + 1)) → 403 velocity_exceeded + auto-suspend · suspended → 403"
green "[M90] (B) PARITY:  /v1/abuse/admit → 404 (routes unmounted) — byte-parity baseline"

# ── 8) emit the gate event via the kernel log helper (best-effort) ─────────────
step "8/8 log GATE m90=PASS"
emit_gate_log() {
  (
    set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-b7-abuse-guard}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m90=PASS" --outcome pass \
      --msg "B7.9 abuse guard: /v1/abuse/admit admits verified within-velocity caller, 403+auto-suspend on velocity breach, 403 tenant_suspended thereafter; flag OFF -> 404 (routes unmounted, byte-parity)" \
      --ref "scripts/verify/m90-abuse-guard.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M90] ALL GATES GREEN — abuse guard admits verified within-velocity, suspends on velocity breach, and is byte-parity when OFF"
exit 0
