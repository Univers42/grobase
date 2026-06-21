#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m172-pubkeys.sh                                    :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/21 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/21 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M172 — member X25519 pubkey registry + grant-fulfilment seam (USER_PUBKEYS_ENABLED).
# The bridge between the control plane (WHO may access) and the vault42 ZK crypto
# plane (WHO CAN decrypt). tenant-control built FROM CURRENT source:
#
#   (A · POSITIVE) members register their PUBLIC keys (no private key stored) and
#       read each other's; a team grant on a project is "unfulfilled" until the
#       scope key is wrapped to EVERY member — fulfilled flips false -> partial ->
#       true as wraps are recorded.
#   (B · REJECTS) a non-member cannot register/read (404); a non-admin cannot
#       record a wrap (404 non-member); an unregistered user's pubkey 404.
#   (C · PARITY) USER_PUBKEYS_ENABLED unset -> every pubkey route 404, no rows.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"
GO_DIR="${INFRA_DIR}/src/control-plane"
MIG_DIR="${INFRA_DIR}/scripts/migrations/postgresql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
step() { cyan "[M172] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[M172] FAIL — $*"
  exit 1
}

PG_IMAGE="${M172_PG_IMAGE:-postgres:16-alpine}"
TC_IMG="m172-tc-$$:scratch"
NET="m172net-$$"
PG="m172-pg-$$"
TC_ON="m172-tc-on-$$"
TC_OFF="m172-tc-off-$$"
PORT_ON="${M172_PORT_ON:-19172}"
PORT_OFF="${M172_PORT_OFF:-19173}"
PGPW="postgres"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SVC_TOKEN="m172-internal-service-token-$$"
JWT_SECRET="m172-jwt-secret-deadbeefcafef00ddeadbeefcafef00d"
BODY_TMP="$(mktemp)"

U1="11111111-1111-1111-1111-111111111111" # org A owner (admin)
U2="22222222-2222-2222-2222-222222222222" # team member
U3="33333333-3333-3333-3333-333333333333" # team member
UOUT="44444444-4444-4444-4444-444444444444" # not a member

cleanup() {
  docker rm -fv "${TC_ON}" "${TC_OFF}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${TC_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" 2>/dev/null || true
}
trap cleanup EXIT

psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
apply_migration() { sed '/^#/d' "$1" | docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1; }

mint_jwt() {
  local sub="$1" email="$2"
  psql_val "
    WITH parts AS (
      SELECT
        translate(encode(convert_to('{\"alg\":\"HS256\",\"typ\":\"JWT\"}','utf8'),'base64'),'+/=' || chr(10) || chr(13),'-_') AS h,
        translate(encode(convert_to(
          '{\"sub\":\"${sub}\",\"email\":\"${email}\",\"role\":\"authenticated\",\"aud\":\"authenticated\",\"exp\":' ||
          (extract(epoch from now())::bigint + 3600)::text || '}','utf8'),'base64'),'+/=' || chr(10) || chr(13),'-_') AS p
    ),
    signed AS (
      SELECT h, p,
        translate(encode(hmac((h || '.' || p), '${JWT_SECRET}', 'sha256'),'base64'),'+/=' || chr(10) || chr(13),'-_') AS s
      FROM parts
    )
    SELECT rtrim(h,'=') || '.' || rtrim(p,'=') || '.' || rtrim(s,'=') FROM signed;"
}

req() {
  local m="$1" p="$2" path="$3" jwt="$4" body="${5:-}"
  if [[ -n "${body}" ]]; then
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "Authorization: Bearer ${jwt}" -H 'Content-Type: application/json' -d "${body}"
  else
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "Authorization: Bearer ${jwt}"
  fi
}
json_str() { { grep -o "\"$1\":\"[^\"]*\"" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*://; s/"//g'; }
body_has() { grep -q "$1" "${BODY_TMP}"; }

wait_ready_http() {
  local i
  for i in $(seq 1 60); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2$3" 2>/dev/null)" == "200" ]] && return 0
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -20; return 1; }
    sleep 0.5
  done
  red "$1 never became ready:"; docker logs "$1" 2>&1 | tail -20; return 1
}

# ── 1) postgres + migrations ──────────────────────────────────────────────────
step "1/5 boot postgres + migrations 005..073 + 077/078/079/081"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
for i in $(seq 1 60); do
  docker exec -i "${PG}" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 && break
  [[ $i -eq 60 ]] && fail "postgres never accepted TCP"
  sleep 0.5
done
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE IF NOT EXISTS public.schema_migrations (version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.current_user_id() RETURNS uuid LANGUAGE sql STABLE AS $fn$ SELECT NULLIF(current_setting('app.current_user_id', true), '')::uuid $fn$;
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS uuid LANGUAGE sql STABLE AS $fn$ SELECT COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'tenant_id', NULLIF(current_setting('app.current_tenant_id', true), ''), auth.current_user_id()::text)::uuid $fn$;
DO $r$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF; IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF; IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role; END IF; END $r$;
GRANT EXECUTE ON FUNCTION auth.current_user_id() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.current_tenant_id() TO anon, authenticated, service_role;
SQL
for m in 005_add_tenant_table 032_tenants 040_tenant_usage 043_orgs 044_org_billing_rollup 047_tenant_audit_log 072_teams 073_project_grants 077_environments 078_groups 079_project_grants_ext 081_user_pubkeys; do
  apply_migration "${MIG_DIR}/${m}.sql" || fail "migration ${m} failed to apply"
done
[[ "$(psql_val "SELECT count(*) FROM public.user_pubkeys")" == "0" ]] || fail "public.user_pubkeys should start EMPTY"
ok "migrations applied — user_pubkeys empty"

# ── 2) boot tenant-control USER_PUBKEYS_ENABLED=1 ─────────────────────────────
step "2/5 boot tenant-control USER_PUBKEYS_ENABLED=1 on 127.0.0.1:${PORT_ON}"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3020 -t "${TC_IMG}" "${GO_DIR}" >/dev/null || fail "image build failed"
docker run -d --name "${TC_ON}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" -e GOTRUE_JWT_SECRET="${JWT_SECRET}" \
  -e ORG_MODEL_ENABLED=1 -e RBAC_HIERARCHY_ENABLED=1 -e USER_PUBKEYS_ENABLED=1 \
  -e ADAPTER_REGISTRY_URL="" -e TENANT_CONTROL_PORT=3020 -e TENANT_CONTROL_PRODUCT_MODE=enabled -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_ON}:3020" "${TC_IMG}" >/dev/null
wait_ready_http "${TC_ON}" "${PORT_ON}" /health/live || fail "ON tenant-control not ready"
{ docker logs "${TC_ON}" 2>&1 || true; } | grep -q "user pubkeys enabled" || fail "pubkeys not enabled"
JWT_U1="$(mint_jwt "${U1}" u1@m172.test)"
JWT_U2="$(mint_jwt "${U2}" u2@m172.test)"
JWT_UOUT="$(mint_jwt "${UOUT}" uout@m172.test)"
ok "ON tenant-control up"

# ── 3) org A + team core (U2,U3) + project X + a team grant ───────────────────
step "3/5 org A + team core (U2,U3 members) + project X + team grant"
[[ "$(req POST "${PORT_ON}" /v1/orgs "${JWT_U1}" "{\"slug\":\"m172a$$\",\"name\":\"A\"}")" == "201" ]] || fail "create org A"
ORG_A="$(json_str id)"
psql_val "INSERT INTO public.org_members (org_id,user_id,role,invited_by) VALUES ('${ORG_A}'::uuid,'${U2}','developer','${U1}'),('${ORG_A}'::uuid,'${U3}','developer','${U1}') ON CONFLICT DO NOTHING" >/dev/null
[[ "$(req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/teams" "${JWT_U1}" '{"slug":"core","name":"Core"}')" == "201" ]] || fail "create team"
TEAM="$(json_str id)"
req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/teams/${TEAM}/members" "${JWT_U1}" "{\"user_id\":\"${U2}\"}" >/dev/null
req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/teams/${TEAM}/members" "${JWT_U1}" "{\"user_id\":\"${U3}\"}" >/dev/null
psql_val "INSERT INTO public.tenants (slug,name,plan,status,owner_user_id,org_id) VALUES ('m172x$$','X','free','active','${U1}','${ORG_A}'::uuid)" >/dev/null
PROJ_X="$(psql_val "SELECT id::text FROM public.tenants WHERE slug='m172x$$'")"
req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/projects/${PROJ_X}/grants" "${JWT_U1}" \
  "{\"grantee_kind\":\"team\",\"grantee_id\":\"${TEAM}\",\"project_role\":\"writer\"}" >/dev/null
GRANT_ID="$(psql_val "SELECT id::text FROM public.project_grants WHERE project_id::text='${PROJ_X}' AND grantee_kind='team' AND grantee_id='${TEAM}' AND revoked_at IS NULL")"
[[ -n "${GRANT_ID}" ]] || fail "team grant id"
ok "org A (${ORG_A}), team (${TEAM}) with U2/U3, project X, grant (${GRANT_ID})"

# ── 4) (A · POSITIVE) register pubkeys, read them, fulfilment false->partial->true
step "4/5 (A) register pubkeys + read + fulfilment false -> partial -> true"
[[ "$(req PUT "${PORT_ON}" "/v1/orgs/${ORG_A}/pubkey" "${JWT_U2}" '{"x25519_pub":"X25519U2","ed25519_pub":"ED25519U2","v42_address":"v42:u2addr","pubkey_sig":"sigU2"}')" == "200" ]] || fail "U2 register pubkey"
[[ "$(req PUT "${PORT_ON}" "/v1/orgs/${ORG_A}/pubkey" "${JWT_U1}" '{"x25519_pub":"X25519U1","ed25519_pub":"ED25519U1","v42_address":"v42:u1addr","pubkey_sig":"sigU1"}')" == "200" ]] || fail "U1 register pubkey"
req GET "${PORT_ON}" "/v1/orgs/${ORG_A}/users/${U2}/pubkey" "${JWT_U1}" >/dev/null
[[ "$(json_str x25519_pub)" == "X25519U2" ]] || fail "read U2 pubkey mismatch"
[[ "$(psql_val "SELECT count(*) FROM public.user_pubkeys WHERE x25519_pub LIKE 'X25519%'")" == "2" ]] || fail "pubkeys not stored"
# fulfilment: team grant covers U2+U3; no wraps yet -> not fulfilled, both missing.
req GET "${PORT_ON}" "/v1/orgs/${ORG_A}/projects/${PROJ_X}/grants/${GRANT_ID}/fulfilled" "${JWT_U1}" >/dev/null
body_has '"fulfilled":false' || fail "(A) expected unfulfilled before any wrap"
body_has "${U2}" && body_has "${U3}" || fail "(A) both members should be missing before wraps"
# record a wrap for U2 -> still not fulfilled (U3 missing).
[[ "$(req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/projects/${PROJ_X}/grants/${GRANT_ID}/wraps" "${JWT_U1}" "{\"user_id\":\"${U2}\"}")" == "201" ]] || fail "record wrap U2"
req GET "${PORT_ON}" "/v1/orgs/${ORG_A}/projects/${PROJ_X}/grants/${GRANT_ID}/fulfilled" "${JWT_U1}" >/dev/null
body_has '"fulfilled":false' || fail "(A) should still be unfulfilled with U3 missing"
body_has "${U3}" || fail "(A) U3 should still be missing"
# record a wrap for U3 -> fulfilled.
req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/projects/${PROJ_X}/grants/${GRANT_ID}/wraps" "${JWT_U1}" "{\"user_id\":\"${U3}\"}" >/dev/null
req GET "${PORT_ON}" "/v1/orgs/${ORG_A}/projects/${PROJ_X}/grants/${GRANT_ID}/fulfilled" "${JWT_U1}" >/dev/null
body_has '"fulfilled":true' || fail "(A) should be fulfilled after both wraps"
ok "(A) register/read pubkeys; fulfilment false -> partial -> true as wraps recorded"

# ── 5) (B · REJECTS) + (C · PARITY) ───────────────────────────────────────────
step "5/5 (B) non-member 404 · unregistered pubkey 404  ·  (C) flag OFF -> 404, no rows"
[[ "$(req PUT "${PORT_ON}" "/v1/orgs/${ORG_A}/pubkey" "${JWT_UOUT}" '{"x25519_pub":"X","v42_address":"v42:x","pubkey_sig":"s"}')" == "404" ]] || fail "(B) non-member could register a pubkey"
[[ "$(req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/projects/${PROJ_X}/grants/${GRANT_ID}/wraps" "${JWT_UOUT}" "{\"user_id\":\"${U2}\"}")" == "404" ]] || fail "(B) non-member could record a wrap"
[[ "$(req GET "${PORT_ON}" "/v1/orgs/${ORG_A}/users/${UOUT}/pubkey" "${JWT_U1}")" == "404" ]] || fail "(B) unregistered pubkey should 404"
PK_BEFORE="$(psql_val "SELECT count(*) FROM public.user_pubkeys")"
docker run -d --name "${TC_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" -e GOTRUE_JWT_SECRET="${JWT_SECRET}" \
  -e ORG_MODEL_ENABLED=1 -e RBAC_HIERARCHY_ENABLED=1 \
  -e TENANT_CONTROL_PORT=3020 -e TENANT_CONTROL_PRODUCT_MODE=enabled -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_OFF}:3020" "${TC_IMG}" >/dev/null
wait_ready_http "${TC_OFF}" "${PORT_OFF}" /health/live || fail "OFF tenant-control not ready"
{ docker logs "${TC_OFF}" 2>&1 || true; } | grep -q "user pubkeys disabled" || fail "(C) OFF did not report pubkeys disabled"
[[ "$(req PUT "${PORT_OFF}" "/v1/orgs/${ORG_A}/pubkey" "${JWT_U1}" '{"x25519_pub":"Z","v42_address":"v42:z","pubkey_sig":"s"}')" == "404" ]] || fail "(C) pubkey route with flag OFF expected 404"
[[ "$(psql_val "SELECT count(*) FROM public.user_pubkeys")" == "${PK_BEFORE}" ]] || fail "(C) OFF router wrote a pubkey row — not byte-parity"
ok "(B) non-member 404 · unregistered 404  ·  (C) flag OFF -> 404, no rows (byte-parity)"

green "[M172] (A) pubkey registry (public-only) + read; grant fulfilment false->partial->true"
green "[M172] (B) non-member register/wrap 404 · unregistered pubkey 404"
green "[M172] (C) flag OFF -> pubkey routes 404, no rows (byte-parity)"

emit_gate_log() {
  (
    set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-pubkeys}"
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m172=PASS" --outcome pass \
      --msg "pubkey registry + grant-fulfilment seam: members register public X25519 keys (no private key stored) + read co-members'; a team grant is unfulfilled until the scope key is wrapped to every member (false->partial->true); non-member register/wrap 404; unregistered pubkey 404; flag OFF -> 404 + no rows" \
      --ref "scripts/verify/m172-pubkeys.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
green "[M172] ALL GATES GREEN — pubkey registry + grant-fulfilment seam"
exit 0
