#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m170-standalone-invites.sh                         :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/21 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/21 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M170 — STANDALONE-project direct invitations (INVITES_ENABLED). A project with
# NO org may invite users DIRECTLY (the user's "project alone" rule); an org-bound
# project must invite via a team (409). tenant-control built FROM CURRENT source:
#
#   (A · POSITIVE) U1 owns a standalone project SP (org_id IS NULL). U1 invites
#       u2 directly to SP (role writer) -> U2 accepts -> a direct user->project
#       grant exists with org_id NULL + source 'invite'.
#   (B · REJECTS) an ORG-bound project rejects a direct project invite (409 "invite
#       via a team"); a NON-owner cannot invite to SP (403); a missing project 404.
#   (C · PARITY) INVITES_ENABLED unset -> /v1/projects/{id}/invites 404, no rows.

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
step() { cyan "[M170] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[M170] FAIL — $*"
  exit 1
}

PG_IMAGE="${M170_PG_IMAGE:-postgres:16-alpine}"
TC_IMG="m170-tc-$$:scratch"
NET="m170net-$$"
PG="m170-pg-$$"
TC_ON="m170-tc-on-$$"
TC_OFF="m170-tc-off-$$"
PORT_ON="${M170_PORT_ON:-19170}"
PORT_OFF="${M170_PORT_OFF:-19171}"
PGPW="postgres"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SVC_TOKEN="m170-internal-service-token-$$"
JWT_SECRET="m170-jwt-secret-deadbeefcafef00ddeadbeefcafef00d"
BODY_TMP="$(mktemp)"

U1="11111111-1111-1111-1111-111111111111"   # standalone project owner
U2="22222222-2222-2222-2222-222222222222"   # invited directly to the project
UOUT="44444444-4444-4444-4444-444444444444" # not the owner

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
step "1/5 boot postgres + migrations 005..073 + 077/078/079/080"
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
for m in 005_add_tenant_table 032_tenants 040_tenant_usage 043_orgs 044_org_billing_rollup 047_tenant_audit_log 072_teams 073_project_grants 077_environments 078_groups 079_project_grants_ext 080_invites; do
  apply_migration "${MIG_DIR}/${m}.sql" || fail "migration ${m} failed to apply"
done
# seed: org A, a standalone project SP (org_id NULL, owner U1), an org-bound project OP (org_id A).
psql_val "INSERT INTO public.orgs (slug,name) VALUES ('m170a$$','A')" >/dev/null
ORG_A="$(psql_val "SELECT id::text FROM public.orgs WHERE slug='m170a$$'")"
[[ -n "${ORG_A}" ]] || fail "seed org A"
psql_val "INSERT INTO public.tenants (slug,name,plan,status,owner_user_id,org_id) VALUES ('m170sp$$','SP','free','active','${U1}',NULL)" >/dev/null
SP="$(psql_val "SELECT id::text FROM public.tenants WHERE slug='m170sp$$'")"
psql_val "INSERT INTO public.tenants (slug,name,plan,status,owner_user_id,org_id) VALUES ('m170op$$','OP','free','active','${U1}','${ORG_A}'::uuid)" >/dev/null
OP="$(psql_val "SELECT id::text FROM public.tenants WHERE slug='m170op$$'")"
[[ -n "${SP}" && -n "${OP}" ]] || fail "seed projects (SP=${SP} OP=${OP})"
ok "seeded org A, standalone SP (${SP}, org_id NULL), org-bound OP (${OP})"

# ── 2) boot tenant-control INVITES_ENABLED=1 ──────────────────────────────────
step "2/5 boot tenant-control INVITES_ENABLED=1 on 127.0.0.1:${PORT_ON}"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3020 -t "${TC_IMG}" "${GO_DIR}" >/dev/null || fail "image build failed"
docker run -d --name "${TC_ON}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" -e GOTRUE_JWT_SECRET="${JWT_SECRET}" \
  -e ORG_MODEL_ENABLED=1 -e RBAC_HIERARCHY_ENABLED=1 -e INVITES_ENABLED=1 \
  -e ADAPTER_REGISTRY_URL="" -e TENANT_CONTROL_PORT=3020 -e TENANT_CONTROL_PRODUCT_MODE=enabled -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_ON}:3020" "${TC_IMG}" >/dev/null
wait_ready_http "${TC_ON}" "${PORT_ON}" /health/live || fail "ON tenant-control not ready"
{ docker logs "${TC_ON}" 2>&1 || true; } | grep -q "invites enabled" || fail "invites not enabled"
JWT_U1="$(mint_jwt "${U1}" u1@m170.test)"
JWT_U2="$(mint_jwt "${U2}" u2@m170.test)"
JWT_UOUT="$(mint_jwt "${UOUT}" uout@m170.test)"
ok "ON tenant-control up"

# ── 3) (A · POSITIVE) U1 invites U2 directly to the standalone project ────────
step "3/5 (A) owner invites U2 directly to standalone SP -> U2 accepts -> direct grant"
C="$(req POST "${PORT_ON}" "/v1/projects/${SP}/invites" "${JWT_U1}" '{"email":"u2@m170.test","role":"writer"}')"
[[ "${C}" == "201" ]] || fail "(A) standalone project invite got ${C} — $(head -c 300 "${BODY_TMP}")"
TOK="$(json_str token)"; [[ "${TOK}" == mbi_* ]] || fail "(A) token prefix"
[[ "$(req POST "${PORT_ON}" /v1/invites/accept "${JWT_U2}" "{\"token\":\"${TOK}\"}")" == "200" ]] || fail "(A) U2 accept"
GRANT_ROLE="$(psql_val "SELECT project_role FROM public.project_grants WHERE project_id::text='${SP}' AND grantee_kind='user' AND grantee_id='${U2}' AND org_id IS NULL AND source='invite' AND revoked_at IS NULL")"
[[ "${GRANT_ROLE}" == "writer" ]] || fail "(A) standalone grant not created (org_id NULL, source invite, writer) — got '${GRANT_ROLE}'"
ok "(A) direct standalone invite -> accept -> user→project grant (org_id NULL, source invite, writer)"

# ── 4) (B · REJECTS) org-bound 409 · non-owner 403 · missing 404 ──────────────
step "4/5 (B) org-bound project 409 (invite via a team) · non-owner 403 · missing 404"
C="$(req POST "${PORT_ON}" "/v1/projects/${OP}/invites" "${JWT_U1}" '{"email":"x@m170.test","role":"reader"}')"
[[ "${C}" == "409" ]] || fail "(B) org-bound project direct invite expected 409, got ${C}"
grep -q 'team' "${BODY_TMP}" || fail "(B) 409 body should mention inviting via a team"
[[ "$(req POST "${PORT_ON}" "/v1/projects/${SP}/invites" "${JWT_UOUT}" '{"email":"y@m170.test","role":"reader"}')" == "403" ]] || fail "(B) non-owner could invite to standalone project"
RANDP="$(psql_val "SELECT gen_random_uuid()::text")"
[[ "$(req POST "${PORT_ON}" "/v1/projects/${RANDP}/invites" "${JWT_U1}" '{"email":"z@m170.test","role":"reader"}')" == "404" ]] || fail "(B) missing project not 404"
ok "(B) org-bound 409 · non-owner 403 · missing 404"

# ── 5) (C · PARITY) flag OFF -> route 404, no rows ────────────────────────────
step "5/5 (C · PARITY) INVITES_ENABLED unset -> /v1/projects/{id}/invites 404, no rows"
INV_BEFORE="$(psql_val "SELECT count(*) FROM public.invites")"
docker run -d --name "${TC_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" -e GOTRUE_JWT_SECRET="${JWT_SECRET}" \
  -e ORG_MODEL_ENABLED=1 -e RBAC_HIERARCHY_ENABLED=1 \
  -e TENANT_CONTROL_PORT=3020 -e TENANT_CONTROL_PRODUCT_MODE=enabled -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_OFF}:3020" "${TC_IMG}" >/dev/null
wait_ready_http "${TC_OFF}" "${PORT_OFF}" /health/live || fail "OFF tenant-control not ready"
[[ "$(req POST "${PORT_OFF}" "/v1/projects/${SP}/invites" "${JWT_U1}" '{"email":"q@m170.test","role":"reader"}')" == "404" ]] || fail "(C) project-invite route with flag OFF expected 404"
[[ "$(psql_val "SELECT count(*) FROM public.invites")" == "${INV_BEFORE}" ]] || fail "(C) OFF router wrote an invites row — not byte-parity"
ok "(C) flag OFF -> route 404; no rows (byte-parity)"

green "[M170] (A) standalone project direct invite -> accept -> direct user→project grant"
green "[M170] (B) org-bound 409 (invite via a team) · non-owner 403 · missing 404"
green "[M170] (C) flag OFF -> route 404, no rows (byte-parity)"

emit_gate_log() {
  (
    set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-standalone-invites}"
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m170=PASS" --outcome pass \
      --msg "standalone-project direct invites: owner invites a user directly to an org-less project -> accept -> direct user->project grant (org_id NULL, source invite); org-bound project rejects direct invite (409 invite-via-a-team); non-owner 403; missing 404; flag OFF -> 404 + no rows" \
      --ref "scripts/verify/m170-standalone-invites.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
green "[M170] ALL GATES GREEN — standalone-project direct invitations + org-guard"
exit 0
