#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m132-ceiling-enforce.sh                            :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M132 — DYNAMIC BUILDER ceiling = PRIVILEGE BOUNDARY, enforced at BOTH points:
#
#   (A · COMPOSE-time) tenant on `basic` (aggregate OFF in the tier). PATCH
#       /v1/tenants/me/entitlements {capabilities:{aggregate:true}} → 403
#       entitlement_exceeds_ceiling. A tenant can NEVER grant itself a capability
#       above its plan. (basic has aggregate OFF; turning it ON exceeds the
#       ceiling.)
#
#   (B · RESOLVE-time BACKSTOP) directly INSERT an OVER-CEILING entitlement row
#       (bypassing the compose gate, simulating a stale row written before a
#       downgrade): rps=400 + aggregate=true under a basic ceiling (rps=100,
#       aggregate OFF). Then GET /databases/{id}/connect → the STAMP carries the
#       CLAMPED (ceiling) values: rps=100, aggregate=false — NEVER the row's 400/
#       true. This is the load-bearing backstop: a too-high row is clamped on
#       EVERY resolve, never trusted.
#
# NON-VACUITY: arm A's 403 only happens if ValidateWithin runs at compose time;
# arm B's clamp only happens if Resolve clamps at /connect time. Without the
# builder both are impossible (PATCH /me/entitlements would 404; /connect would
# stamp basic verbatim, which COINCIDENTALLY equals the clamp for rps — so arm B
# inserts a row that, if TRUSTED, would stamp 400; the assertion that it stamps
# 100 proves the clamp, not the absence of a row).
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
step()  { cyan "[M132] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M132] FAIL — $*"; exit 1; }

PG_IMAGE="${M132_PG_IMAGE:-postgres:16-alpine}"
TC_IMG="m132-tc-$$:scratch"; AR_IMG="m132-ar-$$:scratch"
NET="m132net-$$"; PG="m132-pg-$$"; TC="m132-tc-$$"; AR="m132-ar-$$"
PORT_TC="${M132_PORT_TC:-18935}"; PORT_AR="${M132_PORT_AR:-18936}"
PGPW="postgres"; DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SVC_TOKEN="m132-internal-service-token-$$"
ENC_KEY="m132-enc-key-0123456789abcdef0123456789abcdef"
TENANT="m132-t-$$"; BODY_TMP="$(mktemp)"

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
ar_register() { curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST "http://127.0.0.1:${1}/databases" -H "X-Service-Token: ${SVC_TOKEN}" -H "X-Baas-Tenant-Id: ${2}" -H 'Content-Type: application/json' -d "${3}"; }
ar_connect()  { curl -s -o "${BODY_TMP}" -w '%{http_code}' "http://127.0.0.1:${1}/databases/${3}/connect" -H "X-Service-Token: ${SVC_TOKEN}" -H "X-Baas-Tenant-Id: ${2}"; }
co_num() { { grep -o "\"$1\":[0-9]*" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*://'; }
co_bool() { { grep -o "\"$1\":\(true\|false\)" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*://'; }
mount_id() { grep -o '"id":"[^"]*"' "${BODY_TMP}" | head -1 | cut -d'"' -f4; }
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

step "3/7 seed tenant on basic (aggregate OFF, rps=100) + an admin key"
admin_req POST "${PORT_TC}" /v1/tenants "{\"id\":\"${TENANT}\",\"name\":\"T\",\"plan\":\"basic\"}" >/dev/null
admin_req POST "${PORT_TC}" "/v1/tenants/${TENANT}/keys" "{\"name\":\"t-key-$$\",\"scopes\":[\"read\",\"write\",\"admin\"]}" >/dev/null
KEY="$(json_str key)"; [[ "${KEY}" == mbk_* ]] || fail "key not minted (line: key)"
ok "basic tenant + admin key"

# ── ARM A · COMPOSE-time gate ──────────────────────────────────────────────────
step "4/7 (A · COMPOSE) PATCH /me/entitlements {aggregate:true} on basic → 403 entitlement_exceeds_ceiling"
C="$(me_req PATCH "${PORT_TC}" /v1/tenants/me/entitlements "${KEY}" '{"capabilities":{"aggregate":true}}')"
[[ "${C}" == "403" ]] || fail "(A) PATCH aggregate:true on basic expected 403, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A 403)"
grep -q 'entitlement_exceeds_ceiling' "${BODY_TMP}" || fail "(A) 403 body missing entitlement_exceeds_ceiling — $(head -c 300 "${BODY_TMP}") (line: A code)"
# And NO row was written (the gate rejects before UPSERT).
[[ "$(psql_val "SELECT count(*) FROM public.tenant_entitlements WHERE tenant_id='${TENANT}'")" == "0" ]] \
  || fail "(A) an entitlement row was written despite the 403 — reject must precede UPSERT (line: A no row)"
ok "(A) compose-time gate: aggregate over basic's ceiling → 403, no row written"

# Sanity: a WITHIN-ceiling PATCH succeeds (proves the 403 is about exceeding, not a blanket block).
step "4b/7 (A · sanity) PATCH /me/entitlements {rps:50} (within basic 100) → 200"
C="$(me_req PATCH "${PORT_TC}" /v1/tenants/me/entitlements "${KEY}" '{"limits":{"rps":50}}')"
[[ "${C}" == "200" ]] || fail "(A) within-ceiling PATCH rps:50 expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A within)"
ok "(A) within-ceiling PATCH (rps:50 ≤ basic 100) → 200 = the 403 is about EXCEEDING, not a blanket block"

# ── ARM B · RESOLVE-time backstop ──────────────────────────────────────────────
step "5/7 (B · BACKSTOP) directly INSERT an OVER-CEILING row (rps=400, aggregate=true) under the basic ceiling"
psql_q >/dev/null 2>&1 <<SQL || fail "(B) direct INSERT failed (line: B insert)"
INSERT INTO public.tenant_entitlements (tenant_id, entitlement, status, updated_at)
VALUES ('${TENANT}', '{"limits":{"rps":400},"capabilities":{"aggregate":true}}'::jsonb, 'active', now())
ON CONFLICT (tenant_id) DO UPDATE SET entitlement = EXCLUDED.entitlement, status='active', updated_at=now();
SQL
[[ "$(psql_val "SELECT (entitlement->'limits'->>'rps') FROM public.tenant_entitlements WHERE tenant_id='${TENANT}'")" == "400" ]] \
  || fail "(B) over-ceiling row not stored (rps=400) (line: B row)"
ok "(B) stale over-ceiling row stored (rps=400, aggregate=true) — basic ceiling is rps=100, aggregate OFF"

step "6/7 (B · BACKSTOP) register a mount + GET /connect → STAMP is CLAMPED to the ceiling (rps=100, aggregate=false)"
ar_register "${PORT_AR}" "${TENANT}" '{"engine":"postgresql","name":"m1","connection_string":"postgres://u:p@h:5432/d","isolation":"shared_rls"}' >/dev/null
MID="$(mount_id)"; [[ -n "${MID}" ]] || fail "(B) mount not registered (line: B mount)"
C="$(ar_connect "${PORT_AR}" "${TENANT}" "${MID}")"
[[ "${C}" == "200" ]] || fail "(B) /connect expected 200, got ${C} — $(head -c 400 "${BODY_TMP}") (line: B connect)"
RPS="$(co_num rps)"; AGG="$(co_bool aggregate)"
[[ "${RPS}" == "100" ]] \
  || fail "(B) BACKSTOP FAILED: stamp rps=${RPS}, want 100 (clamped to basic ceiling) — the over-ceiling row (400) was TRUSTED! (line: B rps clamp)"
[[ "${AGG}" == "false" ]] \
  || fail "(B) BACKSTOP FAILED: stamp aggregate=${AGG}, want false (clamped to basic ceiling OFF) — capability widened past ceiling! (line: B aggregate clamp)"
ok "(B) RESOLVE-time backstop: stamp CLAMPED to rps=100, aggregate=false — the over-ceiling row is clamped on every resolve, never trusted"

step "7/7 summary"
green "[M132] (A) COMPOSE: PATCH /me/entitlements over the basic ceiling → 403 entitlement_exceeds_ceiling, no row"
green "[M132] (B) BACKSTOP: a directly-INSERTed over-ceiling row (rps=400, aggregate ON) is CLAMPED at /connect to rps=100, aggregate=false"
emit_gate_log() { ( set +e
  [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
  export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"; export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-builder}"
  . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
  log_event GATE --gate "m132=PASS" --outcome pass \
    --msg "dynamic builder ceiling = privilege boundary at BOTH points: PATCH /me/entitlements {aggregate:true} on basic → 403 entitlement_exceeds_ceiling (compose-time, no row); a directly-INSERTed over-ceiling row (rps=400, aggregate ON) is CLAMPED at /connect to rps=100, aggregate=false (resolve-time backstop, never trusted)" \
    --ref "scripts/verify/m132-ceiling-enforce.sh" >/dev/null 2>&1; exit 0 ) || true; }
emit_gate_log
green "[M132] ALL GATES GREEN — ceiling enforced at compose AND resolve time"
exit 0
