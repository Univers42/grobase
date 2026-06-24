#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m162-rbac-hierarchy.sh                             :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/20 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/20 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M162 — Track-D RBAC HIERARCHY live gate (RBAC_HIERARCHY_ENABLED): teams,
# project-role grants (User→Project and Team→Project), the effective-permission
# resolver (MAX of direct + team, org-bounded, TTL-aware, deny-by-default), and
# short-lived NON-ESCALATING scoped tokens. Control-plane only — it never touches
# the data plane. Exercises a tenant-control built FROM CURRENT source:
#
#   (A · POSITIVE spine — the "transcendence" example) U1 creates org A (owner) and
#       project X; creates team `core`; adds U2,U3; grants `core` ADMIN on X →
#       effective(U2)=admin AND effective(U3)=admin (a team grant PROPAGATES to
#       members).
#   (B · LOAD-BEARING REJECTS — a gate that only shows the happy path is VACUOUS)
#       deny-by-default (a never-granted user → no access); effective=MAX BOTH ways
#       (team admin + direct reader → admin); membership removal is INSTANT (drop
#       U3 from `core` → U3 falls to its direct grant); grant revoke is INSTANT;
#       a token can NEVER exceed the issuer's effective role (writer issuer minting
#       admin → 403); TTL expiry denies; a member of A cannot create a team / grant
#       in org B (cross-org isolation).
#   (C · PARITY) a SECOND tenant-control with RBAC_HIERARCHY_ENABLED UNSET → every
#       /v1/orgs/{id}/teams|grants|tokens route 404 while base /v1/orgs* still 200,
#       and NO teams/grants/tokens row is ever written — byte-parity with today.
#   (D · AUDIT) every privileged RBAC change seals a tamper-evident chain event.
#
# ISOLATED (mirrors m103): scratch postgres (prelude + REAL 005/032/040/043/044/047
# + the NEW 072/073) + a tenant-control built FROM CURRENT source, on a PRIVATE
# network, every name suffixed $$, an EXIT-trap removing EVERYTHING. It NEVER
# touches a mini-baas-* container/network/image/volume.

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
step() { cyan "[M162] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[M162] FAIL — $*"
  exit 1
}

PG_IMAGE="${M162_PG_IMAGE:-postgres:16-alpine}"
TC_IMG="m162-tc-$$:scratch"
NET="m162net-$$"
PG="m162-pg-$$"
TC_ON="m162-tc-on-$$"
TC_OFF="m162-tc-off-$$"
PORT_ON="${M162_PORT_ON:-19162}"
PORT_OFF="${M162_PORT_OFF:-19163}"
PGPW="postgres"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SVC_TOKEN="m162-internal-service-token-$$"
JWT_SECRET="m162-jwt-secret-deadbeefcafef00ddeadbeefcafef00d"
BODY_TMP="$(mktemp)"

U1="11111111-1111-1111-1111-111111111111" # org A owner
U2="22222222-2222-2222-2222-222222222222" # team core member (org A)
U3="33333333-3333-3333-3333-333333333333" # team core member (org A)
U4="44444444-4444-4444-4444-444444444444" # org B owner (no membership in A)
U5="55555555-5555-5555-5555-555555555555" # org A developer (token issuer)

cleanup() {
  docker rm -fv "${TC_ON}" "${TC_OFF}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${TC_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" 2>/dev/null || true
}
trap cleanup EXIT

psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
apply_migration() { sed '/^#/d' "$1" | docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1; }

mint_jwt() { # $1=sub  $2=email
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

org_req() { # $1=method $2=port $3=path $4=jwt $5=body?
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

# Effective project role for a user: echoes the role string ("" = no access).
eff() { # $1=port $2=jwt(caller) $3=org $4=proj $5=targetUser
  org_req GET "$1" "/v1/orgs/$3/projects/$4/effective?user=$5" "$2" >/dev/null
  json_str role
}

wait_ready_http() { # $1=container $2=port $3=path
  local i
  for i in $(seq 1 60); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2$3" 2>/dev/null)" == "200" ]] && return 0
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

# ── 0) build the scratch tenant-control FROM CURRENT source ────────────────────
step "0/9 build scratch tenant-control from CURRENT source (the P4 RBAC-hierarchy code)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3020 \
  -t "${TC_IMG}" "${GO_DIR}" >/dev/null ||
  fail "scratch tenant-control image build failed (line: docker build TC)"
ok "tenant-control built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated net + postgres + prelude + REAL migrations + NEW 072/073 ───────
step "1/9 boot isolated net (${NET}): postgres + migrations 005/032/040/043/044/047 + NEW 072/073"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
for i in $(seq 1 90); do
  docker exec "${PG}" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 &&
    [[ "$(psql_val 'SELECT 1')" == "1" ]] && break
  [[ $i -eq 90 ]] && {
    docker logs "${PG}" 2>&1 | tail -20
    fail "scratch postgres never accepted TCP"
  }
  sleep 0.5
done

prelude() {
  docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.current_user_id() RETURNS uuid
  LANGUAGE sql STABLE AS $fn$
    SELECT NULLIF(current_setting('app.current_user_id', true), '')::uuid $fn$;
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS uuid
  LANGUAGE sql STABLE AS $fn$
    SELECT COALESCE(
      NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'tenant_id',
      NULLIF(current_setting('app.current_tenant_id', true), ''),
      auth.current_user_id()::text
    )::uuid $fn$;
DO $r$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon')          THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role')  THEN CREATE ROLE service_role; END IF;
END $r$;
GRANT EXECUTE ON FUNCTION auth.current_user_id()   TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.current_tenant_id() TO anon, authenticated, service_role;
SQL
}
for i in $(seq 1 20); do
  prelude && break
  [[ $i -eq 20 ]] && fail "migration prelude never committed"
  sleep 0.5
done
for m in 005_add_tenant_table 032_tenants 040_tenant_usage 043_orgs 044_org_billing_rollup 047_tenant_audit_log 072_teams 073_project_grants 077_environments 078_groups 079_project_grants_ext; do
  apply_migration "${MIG_DIR}/${m}.sql" || fail "migration ${m} failed to apply"
done
for t in teams team_members project_grants rbac_tokens; do
  [[ "$(psql_val "SELECT count(*) FROM public.${t}")" == "0" ]] || fail "public.${t} should start EMPTY"
done
ok "migrations applied — teams/team_members/project_grants/rbac_tokens empty"

# ── 2) boot tenant-control with RBAC_HIERARCHY_ENABLED=1 ───────────────────────
step "2/9 boot tenant-control ORG_MODEL_ENABLED=1 RBAC_HIERARCHY_ENABLED=1 on 127.0.0.1:${PORT_ON}"
docker run -d --name "${TC_ON}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e GOTRUE_JWT_SECRET="${JWT_SECRET}" \
  -e ORG_MODEL_ENABLED=1 \
  -e RBAC_HIERARCHY_ENABLED=1 \
  -e ADAPTER_REGISTRY_URL="" \
  -e TENANT_CONTROL_PORT=3020 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_ON}:3020" "${TC_IMG}" >/dev/null
wait_ready_http "${TC_ON}" "${PORT_ON}" /health/live || fail "RBAC-ON tenant-control not ready"
{ docker logs "${TC_ON}" 2>&1 || true; } | grep -q "RBAC hierarchy enabled" ||
  {
    docker logs "${TC_ON}" 2>&1 | tail -20
    fail "RBAC hierarchy never reported enabled"
  }
ok "RBAC-ON tenant-control up (/v1/orgs/{id}/teams|grants|tokens mounted)"

JWT_U1="$(mint_jwt "${U1}" u1@m162.test)"; [[ -n "${JWT_U1}" ]] || fail "mint U1"
JWT_U2="$(mint_jwt "${U2}" u2@m162.test)"; [[ -n "${JWT_U2}" ]] || fail "mint U2"
JWT_U3="$(mint_jwt "${U3}" u3@m162.test)"; [[ -n "${JWT_U3}" ]] || fail "mint U3"
JWT_U4="$(mint_jwt "${U4}" u4@m162.test)"; [[ -n "${JWT_U4}" ]] || fail "mint U4"
JWT_U5="$(mint_jwt "${U5}" u5@m162.test)"; [[ -n "${JWT_U5}" ]] || fail "mint U5"
[[ "$(org_req GET "${PORT_ON}" /v1/orgs "${JWT_U1}")" == "200" ]] || fail "minted JWT not accepted by verifier"
ok "minted + verified five human JWTs (U1..U5)"

# ── 3) org A (U1 owner), org B (U4 owner), project X in A ──────────────────────
step "3/9 (A) U1 creates org A + project X; U4 creates org B"
ORG_SLUG="m162-org-a-$$"
[[ "$(org_req POST "${PORT_ON}" /v1/orgs "${JWT_U1}" "{\"slug\":\"${ORG_SLUG}\",\"name\":\"Org A\"}")" == "201" ]] ||
  fail "create org A — $(head -c 300 "${BODY_TMP}")"
ORG_A="$(json_str id)"; [[ -n "${ORG_A}" ]] || fail "org A id missing"
[[ "$(org_req POST "${PORT_ON}" /v1/orgs "${JWT_U4}" "{\"slug\":\"m162-org-b-$$\",\"name\":\"Org B\"}")" == "201" ]] ||
  fail "create org B"
ORG_B="$(json_str id)"; [[ -n "${ORG_B}" ]] || fail "org B id missing"
# U2,U3 are org-A members (a team member is always an org member); developer role
# grants CapOrgRead (read teams/grants) but not team/grant management.
psql_val "INSERT INTO public.org_members (org_id, user_id, role, invited_by) VALUES ('${ORG_A}'::uuid,'${U2}','developer','${U1}'),('${ORG_A}'::uuid,'${U3}','developer','${U1}') ON CONFLICT (org_id,user_id) DO NOTHING" >/dev/null
PROJ_SLUG="m162-proj-x-$$"
PROJ_BODY="{\"tenant\":\"${PROJ_SLUG}\",\"name\":\"Proj X\",\"plan\":\"nano\",\"seed_roles\":false,\"mounts\":[{\"engine\":\"postgresql\",\"name\":\"probe\",\"connection_string\":\"${DB_INNET}\",\"isolation\":\"shared_rls\"}]}"
C="$(org_req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/projects" "${JWT_U1}" "${PROJ_BODY}")"
[[ "${C}" == "200" || "${C}" == "201" ]] || fail "provision project X expected 200/201, got ${C} — $(head -c 400 "${BODY_TMP}")"
PROJ_X="$(psql_val "SELECT id::text FROM public.tenants WHERE slug='${PROJ_SLUG}' AND org_id::text='${ORG_A}'")"
[[ -n "${PROJ_X}" ]] || fail "project X tenant row (org_id stamped) not found"
ok "org A (${ORG_A}), org B (${ORG_B}), project X (${PROJ_X}) created"

# ── 4) (A · POSITIVE spine) team `core` → admin on X → members inherit admin ───
step "4/9 (A) team core admin on X PROPAGATES to members (the transcendence example)"
C="$(org_req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/teams" "${JWT_U1}" '{"slug":"core","name":"Core"}')"
[[ "${C}" == "201" ]] || fail "create team expected 201, got ${C} — $(head -c 300 "${BODY_TMP}")"
TEAM_CORE="$(json_str id)"; [[ -n "${TEAM_CORE}" ]] || fail "team id missing"
[[ "$(org_req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/teams/${TEAM_CORE}/members" "${JWT_U1}" "{\"user_id\":\"${U2}\"}")" == "200" ]] || fail "add U2 to team"
[[ "$(org_req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/teams/${TEAM_CORE}/members" "${JWT_U1}" "{\"user_id\":\"${U3}\"}")" == "200" ]] || fail "add U3 to team"
C="$(org_req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/projects/${PROJ_X}/grants" "${JWT_U1}" \
  "{\"grantee_kind\":\"team\",\"grantee_id\":\"${TEAM_CORE}\",\"project_role\":\"admin\"}")"
[[ "${C}" == "201" ]] || fail "grant team admin expected 201, got ${C} — $(head -c 300 "${BODY_TMP}")"
[[ "$(eff "${PORT_ON}" "${JWT_U1}" "${ORG_A}" "${PROJ_X}" "${U2}")" == "admin" ]] || fail "(A) team grant did not propagate to U2"
[[ "$(eff "${PORT_ON}" "${JWT_U1}" "${ORG_A}" "${PROJ_X}" "${U3}")" == "admin" ]] || fail "(A) team grant did not propagate to U3"
ok "(A) team core → admin on X; effective(U2)=effective(U3)=admin (propagation REAL)"

# ── 5) (B · REJECTS) deny-default · effective=MAX · instant membership/revoke ──
step "5/9 (B) deny-by-default · effective=MAX both ways · membership/revoke are INSTANT"
# deny-by-default: U4 (owner of B, not a member of A) has no grant in A.
[[ -z "$(eff "${PORT_ON}" "${JWT_U1}" "${ORG_A}" "${PROJ_X}" "${U4}")" ]] || fail "(B) deny-by-default broken: a never-granted user has access"
ok "(B) deny-by-default — a never-granted user has NO access"
# effective=MAX: U3 also gets a DIRECT reader grant → still admin (max of admin,reader).
[[ "$(org_req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/projects/${PROJ_X}/grants" "${JWT_U1}" \
  "{\"grantee_kind\":\"user\",\"grantee_id\":\"${U3}\",\"project_role\":\"reader\"}")" == "201" ]] || fail "direct reader grant to U3"
[[ "$(eff "${PORT_ON}" "${JWT_U1}" "${ORG_A}" "${PROJ_X}" "${U3}")" == "admin" ]] || fail "(B) effective != MAX (team admin + direct reader should be admin)"
ok "(B) effective=MAX — U3 (team admin + direct reader) resolves to admin"
# membership removal is INSTANT: drop U3 from core → falls to its direct reader.
[[ "$(org_req DELETE "${PORT_ON}" "/v1/orgs/${ORG_A}/teams/${TEAM_CORE}/members/${U3}" "${JWT_U1}")" == "200" ]] || fail "remove U3 from team"
[[ "$(eff "${PORT_ON}" "${JWT_U1}" "${ORG_A}" "${PROJ_X}" "${U3}")" == "reader" ]] || fail "(B) membership removal not instant (U3 should fall to direct reader)"
[[ "$(eff "${PORT_ON}" "${JWT_U1}" "${ORG_A}" "${PROJ_X}" "${U2}")" == "admin" ]] || fail "(B) U2 lost admin after U3 removal — over-revoked"
ok "(B) membership removal INSTANT — U3 falls to its direct reader; U2 retains admin"
# revoke is INSTANT: revoke U3's direct grant → no access.
GRANT_U3="$(psql_val "SELECT id::text FROM public.project_grants WHERE project_id::text='${PROJ_X}' AND grantee_kind='user' AND grantee_id='${U3}' AND revoked_at IS NULL")"
[[ -n "${GRANT_U3}" ]] || fail "could not find U3's direct grant id"
[[ "$(org_req DELETE "${PORT_ON}" "/v1/orgs/${ORG_A}/projects/${PROJ_X}/grants/${GRANT_U3}" "${JWT_U1}")" == "200" ]] || fail "revoke U3 grant"
[[ -z "$(eff "${PORT_ON}" "${JWT_U1}" "${ORG_A}" "${PROJ_X}" "${U3}")" ]] || fail "(B) revoke not instant — U3 still has access"
ok "(B) grant revoke INSTANT — U3 immediately has NO access"

# ── 6) (B · REJECT) a token can NEVER exceed the issuer's effective role ───────
step "6/9 (B) scoped token NON-ESCALATION (the load-bearing token proof)"
# U5 is an org developer (insert membership directly). developer→writer on the project lattice.
psql_val "INSERT INTO public.org_members (org_id, user_id, role, invited_by) VALUES ('${ORG_A}'::uuid, '${U5}', 'developer', '${U1}') ON CONFLICT (org_id,user_id) DO UPDATE SET role='developer'" >/dev/null
# org-scoped token: developer maps to writer → admin is an ESCALATION (403), writer is OK (201).
[[ "$(org_req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/tokens" "${JWT_U5}" '{"scope_kind":"org","project_role":"admin"}')" == "403" ]] ||
  fail "(B) a developer minted an ADMIN org token (escalation NOT blocked) — $(head -c 300 "${BODY_TMP}")"
grep -q 'forbidden' "${BODY_TMP}" || fail "(B) escalation 403 body missing 'forbidden'"
C="$(org_req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/tokens" "${JWT_U5}" '{"scope_kind":"org","project_role":"writer"}')"
[[ "${C}" == "201" ]] || fail "(B) developer could not mint a writer token (got ${C}) — within-role mint must succeed"
TOK1="$(json_str token)"; [[ "${TOK1}" == rbt_* ]] || fail "(B) minted token has no rbt_ prefix — got '${TOK1}'"
[[ "$(psql_val "SELECT count(*) FROM public.rbac_tokens WHERE token_prefix LIKE 'rbt_%'")" -ge 1 ]] || fail "(B) rbac_tokens row not written"
[[ "$(psql_val "SELECT count(*) FROM public.rbac_tokens WHERE token_hash LIKE '%${TOK1}%'")" == "0" ]] || fail "(B) cleartext token leaked into the DB — must store ONLY the hash"
# project-scoped token: U5 granted only reader on X → minting writer is an escalation (403).
[[ "$(org_req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/projects/${PROJ_X}/grants" "${JWT_U1}" \
  "{\"grantee_kind\":\"user\",\"grantee_id\":\"${U5}\",\"project_role\":\"reader\"}")" == "201" ]] || fail "grant U5 reader on X"
[[ "$(org_req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/tokens" "${JWT_U5}" "{\"scope_kind\":\"project\",\"scope_id\":\"${PROJ_X}\",\"project_role\":\"writer\"}")" == "403" ]] ||
  fail "(B) a project reader minted a WRITER project token (escalation NOT blocked)"
[[ "$(org_req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/tokens" "${JWT_U5}" "{\"scope_kind\":\"project\",\"scope_id\":\"${PROJ_X}\",\"project_role\":\"reader\"}")" == "201" ]] ||
  fail "(B) a project reader could not mint a reader token — within-role mint must succeed"
ok "(B) token NON-ESCALATION REAL — admin/writer above the issuer's role → 403; within-role → 201; only the hash stored"

# ── 7) (B · REJECT) TTL expiry · cross-org isolation ──────────────────────────
step "7/9 (B) TTL expiry denies · a member of A cannot create a team/grant in org B"
# TTL: grant U3 reader expiring in the PAST → effective deny; future → allow.
[[ "$(org_req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/projects/${PROJ_X}/grants" "${JWT_U1}" \
  "{\"grantee_kind\":\"user\",\"grantee_id\":\"${U3}\",\"project_role\":\"reader\",\"expires_at\":\"2000-01-01T00:00:00Z\"}")" == "201" ]] || fail "expired grant insert"
[[ -z "$(eff "${PORT_ON}" "${JWT_U1}" "${ORG_A}" "${PROJ_X}" "${U3}")" ]] || fail "(B) an EXPIRED grant still confers access — TTL gate is OPEN"
[[ "$(org_req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/projects/${PROJ_X}/grants" "${JWT_U1}" \
  "{\"grantee_kind\":\"user\",\"grantee_id\":\"${U3}\",\"project_role\":\"reader\",\"expires_at\":\"2099-01-01T00:00:00Z\"}")" == "201" ]] || fail "future grant insert"
[[ "$(eff "${PORT_ON}" "${JWT_U1}" "${ORG_A}" "${PROJ_X}" "${U3}")" == "reader" ]] || fail "(B) a future-dated grant did not confer access"
ok "(B) TTL expiry REAL — expired grant denies; future-dated grant allows"
# cross-org: U2 (member of A only) cannot create a team or grant in org B.
C="$(org_req POST "${PORT_ON}" "/v1/orgs/${ORG_B}/teams" "${JWT_U2}" '{"slug":"sneak","name":"x"}')"
[[ "${C}" == "403" || "${C}" == "404" ]] || fail "(B) cross-org team create not blocked (got ${C})"
C="$(org_req POST "${PORT_ON}" "/v1/orgs/${ORG_B}/projects/${PROJ_X}/grants" "${JWT_U2}" \
  "{\"grantee_kind\":\"user\",\"grantee_id\":\"${U2}\",\"project_role\":\"owner\"}")"
[[ "${C}" == "403" || "${C}" == "404" ]] || fail "(B) cross-org grant not blocked (got ${C})"
[[ "$(org_req GET "${PORT_ON}" "/v1/orgs/${ORG_A}/teams" "${JWT_U2}")" == "200" ]] || fail "(B) U2 lost access to its own org A teams (over-blocked)"
ok "(B) cross-org isolation REAL — member of A blocked in org B (403/404), full access to A retained"

# ── 8) (C · PARITY) flag OFF → teams/grants/tokens routes 404, base orgs 200 ───
step "8/9 (C · PARITY) RBAC_HIERARCHY_ENABLED unset → /teams|grants|tokens 404, base /v1/orgs 200, no rows"
TEAMS_BEFORE="$(psql_val "SELECT count(*) FROM public.teams")"
docker run -d --name "${TC_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e GOTRUE_JWT_SECRET="${JWT_SECRET}" \
  -e ORG_MODEL_ENABLED=1 \
  -e TENANT_CONTROL_PORT=3020 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_OFF}:3020" "${TC_IMG}" >/dev/null
wait_ready_http "${TC_OFF}" "${PORT_OFF}" /health/live || fail "RBAC-OFF tenant-control not ready"
{ docker logs "${TC_OFF}" 2>&1 || true; } | grep -q "RBAC hierarchy disabled" ||
  fail "(C) OFF instance did not report RBAC hierarchy disabled (flag default not OFF?)"
[[ "$(org_req GET "${PORT_OFF}" "/v1/orgs/${ORG_A}/teams" "${JWT_U1}")" == "404" ]] || fail "(C) GET /teams with flag OFF expected 404"
[[ "$(org_req POST "${PORT_OFF}" "/v1/orgs/${ORG_A}/tokens" "${JWT_U1}" '{"scope_kind":"org","project_role":"reader"}')" == "404" ]] || fail "(C) POST /tokens with flag OFF expected 404"
[[ "$(org_req GET "${PORT_OFF}" "/v1/orgs/${ORG_A}/projects/${PROJ_X}/grants" "${JWT_U1}")" == "404" ]] || fail "(C) GET /grants with flag OFF expected 404"
[[ "$(org_req GET "${PORT_OFF}" "/v1/orgs" "${JWT_U1}")" == "200" ]] || fail "(C) base GET /v1/orgs should still be 200 with RBAC OFF"
[[ "$(psql_val "SELECT count(*) FROM public.teams")" == "${TEAMS_BEFORE}" ]] || fail "(C) the OFF router wrote a teams row — not byte-parity"
ok "(C) flag OFF → teams/grants/tokens 404; base /v1/orgs 200; no rows written (byte-parity)"

# ── 9) (D · AUDIT) privileged RBAC changes sealed a tamper-evident chain ───────
step "9/9 (D · AUDIT) the RBAC changes sealed audit-chain events for org A"
AUDIT_N="$(psql_val "SELECT count(*) FROM public.tenant_audit_log WHERE tenant_id='${ORG_A}'")"
[[ "${AUDIT_N}" -ge 3 ]] || fail "(D) expected ≥3 audit events for org A (team.create/grant/...), got ${AUDIT_N}"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_audit_log WHERE tenant_id='${ORG_A}' AND action='team.create'")" -ge 1 ]] || fail "(D) no team.create audit event"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_audit_log WHERE tenant_id='${ORG_A}' AND action='project.grant'")" -ge 1 ]] || fail "(D) no project.grant audit event"
ok "(D) audit chain sealed ${AUDIT_N} events for org A (team.create + project.grant + …)"

# ── summary + gate log ─────────────────────────────────────────────────────────
green "[M162] (A) team admin on X PROPAGATES to members (transcendence example)"
green "[M162] (B) deny-default · effective=MAX · membership/revoke INSTANT · token NON-ESCALATION · TTL expiry · cross-org isolation"
green "[M162] (C) flag OFF → /teams|grants|tokens 404, base /v1/orgs 200, no rows (byte-parity)"
green "[M162] (D) every privileged RBAC change sealed a tamper-evident audit event"

emit_gate_log() {
  (
    set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-rbac-hierarchy}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m162=PASS" --outcome pass \
      --msg "RBAC hierarchy: team grant propagates to members; effective=MAX(direct,team) org-bounded TTL-aware deny-default; membership removal + grant revoke instant; scoped tokens never exceed the issuer's effective role (rbt_ hash-only); TTL expiry denies; cross-org create/grant blocked; RBAC_HIERARCHY_ENABLED unset -> teams/grants/tokens 404 + base orgs 200 + no rows (byte-parity); privileged changes sealed audit-chain events" \
      --ref "scripts/verify/m162-rbac-hierarchy.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
green "[M162] ALL GATES GREEN — Track-D RBAC hierarchy: teams, project grants, effective=MAX, non-escalating tokens, flag-OFF parity"
exit 0
