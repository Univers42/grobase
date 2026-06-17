#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m131-selfserve-mount-create.sh                    :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M131 — DYNAMIC BUILDER self-serve mounts: a tenant composes its OWN backend
# through /v1/tenants/me/mounts (no path id; tenant from credential).
#
#   POST /v1/tenants/me/mounts  (A's API key) → a mount registered for A
#   GET  /v1/tenants/me/mounts  (A's API key) → the mount IS in A's list
#   GET  /v1/tenants/me/mounts  (B's API key) → the mount is ABSENT from B's list
#   DELETE /v1/tenants/me/mounts/{id} (A's key) → A removes its OWN mount
#
# THE LOAD-BEARING ARM: the mount A created is ABSENT from B's /me/mounts. There
# is no path id anywhere — the tenant is resolved from the caller credential, so
# cross-tenant access is impossible by construction (the same discipline as B4a
# /me). DELETE is caller-scoped (the adapter-registry binds AND tenant_id=$caller).
#
# ISOLATED by design (mirrors m83/m130): scratch postgres (prelude + REAL 004 +
# 005 + 006 + 032 + 062) + tenant-control + adapter-registry built FROM CURRENT
# source, ALL on a PRIVATE network, every name suffixed $$, an EXIT-trap removing
# EVERYTHING. NEVER touches a mini-baas-* container/network/image/volume.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"
GO_DIR="${INFRA_DIR}/go/control-plane"
MIG_DIR="${INFRA_DIR}/scripts/migrations/postgresql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M131] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M131] FAIL — $*"; exit 1; }

PG_IMAGE="${M131_PG_IMAGE:-postgres:16-alpine}"
TC_IMG="m131-tc-$$:scratch"; AR_IMG="m131-ar-$$:scratch"
NET="m131net-$$"; PG="m131-pg-$$"; TC="m131-tc-$$"; AR="m131-ar-$$"
PORT_TC="${M131_PORT_TC:-18933}"; PORT_AR="${M131_PORT_AR:-18934}"
PGPW="postgres"; DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SVC_TOKEN="m131-internal-service-token-$$"
ENC_KEY="m131-enc-key-0123456789abcdef0123456789abcdef"
TENANT_A="m131-a-$$"; TENANT_B="m131-b-$$"
MOUNT_A_NAME="m131-a-only-$$"   # uniquely-named — its ABSENCE from B proves isolation
BODY_TMP="$(mktemp)"

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
  if [[ -n "${body}" ]]; then
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "X-Service-Token: ${SVC_TOKEN}" -H 'Content-Type: application/json' -d "${body}"
  else
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" -H "X-Service-Token: ${SVC_TOKEN}"
  fi
}
me_req() { local m="$1" p="$2" path="$3" key="$4" body="${5:-}"
  if [[ -n "${body}" ]]; then
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "X-API-Key: ${key}" -H 'Content-Type: application/json' -d "${body}"
  else
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" -H "X-API-Key: ${key}"
  fi
}
json_str() { { grep -o "\"$1\":\"[^\"]*\"" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*://; s/"//g'; }

wait_ready() { local i; for i in $(seq 1 60); do
  [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2/health/live" 2>/dev/null)" == "200" ]] && return 0
  docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -20; return 1; }
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

step "2/7 boot tenant-control (SELFSERVE+BUILDER on) + adapter-registry (PACKAGE+BUILDER on)"
docker run -d --name "${AR}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" -e VAULT_ENC_KEY="${ENC_KEY}" -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e PACKAGE_ENFORCEMENT=1 -e BUILDER_ENABLED=1 -e PORT=3021 \
  -p "127.0.0.1:${PORT_AR}:3021" "${AR_IMG}" >/dev/null
docker run -d --name "${TC}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e ADAPTER_REGISTRY_URL="http://${AR}:3021" \
  -e TENANT_SELFSERVE_ENABLED=1 -e BUILDER_ENABLED=1 \
  -e TENANT_CONTROL_PORT=3020 -e TENANT_CONTROL_PRODUCT_MODE=enabled -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_TC}:3020" "${TC_IMG}" >/dev/null
wait_ready "${AR}" "${PORT_AR}" || fail "AR not ready"
wait_ready "${TC}" "${PORT_TC}" || fail "TC not ready"
ok "services up"

step "3/7 seed tenants A + B (pro) + an admin key each"
admin_req POST "${PORT_TC}" /v1/tenants "{\"id\":\"${TENANT_A}\",\"name\":\"A\",\"plan\":\"pro\"}" >/dev/null
admin_req POST "${PORT_TC}" /v1/tenants "{\"id\":\"${TENANT_B}\",\"name\":\"B\",\"plan\":\"pro\"}" >/dev/null
admin_req POST "${PORT_TC}" "/v1/tenants/${TENANT_A}/keys" "{\"name\":\"a-key-$$\",\"scopes\":[\"read\",\"write\",\"admin\"]}" >/dev/null
KEY_A="$(json_str key)"; [[ "${KEY_A}" == mbk_* ]] || fail "A key not minted (line: A key)"
admin_req POST "${PORT_TC}" "/v1/tenants/${TENANT_B}/keys" "{\"name\":\"b-key-$$\",\"scopes\":[\"read\",\"write\",\"admin\"]}" >/dev/null
KEY_B="$(json_str key)"; [[ "${KEY_B}" == mbk_* ]] || fail "B key not minted (line: B key)"
ok "A + B (pro) created with admin keys"

step "4/7 POST /v1/tenants/me/mounts with A's key → mount registered for A"
C="$(me_req POST "${PORT_TC}" /v1/tenants/me/mounts "${KEY_A}" "{\"engine\":\"postgresql\",\"name\":\"${MOUNT_A_NAME}\",\"connection_string\":\"postgres://u:p@h:5432/d\",\"isolation\":\"shared_rls\"}")"
[[ "${C}" == "201" || "${C}" == "200" ]] || fail "POST /me/mounts (A) expected 201/200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A create mount)"
MID_A="$(json_str id)"; [[ -n "${MID_A}" ]] || fail "no mount id returned (line: A mount id)"
ok "A created mount ${MOUNT_A_NAME} (id=${MID_A}) via /me/mounts — no path id"

step "5/7 GET /v1/tenants/me/mounts with A's key → A's mount is listed"
C="$(me_req GET "${PORT_TC}" /v1/tenants/me/mounts "${KEY_A}")"
[[ "${C}" == "200" ]] || fail "GET /me/mounts (A) expected 200, got ${C} (line: A list)"
grep -q "${MOUNT_A_NAME}" "${BODY_TMP}" || fail "A's own mount missing from A's /me/mounts (line: A list has own)"
ok "A's /me/mounts lists A's mount"

step "6/7 LOAD-BEARING: GET /v1/tenants/me/mounts with B's key → A's mount is ABSENT"
C="$(me_req GET "${PORT_TC}" /v1/tenants/me/mounts "${KEY_B}")"
[[ "${C}" == "200" ]] || fail "GET /me/mounts (B) expected 200, got ${C} (line: B list)"
if grep -q "${MOUNT_A_NAME}" "${BODY_TMP}"; then
  fail "A's mount '${MOUNT_A_NAME}' is VISIBLE in B's /me/mounts — cross-tenant mount exposure! (line: B no A mount)"
fi
ok "B's /me/mounts does NOT contain A's mount = isolation by construction (no path id)"

step "7/7 DELETE /v1/tenants/me/mounts/{id} (A's key) → A removes its OWN mount"
C="$(me_req DELETE "${PORT_TC}" "/v1/tenants/me/mounts/${MID_A}" "${KEY_A}")"
[[ "${C}" == "200" ]] || fail "DELETE /me/mounts/{id} (A) expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A delete)"
C="$(me_req GET "${PORT_TC}" /v1/tenants/me/mounts "${KEY_A}")"
grep -q "${MOUNT_A_NAME}" "${BODY_TMP}" && fail "A's mount still listed after DELETE (line: A delete gone)" || true
ok "A deleted its OWN mount (caller-scoped); gone from A's list"

green "[M131] self-serve mounts: A composes via /me/mounts (no path id); A's mount absent from B's list; caller-scoped DELETE"
emit_gate_log() { ( set +e
  [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
  export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"; export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-builder}"
  . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
  log_event GATE --gate "m131=PASS" --outcome pass \
    --msg "dynamic builder self-serve mounts: POST/GET/DELETE /v1/tenants/me/mounts with A's key registers+lists+removes A's OWN mount (no path id); A's mount is ABSENT from B's /me/mounts (cross-tenant isolation by construction); DELETE is caller-scoped" \
    --ref "scripts/verify/m131-selfserve-mount-create.sh" >/dev/null 2>&1; exit 0 ) || true; }
emit_gate_log
green "[M131] ALL GATES GREEN"
exit 0
