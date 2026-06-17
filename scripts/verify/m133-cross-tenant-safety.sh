#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m133-cross-tenant-safety.sh                        :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M133 — DYNAMIC BUILDER cross-tenant safety: A's credential can NEVER read or
# modify B's mounts/entitlements, and the OPERATOR routes are service-token-only.
#
#   (1) A's GET /me/entitlements resolves to A (A's plan), never B.
#   (2) A's PATCH /me/entitlements changes ONLY A — B's entitlement row is
#       untouched after A writes (B has a uniquely-detectable ceiling none of A's
#       writes could set).
#   (3) The OPERATOR route PUT /v1/tenants/{B}/entitlement with A's TENANT key
#       (not the service token) → 401 (a tenant credential is not an operator).
#   (4) No auth header → 401 on /me/entitlements and /me/mounts.
#
# THE LOAD-BEARING ARMS: (2) B's row is byte-unchanged after A's writes, and (3)
# A's tenant key cannot reach the operator's ceiling-authority route. There is no
# {id} on the self-serve surface (the tenant is the credential), so a cross-tenant
# WRITE is impossible by construction; the operator {id} routes are walled by the
# service token.
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
step()  { cyan "[M133] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M133] FAIL — $*"; exit 1; }

PG_IMAGE="${M133_PG_IMAGE:-postgres:16-alpine}"
TC_IMG="m133-tc-$$:scratch"; AR_IMG="m133-ar-$$:scratch"
NET="m133net-$$"; PG="m133-pg-$$"; TC="m133-tc-$$"; AR="m133-ar-$$"
PORT_TC="${M133_PORT_TC:-18937}"; PORT_AR="${M133_PORT_AR:-18938}"
PGPW="postgres"; DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SVC_TOKEN="m133-internal-service-token-$$"
ENC_KEY="m133-enc-key-0123456789abcdef0123456789abcdef"
TENANT_A="m133-a-$$"; TENANT_B="m133-b-$$"; BODY_TMP="$(mktemp)"

cleanup() {
  docker rm -fv "${TC}" "${AR}" "${PG}" >/dev/null 2>&1 || true
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
# An operator route called with a TENANT key (NOT the service token).
key_req() { local m="$1" p="$2" path="$3" key="$4" body="${5:-}"
  curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" -H "X-API-Key: ${key}" -H 'Content-Type: application/json' -d "${body}"; }
json_str() { { grep -o "\"$1\":\"[^\"]*\"" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*://; s/"//g'; }

wait_ready() { local i; for i in $(seq 1 60); do
  [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2/health/live" 2>/dev/null)" == "200" ]] && return 0
  docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited:"; docker logs "$1" 2>&1 | tail -20; return 1; }
  sleep 0.5; done; red "$1 never ready:"; docker logs "$1" 2>&1 | tail -20; return 1; }

step "0/7 build scratch tenant-control + adapter-registry from CURRENT source"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3020 -t "${TC_IMG}" "${GO_DIR}" >/dev/null || fail "build TC"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=adapter-registry --build-arg PORT=3021 -t "${AR_IMG}" "${GO_DIR}" >/dev/null || fail "build AR"
ok "images built"

step "1/7 boot postgres + migrations (004/005/006/032/062)"
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

step "2/7 boot tenant-control + adapter-registry (SELFSERVE+BUILDER on, PACKAGE on)"
docker run -d --name "${AR}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" -e VAULT_ENC_KEY="${ENC_KEY}" -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e PACKAGE_ENFORCEMENT=1 -e BUILDER_ENABLED=1 -e PORT=3021 -p "127.0.0.1:${PORT_AR}:3021" "${AR_IMG}" >/dev/null
docker run -d --name "${TC}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" -e ADAPTER_REGISTRY_URL="http://${AR}:3021" \
  -e TENANT_SELFSERVE_ENABLED=1 -e BUILDER_ENABLED=1 \
  -e TENANT_CONTROL_PORT=3020 -e TENANT_CONTROL_PRODUCT_MODE=enabled -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_TC}:3020" "${TC_IMG}" >/dev/null
wait_ready "${AR}" "${PORT_AR}" || fail "AR not ready"
wait_ready "${TC}" "${PORT_TC}" || fail "TC not ready"
ok "services up"

step "3/7 seed A (essential) + B (pro) + admin keys; set B a UNIQUE operator ceiling (max)"
admin_req POST "${PORT_TC}" /v1/tenants "{\"id\":\"${TENANT_A}\",\"name\":\"A\",\"plan\":\"essential\"}" >/dev/null
admin_req POST "${PORT_TC}" /v1/tenants "{\"id\":\"${TENANT_B}\",\"name\":\"B\",\"plan\":\"pro\"}" >/dev/null
admin_req POST "${PORT_TC}" "/v1/tenants/${TENANT_A}/keys" "{\"name\":\"a-$$\",\"scopes\":[\"read\",\"write\",\"admin\"]}" >/dev/null
KEY_A="$(json_str key)"; [[ "${KEY_A}" == mbk_* ]] || fail "A key (line: A key)"
admin_req POST "${PORT_TC}" "/v1/tenants/${TENANT_B}/keys" "{\"name\":\"b-$$\",\"scopes\":[\"read\",\"write\",\"admin\"]}" >/dev/null
KEY_B="$(json_str key)"; [[ "${KEY_B}" == mbk_* ]] || fail "B key (line: B key)"
# Operator gives B a UNIQUE ceiling (max) so any A-induced change to B's row is detectable.
C="$(admin_req PATCH "${PORT_TC}" "/v1/tenants/${TENANT_B}/ceiling" '{"ceiling_plan":"max"}')"
[[ "${C}" == "200" ]] || fail "seed B ceiling expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: B ceiling)"
[[ "$(psql_val "SELECT ceiling_plan FROM public.tenant_entitlements WHERE tenant_id='${TENANT_B}'")" == "max" ]] \
  || fail "B's ceiling_plan not stored as max (line: B ceiling row)"
ok "A(essential) + B(pro, operator ceiling=max) seeded"

step "4/7 (1) A's GET /me/entitlements resolves to A (plan=essential), never B"
C="$(me_req GET "${PORT_TC}" /v1/tenants/me/entitlements "${KEY_A}")"
[[ "${C}" == "200" ]] || fail "(1) A GET /me/entitlements expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: 1 A get)"
grep -q "\"tenant_id\":\"${TENANT_A}\"" "${BODY_TMP}" || fail "(1) A's entitlements not resolved to A (line: 1 is A)"
if grep -q "${TENANT_B}" "${BODY_TMP}"; then fail "(1) tenant B leaked into A's /me/entitlements! (line: 1 no B)"; fi
ok "(1) A's /me/entitlements is A only; B absent"

step "5/7 (2) LOAD-BEARING: A's PATCH /me/entitlements changes ONLY A — B's row byte-unchanged"
B_BEFORE="$(psql_val "SELECT md5(entitlement::text || ceiling_plan || status) FROM public.tenant_entitlements WHERE tenant_id='${TENANT_B}'")"
C="$(me_req PATCH "${PORT_TC}" /v1/tenants/me/entitlements "${KEY_A}" '{"limits":{"rps":150}}')"
[[ "${C}" == "200" ]] || fail "(2) A PATCH /me/entitlements expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: 2 A patch)"
B_AFTER="$(psql_val "SELECT md5(entitlement::text || ceiling_plan || status) FROM public.tenant_entitlements WHERE tenant_id='${TENANT_B}'")"
[[ -n "${B_BEFORE}" && "${B_BEFORE}" == "${B_AFTER}" ]] \
  || fail "(2) B's entitlement row CHANGED after A's PATCH (before=${B_BEFORE} after=${B_AFTER}) — cross-tenant write! (line: 2 B unchanged)"
# And A's own row IS the one that changed.
[[ "$(psql_val "SELECT (entitlement->'limits'->>'rps') FROM public.tenant_entitlements WHERE tenant_id='${TENANT_A}'")" == "150" ]] \
  || fail "(2) A's own row did not get rps=150 (line: 2 A changed)"
ok "(2) A's PATCH wrote A's row (rps=150); B's row byte-unchanged = no cross-tenant write"

step "6/7 (3) LOAD-BEARING: A's TENANT key on the OPERATOR route PUT /v1/tenants/{B}/entitlement → 401"
C="$(key_req PUT "${PORT_TC}" "/v1/tenants/${TENANT_B}/entitlement" "${KEY_A}" '{"ceiling_plan":"max","entitlement":{"limits":{"rps":800}}}')"
[[ "${C}" == "401" ]] \
  || fail "(3) A's tenant key on the operator route expected 401, got ${C} — a tenant key must NOT be an operator! (line: 3 operator 401)"
# Independent truth: B's ceiling is still max (A could not change it via the operator route).
[[ "$(psql_val "SELECT ceiling_plan FROM public.tenant_entitlements WHERE tenant_id='${TENANT_B}'")" == "max" ]] \
  || fail "(3) B's ceiling changed despite the 401 (line: 3 B ceiling intact)"
ok "(3) operator route rejects a tenant key (401); B's ceiling intact"

step "7/7 (4) no-auth → 401 on /me/entitlements + /me/mounts"
C="$(curl -s -o "${BODY_TMP}" -w '%{http_code}' "http://127.0.0.1:${PORT_TC}/v1/tenants/me/entitlements")"
[[ "${C}" == "401" ]] || fail "(4) no-auth GET /me/entitlements expected 401, got ${C} (line: 4 ent 401)"
C="$(curl -s -o "${BODY_TMP}" -w '%{http_code}' "http://127.0.0.1:${PORT_TC}/v1/tenants/me/mounts")"
[[ "${C}" == "401" ]] || fail "(4) no-auth GET /me/mounts expected 401, got ${C} (line: 4 mounts 401)"
ok "(4) unauthenticated builder routes → 401"

green "[M133] A sees only A; A's writes never touch B; operator routes reject a tenant key (401); no-auth → 401"
emit_gate_log() { ( set +e
  [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
  export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"; export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-builder}"
  . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
  log_event GATE --gate "m133=PASS" --outcome pass \
    --msg "dynamic builder cross-tenant safety: A's /me/entitlements is A only; A's PATCH writes A's row and leaves B's byte-unchanged (no {id} on self-serve → no cross-tenant write); A's tenant key on the operator route PUT /v1/tenants/{B}/entitlement → 401 (B's ceiling intact); no-auth → 401" \
    --ref "scripts/verify/m133-cross-tenant-safety.sh" >/dev/null 2>&1; exit 0 ) || true; }
emit_gate_log
green "[M133] ALL GATES GREEN — cross-tenant isolation by construction + operator wall"
exit 0
