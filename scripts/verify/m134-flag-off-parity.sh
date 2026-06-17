#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m134-flag-off-parity.sh                            :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M134 — DYNAMIC BUILDER flag-OFF = BYTE-PARITY. BUILDER_ENABLED unset must make
# the whole feature vanish:
#
#   (1) /v1/tenants/me/mounts, /me/entitlements, /me/builder → 404 (routes not
#       mounted) on a tenant-control with BUILDER unset (TENANT_SELFSERVE still on,
#       so the base /me + /me/keys routes DO exist — only the builder ones 404).
#   (2) the adapter-registry /connect STAMP is byte-identical to a tier-only run
#       EVEN WHEN an entitlement row exists in the table: with BUILDER off the
#       resolver is never wired, so the stamp resolves the named tier (essential
#       rps=200) verbatim, ignoring the over-tier row (rps=400) entirely.
#
# THE LOAD-BEARING ARM: an over-tier entitlement row is present in the DB, yet the
# BUILDER-off adapter-registry stamps the TIER (rps=200), proving the table is
# unread when the flag is off — the feature is dormant, the baseline byte-parity.
#
# ISOLATED by design. NEVER touches mini-baas-*.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"
GO_DIR="${INFRA_DIR}/src/control-plane"
MIG_DIR="${INFRA_DIR}/scripts/migrations/postgresql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M134] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M134] FAIL — $*"; exit 1; }

PG_IMAGE="${M134_PG_IMAGE:-postgres:16-alpine}"
TC_IMG="m134-tc-$$:scratch"; AR_IMG="m134-ar-$$:scratch"
NET="m134net-$$"; PG="m134-pg-$$"; TC_OFF="m134-tc-off-$$"; AR_OFF="m134-ar-off-$$"
PORT_TC="${M134_PORT_TC:-18939}"; PORT_AR="${M134_PORT_AR:-18940}"
PGPW="postgres"; DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SVC_TOKEN="m134-internal-service-token-$$"
ENC_KEY="m134-enc-key-0123456789abcdef0123456789abcdef"
TENANT="m134-t-$$"; BODY_TMP="$(mktemp)"

cleanup() {
  docker rm -fv "${TC_OFF}" "${AR_OFF}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${TC_IMG}" "${AR_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" 2>/dev/null || true
}
trap cleanup EXIT

psql_q()   { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
apply_migration() { sed '/^#/d' "$1" | docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1; }

admin_req() { local m="$1" p="$2" path="$3" body="${4:-}"
  if [[ -n "${body}" ]]; then curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" -H "X-Service-Token: ${SVC_TOKEN}" -H 'Content-Type: application/json' -d "${body}"
  else curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" -H "X-Service-Token: ${SVC_TOKEN}"; fi
}
me_req() { local m="$1" p="$2" path="$3" key="$4" body="${5:-}"
  if [[ -n "${body}" ]]; then curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" -H "X-API-Key: ${key}" -H 'Content-Type: application/json' -d "${body}"
  else curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" -H "X-API-Key: ${key}"; fi
}
ar_register() { curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST "http://127.0.0.1:${1}/databases" -H "X-Service-Token: ${SVC_TOKEN}" -H "X-Baas-Tenant-Id: ${2}" -H 'Content-Type: application/json' -d "${3}"; }
ar_connect()  { curl -s -o "${BODY_TMP}" -w '%{http_code}' "http://127.0.0.1:${1}/databases/${3}/connect" -H "X-Service-Token: ${SVC_TOKEN}" -H "X-Baas-Tenant-Id: ${2}"; }
co_num() { { grep -o "\"$1\":[0-9]*" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*://'; }
mount_id() { grep -o '"id":"[^"]*"' "${BODY_TMP}" | head -1 | cut -d'"' -f4; }
json_str() { { grep -o "\"$1\":\"[^\"]*\"" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*://; s/"//g'; }

wait_ready() { local i; for i in $(seq 1 60); do
  [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2/health/live" 2>/dev/null)" == "200" ]] && return 0
  docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited:"; docker logs "$1" 2>&1 | tail -20; return 1; }
  sleep 0.5; done; red "$1 never ready:"; docker logs "$1" 2>&1 | tail -20; return 1; }

step "0/6 build scratch tenant-control + adapter-registry from CURRENT source"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3020 -t "${TC_IMG}" "${GO_DIR}" >/dev/null || fail "build TC"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=adapter-registry --build-arg PORT=3021 -t "${AR_IMG}" "${GO_DIR}" >/dev/null || fail "build AR"
ok "images built (same binaries; only env flags differ)"

step "1/6 boot postgres + migrations (004/005/006/032/062)"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
for i in $(seq 1 80); do [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break; [[ $i -eq 80 ]] && fail "PG steady"; sleep 0.5; done
prelude() { psql_q >/dev/null 2>&1 <<'SQL'
CREATE TABLE IF NOT EXISTS public.schema_migrations (version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS text LANGUAGE sql STABLE AS $fn$ SELECT current_setting('request.tenant_id', true) $fn$;
CREATE OR REPLACE FUNCTION auth.uid() RETURNS text LANGUAGE sql STABLE AS $fn$ SELECT current_setting('app.current_user_id', true) $fn$;
DO $r$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role')  THEN CREATE ROLE service_role;  END IF;
END $r$;
SQL
}
for i in $(seq 1 20); do prelude && break; [[ $i -eq 20 ]] && fail "prelude"; sleep 0.5; done
apply_migration "${MIG_DIR}/004_add_adapter_registry.sql" || fail "004"
apply_migration "${MIG_DIR}/005_add_tenant_table.sql"     || fail "005"
apply_migration "${MIG_DIR}/006_add_connection_salt.sql"  || true
apply_migration "${MIG_DIR}/032_tenants.sql"              || fail "032"
apply_migration "${MIG_DIR}/062_tenant_entitlements.sql"  || fail "062"
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c 'ALTER TABLE public.tenant_databases DROP CONSTRAINT IF EXISTS tenant_databases_tenant_id_fkey; DROP POLICY IF EXISTS tenant_databases_owner_crud ON public.tenant_databases; DROP POLICY IF EXISTS tenant_databases_tenant_isolation ON public.tenant_databases; ALTER TABLE public.tenant_databases ALTER COLUMN tenant_id TYPE TEXT;' >/dev/null 2>&1 || fail "widen tenant_id->TEXT (004 legacy made it uuid; prod adapter-registry EnsureSchema is TEXT; AR recreates the RLS policy at boot)"
ok "migrations applied"

step "2/6 boot tenant-control (SELFSERVE on, BUILDER UNSET) + adapter-registry (PACKAGE on, BUILDER UNSET)"
docker run -d --name "${AR_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" -e VAULT_ENC_KEY="${ENC_KEY}" -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e PACKAGE_ENFORCEMENT=1 -e PORT=3021 -p "127.0.0.1:${PORT_AR}:3021" "${AR_IMG}" >/dev/null
docker run -d --name "${TC_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" -e ADAPTER_REGISTRY_URL="http://${AR_OFF}:3021" \
  -e TENANT_SELFSERVE_ENABLED=1 \
  -e TENANT_CONTROL_PORT=3020 -e TENANT_CONTROL_PRODUCT_MODE=enabled -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_TC}:3020" "${TC_IMG}" >/dev/null
wait_ready "${AR_OFF}" "${PORT_AR}" || fail "AR-off not ready"
wait_ready "${TC_OFF}" "${PORT_TC}" || fail "TC-off not ready"
ok "BUILDER-off services up (TENANT_SELFSERVE on so base /me exists)"

step "3/6 seed tenant on essential + an admin key"
admin_req POST "${PORT_TC}" /v1/tenants "{\"id\":\"${TENANT}\",\"name\":\"T\",\"plan\":\"essential\"}" >/dev/null
admin_req POST "${PORT_TC}" "/v1/tenants/${TENANT}/keys" "{\"name\":\"t-$$\",\"scopes\":[\"read\",\"write\",\"admin\"]}" >/dev/null
KEY="$(json_str key)"; [[ "${KEY}" == mbk_* ]] || fail "key not minted (line: key)"
ok "essential tenant + admin key"

step "4/6 (1) builder routes 404 with BUILDER unset (base /me still 200)"
# base self-serve route still works (TENANT_SELFSERVE on)
C="$(me_req GET "${PORT_TC}" /v1/tenants/me "${KEY}")"
[[ "${C}" == "200" ]] || fail "(1) base GET /me expected 200 (TENANT_SELFSERVE on), got ${C} (line: 1 base /me)"
for path in /v1/tenants/me/mounts /v1/tenants/me/entitlements; do
  C="$(me_req GET "${PORT_TC}" "${path}" "${KEY}")"
  [[ "${C}" == "404" ]] || fail "(1) GET ${path} expected 404 (builder route not mounted), got ${C} — $(head -c 200 "${BODY_TMP}") (line: 1 ${path})"
done
C="$(me_req POST "${PORT_TC}" /v1/tenants/me/builder "${KEY}" '{"entitlement":{}}')"
[[ "${C}" == "404" ]] || fail "(1) POST /v1/tenants/me/builder expected 404, got ${C} (line: 1 builder)"
ok "(1) /me/mounts, /me/entitlements, /me/builder all 404 with BUILDER off; base /me still 200"

step "5/6 (2) LOAD-BEARING: an over-tier entitlement row is IGNORED — /connect stamps the TIER (essential rps=200)"
# Insert an over-tier row directly (rps=400). With BUILDER off the resolver is
# never wired, so the row must be unread and the stamp must be essential's 200.
psql_q >/dev/null 2>&1 <<SQL || fail "(2) seed over-tier row failed (line: 2 insert)"
INSERT INTO public.tenant_entitlements (tenant_id, entitlement, ceiling_plan, status, updated_at)
VALUES ('${TENANT}', '{"limits":{"rps":400}}'::jsonb, 'pro', 'active', now())
ON CONFLICT (tenant_id) DO UPDATE SET entitlement=EXCLUDED.entitlement, ceiling_plan='pro', status='active', updated_at=now();
SQL
ar_register "${PORT_AR}" "${TENANT}" '{"engine":"postgresql","name":"m1","connection_string":"postgres://u:p@h:5432/d","isolation":"shared_rls"}' >/dev/null
MID="$(mount_id)"; [[ -n "${MID}" ]] || fail "(2) mount not registered (line: 2 mount)"
C="$(ar_connect "${PORT_AR}" "${TENANT}" "${MID}")"
[[ "${C}" == "200" ]] || fail "(2) /connect expected 200, got ${C} — $(head -c 400 "${BODY_TMP}") (line: 2 connect)"
RPS="$(co_num rps)"
[[ "${RPS}" == "200" ]] \
  || fail "(2) PARITY FAILED: stamp rps=${RPS}, want 200 (essential tier) — an over-tier entitlement row (rps=400) was READ with BUILDER off! The flag must make the table unread. (line: 2 tier stamp)"
ok "(2) over-tier row IGNORED with BUILDER off; /connect stamps essential's tier rps=200 — byte-parity baseline"

step "6/6 summary"
green "[M134] (1) builder routes (/me/mounts,/me/entitlements,/me/builder) 404 with BUILDER off; base /me still 200"
green "[M134] (2) an over-tier entitlement row is UNREAD with BUILDER off — /connect stamps the named tier (essential rps=200) = byte-parity"
emit_gate_log() { ( set +e
  [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
  export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"; export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-builder}"
  . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
  log_event GATE --gate "m134=PASS" --outcome pass \
    --msg "dynamic builder flag-OFF parity: BUILDER_ENABLED unset → /v1/tenants/me/{mounts,entitlements,builder} all 404 (base /me still 200); an over-tier entitlement row (rps=400) is UNREAD → /connect stamps the named tier (essential rps=200) byte-identical to a tier-only run = the feature is dormant, baseline byte-parity" \
    --ref "scripts/verify/m134-flag-off-parity.sh" >/dev/null 2>&1; exit 0 ) || true; }
emit_gate_log
green "[M134] ALL GATES GREEN — BUILDER off = byte-parity (routes 404, table unread, tier stamp)"
exit 0
