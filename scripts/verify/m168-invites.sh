#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m168-invites.sh                                    :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/21 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/21 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M168 — generalized team + group invitations (INVITES_ENABLED). Control-plane
# only; tenant-control built FROM CURRENT source:
#
#   (A · POSITIVE) U1 (org A owner) issues a TEAM invite (role member) -> a
#       cleartext mbi_ token returned ONCE; the pending invite is listable; U2
#       (registered) accepts -> joins the team AND becomes an org member. U1
#       issues a GROUP invite; U3 accepts -> joins the group.
#   (B · LOAD-BEARING REJECTS) single-use (re-accept the same token -> 409);
#       invalid token -> 401; expired invite -> 410; a duplicate pending invite
#       for the same (scope,email) -> 409; only the sha256 hash is stored (the
#       cleartext token never lands in the DB); a non-member cannot issue (404).
#   (C · PARITY) INVITES_ENABLED unset -> every invite route 404 while base
#       /v1/orgs/{id}/teams still 200, and NO invites row is written.
#
# ISOLATED (mirrors m166): scratch postgres (prelude + REAL 005..073 + 077/078/
# 079/080) + a tenant-control built FROM CURRENT source, PRIVATE net, $$-suffixed
# names, EXIT-trap cleanup.

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
step() { cyan "[M168] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[M168] FAIL — $*"
  exit 1
}

PG_IMAGE="${M168_PG_IMAGE:-postgres:16-alpine}"
TC_IMG="m168-tc-$$:scratch"
NET="m168net-$$"
PG="m168-pg-$$"
TC_ON="m168-tc-on-$$"
TC_OFF="m168-tc-off-$$"
PORT_ON="${M168_PORT_ON:-19168}"
PORT_OFF="${M168_PORT_OFF:-19169}"
PGPW="postgres"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SVC_TOKEN="m168-internal-service-token-$$"
JWT_SECRET="m168-jwt-secret-deadbeefcafef00ddeadbeefcafef00d"
BODY_TMP="$(mktemp)"

U1="11111111-1111-1111-1111-111111111111" # org A owner
U2="22222222-2222-2222-2222-222222222222" # accepts the team invite
U3="33333333-3333-3333-3333-333333333333" # accepts the group invite
UOUT="44444444-4444-4444-4444-444444444444" # not a member of org A

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
step "1/6 boot isolated net (${NET}): postgres + migrations 005..073 + 077/078/079/080"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
for i in $(seq 1 60); do
  docker exec -i "${PG}" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 && break
  [[ $i -eq 60 ]] && fail "postgres never accepted TCP connections"
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
for m in 005_add_tenant_table 032_tenants 040_tenant_usage 043_orgs 044_org_billing_rollup 047_tenant_audit_log 072_teams 073_project_grants 077_environments 078_groups 079_project_grants_ext 080_invites; do
  apply_migration "${MIG_DIR}/${m}.sql" || fail "migration ${m} failed to apply"
done
[[ "$(psql_val "SELECT count(*) FROM public.invites")" == "0" ]] || fail "public.invites should start EMPTY"
ok "migrations applied — invites empty"

# ── 2) boot tenant-control with INVITES_ENABLED=1 ─────────────────────────────
step "2/6 boot tenant-control INVITES_ENABLED=1 GROUPS_ENABLED=1 on 127.0.0.1:${PORT_ON}"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3020 \
  -t "${TC_IMG}" "${GO_DIR}" >/dev/null || fail "tenant-control image build failed"
docker run -d --name "${TC_ON}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" -e GOTRUE_JWT_SECRET="${JWT_SECRET}" \
  -e ORG_MODEL_ENABLED=1 -e RBAC_HIERARCHY_ENABLED=1 -e GROUPS_ENABLED=1 -e INVITES_ENABLED=1 \
  -e ADAPTER_REGISTRY_URL="" -e TENANT_CONTROL_PORT=3020 -e TENANT_CONTROL_PRODUCT_MODE=enabled -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_ON}:3020" "${TC_IMG}" >/dev/null
wait_ready_http "${TC_ON}" "${PORT_ON}" /health/live || fail "ON tenant-control not ready"
{ docker logs "${TC_ON}" 2>&1 || true; } | grep -q "invites enabled" || fail "invites never reported enabled"
ok "ON tenant-control up (invites mounted)"

JWT_U1="$(mint_jwt "${U1}" u1@m168.test)"
JWT_U2="$(mint_jwt "${U2}" u2@m168.test)"
JWT_U3="$(mint_jwt "${U3}" u3@m168.test)"
JWT_UOUT="$(mint_jwt "${UOUT}" uout@m168.test)"
[[ "$(req GET "${PORT_ON}" /v1/orgs "${JWT_U1}")" == "200" ]] || fail "minted JWT not accepted"

# ── 3) org A + team core + group ──────────────────────────────────────────────
step "3/6 (A) org A (U1 owner) + team core + project X + its group"
[[ "$(req POST "${PORT_ON}" /v1/orgs "${JWT_U1}" "{\"slug\":\"m168-a-$$\",\"name\":\"Org A\"}")" == "201" ]] || fail "create org A"
ORG_A="$(json_str id)"; [[ -n "${ORG_A}" ]] || fail "org A id"
[[ "$(req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/teams" "${JWT_U1}" '{"slug":"core","name":"Core"}')" == "201" ]] || fail "create team core"
TEAM_CORE="$(json_str id)"; [[ -n "${TEAM_CORE}" ]] || fail "team id"
PROJ_SLUG="m168-x-$$"
PROJ_BODY="{\"tenant\":\"${PROJ_SLUG}\",\"name\":\"Proj X\",\"plan\":\"nano\",\"seed_roles\":false,\"mounts\":[{\"engine\":\"postgresql\",\"name\":\"probe\",\"connection_string\":\"${DB_INNET}\",\"isolation\":\"shared_rls\"}]}"
C="$(req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/projects" "${JWT_U1}" "${PROJ_BODY}")"
[[ "${C}" == "200" || "${C}" == "201" ]] || fail "provision project X got ${C}"
PROJ_X="$(psql_val "SELECT id::text FROM public.tenants WHERE slug='${PROJ_SLUG}'")"
[[ "$(req POST "${PORT_ON}" "/v1/projects/${PROJ_X}/groups" "${JWT_U1}")" == "201" ]] || fail "create group"
GROUP_ID="$(json_str id)"; [[ -n "${GROUP_ID}" ]] || fail "group id"
ok "org A (${ORG_A}), team core (${TEAM_CORE}), group (${GROUP_ID})"

# ── 4) (A · POSITIVE) issue + accept a team invite, then a group invite ───────
step "4/6 (A) team invite -> U2 accepts (joins team + becomes org member); group invite -> U3"
C="$(req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/teams/${TEAM_CORE}/invites" "${JWT_U1}" '{"email":"u2@m168.test","role":"member"}')"
[[ "${C}" == "201" ]] || fail "issue team invite got ${C} — $(head -c 300 "${BODY_TMP}")"
TOK_TEAM="$(json_str token)"; [[ "${TOK_TEAM}" == mbi_* ]] || fail "team token missing mbi_ prefix — '${TOK_TEAM}'"
[[ "$(psql_val "SELECT count(*) FROM public.invites WHERE token_hash LIKE '%${TOK_TEAM}%'")" == "0" ]] || fail "cleartext token leaked into DB"
[[ "$(req GET "${PORT_ON}" "/v1/orgs/${ORG_A}/teams/${TEAM_CORE}/invites" "${JWT_U1}")" == "200" ]] || fail "list team invites"
grep -q '"status":"pending"' "${BODY_TMP}" || fail "pending team invite not listed"
[[ "$(req POST "${PORT_ON}" /v1/invites/accept "${JWT_U2}" "{\"token\":\"${TOK_TEAM}\"}")" == "200" ]] || fail "U2 accept team invite — $(head -c 300 "${BODY_TMP}")"
[[ "$(psql_val "SELECT count(*) FROM public.team_members WHERE team_id::text='${TEAM_CORE}' AND user_id='${U2}'")" == "1" ]] || fail "U2 not added to team on accept"
[[ "$(psql_val "SELECT count(*) FROM public.org_members WHERE org_id::text='${ORG_A}' AND user_id='${U2}'")" == "1" ]] || fail "U2 not added as org member on team accept"
C="$(req POST "${PORT_ON}" "/v1/groups/${GROUP_ID}/invites" "${JWT_U1}" '{"email":"u3@m168.test"}')"
[[ "${C}" == "201" ]] || fail "issue group invite got ${C}"
TOK_GROUP="$(json_str token)"; [[ "${TOK_GROUP}" == mbi_* ]] || fail "group token prefix"
[[ "$(req POST "${PORT_ON}" /v1/invites/accept "${JWT_U3}" "{\"token\":\"${TOK_GROUP}\"}")" == "200" ]] || fail "U3 accept group invite"
[[ "$(psql_val "SELECT count(*) FROM public.group_members WHERE group_id::text='${GROUP_ID}' AND user_id='${U3}'")" == "1" ]] || fail "U3 not added to group on accept"
ok "(A) team invite -> U2 in team + org; group invite -> U3 in group; token hash-only"

# ── 5) (B · REJECTS) single-use · invalid · expired · duplicate · non-member ──
step "5/6 (B) single-use 409 · invalid 401 · expired 410 · duplicate 409 · non-member 404"
[[ "$(req POST "${PORT_ON}" /v1/invites/accept "${JWT_U2}" "{\"token\":\"${TOK_TEAM}\"}")" == "409" ]] || fail "(B) re-accept (single-use) not 409"
[[ "$(req POST "${PORT_ON}" /v1/invites/accept "${JWT_U2}" '{"token":"mbi_bogus_does_not_exist"}')" == "401" ]] || fail "(B) invalid token not 401"
# expired: issue, age it in the past, accept -> 410.
req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/teams/${TEAM_CORE}/invites" "${JWT_U1}" '{"email":"u4@m168.test","role":"member"}' >/dev/null
TOK_EXP="$(json_str token)"
psql_val "UPDATE public.invites SET expires_at = now() - interval '1 day' WHERE email='u4@m168.test' AND status='pending'" >/dev/null
[[ "$(req POST "${PORT_ON}" /v1/invites/accept "${JWT_U3}" "{\"token\":\"${TOK_EXP}\"}")" == "410" ]] || fail "(B) expired invite not 410"
# duplicate pending for the same (scope,email) -> 409.
req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/teams/${TEAM_CORE}/invites" "${JWT_U1}" '{"email":"u5@m168.test","role":"member"}' >/dev/null
[[ "$(req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/teams/${TEAM_CORE}/invites" "${JWT_U1}" '{"email":"u5@m168.test","role":"member"}')" == "409" ]] || fail "(B) duplicate pending invite not 409"
# a non-member of org A cannot issue a team invite -> 404 (opaque).
[[ "$(req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/teams/${TEAM_CORE}/invites" "${JWT_UOUT}" '{"email":"x@m168.test","role":"member"}')" == "404" ]] || fail "(B) non-member could issue an invite"
ok "(B) single-use 409 · invalid 401 · expired 410 · duplicate 409 · non-member 404"

# ── 6) (C · PARITY) flag OFF -> invite routes 404, base /teams 200, no new rows ─
step "6/6 (C · PARITY) INVITES_ENABLED unset -> invite routes 404, base /teams 200, no rows"
INV_BEFORE="$(psql_val "SELECT count(*) FROM public.invites")"
docker run -d --name "${TC_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" -e GOTRUE_JWT_SECRET="${JWT_SECRET}" \
  -e ORG_MODEL_ENABLED=1 -e RBAC_HIERARCHY_ENABLED=1 -e GROUPS_ENABLED=1 \
  -e TENANT_CONTROL_PORT=3020 -e TENANT_CONTROL_PRODUCT_MODE=enabled -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_OFF}:3020" "${TC_IMG}" >/dev/null
wait_ready_http "${TC_OFF}" "${PORT_OFF}" /health/live || fail "OFF tenant-control not ready"
{ docker logs "${TC_OFF}" 2>&1 || true; } | grep -q "invites disabled" || fail "(C) OFF did not report invites disabled"
[[ "$(req POST "${PORT_OFF}" "/v1/orgs/${ORG_A}/teams/${TEAM_CORE}/invites" "${JWT_U1}" '{"email":"z@m168.test","role":"member"}')" == "404" ]] || fail "(C) team-invite route with flag OFF expected 404"
[[ "$(req POST "${PORT_OFF}" /v1/invites/accept "${JWT_U2}" '{"token":"mbi_x"}')" == "404" ]] || fail "(C) accept route with flag OFF expected 404"
[[ "$(req GET "${PORT_OFF}" "/v1/orgs/${ORG_A}/teams" "${JWT_U1}")" == "200" ]] || fail "(C) base /teams should still be 200"
[[ "$(psql_val "SELECT count(*) FROM public.invites")" == "${INV_BEFORE}" ]] || fail "(C) OFF router wrote an invites row — not byte-parity"
ok "(C) flag OFF -> invite routes 404; base /teams 200; no rows (byte-parity)"

green "[M168] (A) team + group invites issue/accept; team accept also grants org membership"
green "[M168] (B) single-use · invalid · expired · duplicate · non-member — all rejected; token hash-only"
green "[M168] (C) flag OFF -> invite routes 404, base /teams 200, no rows (byte-parity)"

emit_gate_log() {
  (
    set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-invites}"
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m168=PASS" --outcome pass \
      --msg "generalized team/group invites: issue returns hash-only token; registered accept joins scope (team accept also grants org membership); single-use 409, invalid 401, expired 410, duplicate 409, non-member 404; flag OFF -> 404 + no rows (byte-parity)" \
      --ref "scripts/verify/m168-invites.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
green "[M168] ALL GATES GREEN — generalized team + group invitations"
exit 0
