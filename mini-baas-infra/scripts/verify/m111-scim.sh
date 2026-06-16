#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m111-scim.sh                                       :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M111 — Track-D D2b SCIM 2.0 provisioning gate (RFC 7644). gotrue has NO SCIM
# support; D2b adds a server-side SCIM relying surface (/scim/v2/Users) driven by
# a BEARER token an enterprise IdP holds, flag-gated OFF by default (SCIM_ENABLED).
# SCIM provisions ORG MEMBERS — it REUSES internal/orgs membership (Add/Remove);
# active:false soft-deactivates (org_members.active=false), DELETE deprovisions.
# The bearer token binds a tenant_id (+org_id) — that binding IS the per-tenant
# wall: a T1 token can never read/modify a user provisioned under T2.
#
# It exercises a tenant-control binary built FROM CURRENT source (the EXACT D2b
# code) as a SCIM CLIENT (curl with a bearer token):
#
#   (A · POSITIVE) issue a SCIM token (admin/service-token) -> POST /scim/v2/Users
#       => 201; GET by id => 200; GET ?filter=userName eq "x" => 1 result; PATCH
#       active:false => the org member is DEACTIVATED (org_members.active=false);
#       DELETE => 204 and the member (and the SCIM mapping) is GONE.
#   (B · REJECT, LOAD-BEARING) a SCIM call with NO bearer => 401; with a
#       REVOKED/unknown bearer => 401; AND the cross-tenant wall: a token for T2
#       cannot GET/PATCH/DELETE a user provisioned under T1 (=> 404/401), and T1's
#       user is UNCHANGED. This proves the bearer->tenant binding is the wall.
#   (C · FLAG-OFF PARITY) with SCIM_ENABLED unset, EVERY /scim/v2/* route is 404
#       while admin GET /v1/tenants 200, and scim_tokens has 0 rows — byte-
#       identical to today (gotrue has no SCIM).
#
# ISOLATED by design (mirrors m107): scratch postgres (prelude + REAL 005/032/043/
# 054) + two tenant-control binaries built FROM CURRENT source, ALL on a PRIVATE
# network, every name suffixed with $$, an EXIT-trap removing EVERYTHING. It NEVER
# touches a mini-baas-* container/network/image/volume and NEVER edits
# docker-compose.yml.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                  # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                       # apps/baas
GO_DIR="${INFRA_DIR}/go/control-plane"
MIG_DIR="${INFRA_DIR}/scripts/migrations/postgresql"
MIGRATION_005="${MIG_DIR}/005_add_tenant_table.sql"
MIGRATION_032="${MIG_DIR}/032_tenants.sql"
MIGRATION_043="${MIG_DIR}/043_orgs.sql"
MIGRATION_054="${MIG_DIR}/054_scim_tokens.sql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M111] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M111] FAIL — $*"; exit 1; }

PG_IMAGE="${M111_PG_IMAGE:-postgres:16-alpine}"
TC_IMG="m111-tc-$$:scratch"
NET="m111net-$$"
PG="m111-pg-$$"
TC_ON="m111-tc-on-$$"      # SCIM_ENABLED=1     (A/B)
TC_OFF="m111-tc-off-$$"    # SCIM_ENABLED unset (C · flag-off parity)
# UNIQUE port pair for this gate (m107 uses 19110/19111).
PORT_ON="${M111_PORT_ON:-19122}"
PORT_OFF="${M111_PORT_OFF:-19123}"
PGPW="postgres"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SVC_TOKEN="m111-internal-service-token-$$"
# Two tenants + two orgs: the cross-tenant wall.
TENANT_1="m111-tenant-one-$$"
TENANT_2="m111-tenant-two-$$"
ORG_1="11111111-aaaa-1111-aaaa-111111111111"
ORG_2="22222222-bbbb-2222-bbbb-222222222222"
WORK="$(mktemp -d)"
BODY_TMP="${WORK}/body.json"

cleanup() {
  docker rm -fv "${TC_ON}" "${TC_OFF}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${TC_IMG}" >/dev/null 2>&1 || true
  rm -rf "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

# shellcheck disable=SC2120
psql_q()   { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

# Apply a migration the SAME way make migrate does: strip the leading `#` banner
# lines before piping to psql (the body uses `--` SQL comments psql tolerates).
apply_migration() { # $1=file
  sed '/^#/d' "$1" | docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1
}

# Service-token admin request. $1=method $2=port $3=path $4=body
admin_req() {
  local m="$1" p="$2" path="$3" body="${4:-}"
  if [[ -n "${body}" ]]; then
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "X-Service-Token: ${SVC_TOKEN}" -H 'Content-Type: application/json' -d "${body}"
  else
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "X-Service-Token: ${SVC_TOKEN}"
  fi
}

# SCIM bearer request. $1=method $2=port $3=path $4=bearer $5=body($6=skip-bearer flag)
scim_req() {
  local m="$1" p="$2" path="$3" bearer="$4" body="${5:-}"
  local args=(-s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}")
  if [[ "${bearer}" != "__NONE__" ]]; then
    args+=(-H "Authorization: Bearer ${bearer}")
  fi
  if [[ -n "${body}" ]]; then
    args+=(-H 'Content-Type: application/scim+json' -d "${body}")
  fi
  curl "${args[@]}"
}

# json_str: extract a top-level JSON string field off BODY_TMP. Tolerates 0 matches.
json_str() { { grep -o "\"$1\":\"[^\"]*\"" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*"'"$1"'":"//; s/"$//'; }

wait_ready() { # $1=container $2=port
  local i
  for i in $(seq 1 60); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2/health/live" 2>/dev/null)" == "200" ]] && return 0
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -20; return 1; }
    sleep 0.5
  done
  red "$1 never became ready:"; docker logs "$1" 2>&1 | tail -20; return 1
}

# ── 0) build tenant-control FROM CURRENT source ────────────────────────────────
step "0/12 build tenant-control FROM CURRENT source (the EXACT D2b SCIM code)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3070 \
  -t "${TC_IMG}" "${GO_DIR}" >/dev/null \
  || fail "scratch tenant-control image build failed — gate must exercise the drafted D2b code (line: docker build TC)"
ok "tenant-control built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated net + postgres (TCP-ready) ─────────────────────────────────────
step "1/12 boot isolated net (${NET}): postgres"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
for i in $(seq 1 80); do
  if docker exec "${PG}" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 \
     && [[ "$(psql_val 'SELECT 1')" == "1" ]]; then break; fi
  [[ $i -eq 80 ]] && { docker logs "${PG}" 2>&1 | tail -20; fail "scratch postgres never reached TCP-ready"; }
  sleep 0.5
done
ok "postgres up + TCP-ready (SELECT 1 ok)"

# ── 1b) prelude + REAL 005/032/043/054 ─────────────────────────────────────────
step "1b/12 prelude (schema_migrations, auth.current_tenant_id/user_id, roles) then REAL 005/032/043/054"
prelude() {
  psql_q >/dev/null 2>&1 <<'SQL'
CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS text
  LANGUAGE sql STABLE AS $fn$ SELECT current_setting('request.tenant_id', true) $fn$;
CREATE OR REPLACE FUNCTION auth.current_user_id() RETURNS text
  LANGUAGE sql STABLE AS $fn$ SELECT current_setting('request.user_id', true) $fn$;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
DO $r$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role')  THEN CREATE ROLE service_role;  END IF;
END $r$;
SQL
}
for i in $(seq 1 20); do prelude && break; [[ $i -eq 20 ]] && fail "migration prelude never committed (line: prelude loop)"; sleep 0.5; done
# tenant-control's boot schema-check requires public.tenants (005 + 032).
apply_migration "${MIGRATION_005}" || fail "real migration 005_add_tenant_table.sql failed to apply (line: apply 005)"
apply_migration "${MIGRATION_032}" || fail "real migration 032_tenants.sql failed to apply (line: apply 032)"
# 043 brings org_members (the deactivate assertion target) + org_id column.
[[ -f "${MIGRATION_043}" ]] || fail "migration 043_orgs.sql is MISSING — SCIM provisions org members (line: 043 exists)"
apply_migration "${MIGRATION_043}" || fail "real migration 043_orgs.sql failed to apply (line: apply 043)"
[[ -f "${MIGRATION_054}" ]] || fail "migration 054_scim_tokens.sql is MISSING — the D2b migration must land before m111 (line: 054 exists)"
apply_migration "${MIGRATION_054}" || fail "real migration 054_scim_tokens.sql failed to apply (line: apply 054)"
[[ "$(psql_val "SELECT to_regclass('public.scim_tokens') IS NOT NULL")" == "t" ]] \
  || fail "public.scim_tokens not created by migration 054 (line: 054 tokens table)"
[[ "$(psql_val "SELECT to_regclass('public.scim_users') IS NOT NULL")" == "t" ]] \
  || fail "public.scim_users not created by migration 054 (line: 054 users table)"
[[ "$(psql_val "SELECT count(*) FROM public.scim_tokens")" == "0" ]] \
  || fail "scim_tokens should start EMPTY (line: 054 empty check)"
# org_members.active column must exist (the soft-deactivate target).
[[ "$(psql_val "SELECT count(*) FROM information_schema.columns WHERE table_name='org_members' AND column_name='active'")" == "1" ]] \
  || fail "org_members.active column not added by migration 054 (line: 054 active column)"
# scim_tokens must be write-locked to authenticated (only service_role mints).
HASW="$(psql_val "SELECT count(*) FROM information_schema.role_table_grants WHERE table_name='scim_tokens' AND grantee='authenticated' AND privilege_type IN ('INSERT','UPDATE','DELETE')")" || HASW="?"
[[ "${HASW}" == "0" ]] || fail "authenticated must NOT have INSERT/UPDATE/DELETE on scim_tokens, got ${HASW} (line: 054 grants)"
ok "migrations applied — scim_tokens/scim_users exist + empty, org_members.active present, authenticated read-only on scim_tokens"

# Seed the two tenants + two orgs (the cross-tenant wall needs concrete orgs to
# provision into; ORG_MODEL routes need a JWT, so we seed orgs directly via SQL).
psql_q >/dev/null 2>&1 <<SQL || fail "could not seed tenants/orgs (line: seed)"
INSERT INTO public.tenants (slug, name) VALUES ('${TENANT_1}','M111 T1') ON CONFLICT DO NOTHING;
INSERT INTO public.tenants (slug, name) VALUES ('${TENANT_2}','M111 T2') ON CONFLICT DO NOTHING;
INSERT INTO public.orgs (id, slug, name) VALUES ('${ORG_1}','m111-org-one','M111 Org 1') ON CONFLICT DO NOTHING;
INSERT INTO public.orgs (id, slug, name) VALUES ('${ORG_2}','m111-org-two','M111 Org 2') ON CONFLICT DO NOTHING;
INSERT INTO public.org_members (org_id, user_id, role) VALUES ('${ORG_1}','m111-owner-1','owner') ON CONFLICT DO NOTHING;
INSERT INTO public.org_members (org_id, user_id, role) VALUES ('${ORG_2}','m111-owner-2','owner') ON CONFLICT DO NOTHING;
SQL
ok "seeded T1/T2 tenants + Org1/Org2 (each with a break-glass owner)"

# ── 2) boot the SCIM-ON tenant-control ─────────────────────────────────────────
step "2/12 boot tenant-control SCIM_ENABLED=1 on 127.0.0.1:${PORT_ON} (A · positive / B · reject)"
docker run -d --name "${TC_ON}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e ORG_MODEL_ENABLED=1 \
  -e SCIM_ENABLED=1 \
  -e TENANT_CONTROL_PORT=3070 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_ON}:3070" "${TC_IMG}" >/dev/null
wait_ready "${TC_ON}" "${PORT_ON}" || fail "scim-ON tenant-control not ready (line: wait_ready TC_ON)"
docker logs "${TC_ON}" 2>&1 | grep -q "SCIM .* enabled" \
  || { docker logs "${TC_ON}" 2>&1 | tail -20; fail "SCIM never reported enabled (line: TC_ON enabled log)"; }
ok "scim-ON tenant-control up (/scim/v2/* mounted)"

# ── 3) (A) issue a SCIM bearer token for T1/Org1 (admin/service-token) ──────────
step "3/12 (A) POST /v1/tenants/${TENANT_1}/scim/tokens (service-token) => 201 + cleartext bearer (once)"
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_1}/scim/tokens" "{\"org_id\":\"${ORG_1}\",\"description\":\"okta\"}")"
[[ "${C}" == "201" ]] || fail "(A) token issue expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A issue 201)"
T1_BEARER="$(json_str token)"
[[ -n "${T1_BEARER}" ]] || fail "(A) token issue did not return a cleartext token (line: A bearer)"
[[ "$(psql_val "SELECT count(*) FROM public.scim_tokens WHERE tenant_id='${TENANT_1}'")" == "1" ]] \
  || fail "(A) scim_tokens row for T1 not persisted (line: A token row)"
# the token must be stored HASHED, never as the cleartext.
[[ "$(psql_val "SELECT count(*) FROM public.scim_tokens WHERE token_hash='${T1_BEARER}'")" == "0" ]] \
  || fail "(A) the cleartext token was stored verbatim — must be sha256-hashed! (line: A token hashed)"
ok "(A) SCIM bearer issued for T1/Org1; stored hashed (sha256), cleartext returned once"

# ── 4) (A) POST /scim/v2/Users => 201 (provision an org member) ─────────────────
step "4/12 (A) POST /scim/v2/Users (T1 bearer) => 201 SCIM User (id, userName, active:true)"
C="$(scim_req POST "${PORT_ON}" "/scim/v2/Users" "${T1_BEARER}" \
  '{"schemas":["urn:ietf:params:scim:schemas:core:2.0:User"],"userName":"alice@example.com","externalId":"m111-alice","active":true,"emails":[{"value":"alice@example.com","primary":true}]}')"
[[ "${C}" == "201" ]] || fail "(A) create user expected 201, got ${C} — $(head -c 400 "${BODY_TMP}") (line: A create 201)"
SCIM_ID="$(json_str id)"
[[ -n "${SCIM_ID}" ]] || fail "(A) create user returned no SCIM id — $(head -c 400 "${BODY_TMP}") (line: A scim id)"
grep -q '"userName":"alice@example.com"' "${BODY_TMP}" || fail "(A) created user missing userName (line: A username)"
grep -q '"resourceType":"User"' "${BODY_TMP}" || fail "(A) created user missing meta.resourceType (line: A resourceType)"
# the org membership was created via the EXISTING orgs membership API.
[[ "$(psql_val "SELECT count(*) FROM public.org_members WHERE org_id='${ORG_1}' AND user_id='m111-alice'")" == "1" ]] \
  || fail "(A) SCIM create did not add an org member (the reuse of orgs.AddMember) (line: A member added)"
[[ "$(psql_val "SELECT active FROM public.org_members WHERE org_id='${ORG_1}' AND user_id='m111-alice'")" == "t" ]] \
  || fail "(A) newly provisioned member should be active (line: A member active)"
ok "(A) POST /scim/v2/Users => 201; org member 'm111-alice' added to Org1 (active)"

# ── 5) (A) GET by id => 200 ────────────────────────────────────────────────────
step "5/12 (A) GET /scim/v2/Users/${SCIM_ID} (T1 bearer) => 200"
C="$(scim_req GET "${PORT_ON}" "/scim/v2/Users/${SCIM_ID}" "${T1_BEARER}")"
[[ "${C}" == "200" ]] || fail "(A) get by id expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A get 200)"
grep -q "\"id\":\"${SCIM_ID}\"" "${BODY_TMP}" || fail "(A) get returned the wrong id (line: A get id)"
ok "(A) GET by id => 200"

# ── 6) (A) filter => exactly 1 result ──────────────────────────────────────────
step "6/12 (A) GET /scim/v2/Users?filter=userName eq \"alice@example.com\" => ListResponse(1)"
C="$(scim_req GET "${PORT_ON}" "/scim/v2/Users?filter=userName%20eq%20%22alice@example.com%22" "${T1_BEARER}")"
[[ "${C}" == "200" ]] || fail "(A) filter expected 200, got ${C} (line: A filter 200)"
grep -q '"totalResults":1' "${BODY_TMP}" || fail "(A) filter expected totalResults:1 — $(head -c 300 "${BODY_TMP}") (line: A filter count)"
grep -q 'urn:ietf:params:scim:api:messages:2.0:ListResponse' "${BODY_TMP}" || fail "(A) filter response missing ListResponse schema — $(head -c 300 "${BODY_TMP}") (line: A filter schema)"
ok "(A) filter => exactly 1 result (ListResponse)"

# ── 7) (A) PATCH active:false => the org member is DEACTIVATED ──────────────────
step "7/12 (A) PATCH /scim/v2/Users/${SCIM_ID} replace active:false => org member deactivated"
C="$(scim_req PATCH "${PORT_ON}" "/scim/v2/Users/${SCIM_ID}" "${T1_BEARER}" \
  '{"schemas":["urn:ietf:params:scim:api:messages:2.0:PatchOp"],"Operations":[{"op":"replace","path":"active","value":false}]}')"
[[ "${C}" == "200" ]] || fail "(A) patch expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A patch 200)"
grep -q '"active":false' "${BODY_TMP}" || fail "(A) patched user should report active:false (line: A patch active)"
# the deactivate must reach the ACTUAL org member row (org_members.active=false).
[[ "$(psql_val "SELECT active FROM public.org_members WHERE org_id='${ORG_1}' AND user_id='m111-alice'")" == "f" ]] \
  || fail "(A) PATCH active:false did NOT deactivate the org member (org_members.active still true) (line: A member deactivated)"
ok "(A) PATCH active:false => org member m111-alice deactivated (org_members.active=false)"

# ── 8) (B) cross-tenant wall: a T2 bearer cannot touch T1's user ────────────────
step "8/12 (B · LOAD-BEARING) cross-tenant wall: a T2 bearer cannot GET/PATCH/DELETE T1's user"
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_2}/scim/tokens" "{\"org_id\":\"${ORG_2}\",\"description\":\"entra-t2\"}")"
[[ "${C}" == "201" ]] || fail "(B) T2 token issue expected 201, got ${C} (line: B t2 issue)"
T2_BEARER="$(json_str token)"
[[ -n "${T2_BEARER}" ]] || fail "(B) T2 token issue returned no token (line: B t2 bearer)"
# GET T1's scim id with T2's bearer => 404 (not found within T2's tenant).
C="$(scim_req GET "${PORT_ON}" "/scim/v2/Users/${SCIM_ID}" "${T2_BEARER}")"
[[ "${C}" == "404" ]] || fail "(B) cross-tenant GET expected 404, got ${C} — $(head -c 300 "${BODY_TMP}") (line: B xtenant get)"
# PATCH T1's user with T2's bearer => 404; T1's user UNCHANGED (still deactivated).
C="$(scim_req PATCH "${PORT_ON}" "/scim/v2/Users/${SCIM_ID}" "${T2_BEARER}" \
  '{"schemas":["urn:ietf:params:scim:api:messages:2.0:PatchOp"],"Operations":[{"op":"replace","path":"active","value":true}]}')"
[[ "${C}" == "404" ]] || fail "(B) cross-tenant PATCH expected 404, got ${C} (line: B xtenant patch)"
[[ "$(psql_val "SELECT active FROM public.org_members WHERE org_id='${ORG_1}' AND user_id='m111-alice'")" == "f" ]] \
  || fail "(B) a cross-tenant PATCH MUTATED T1's member — the wall leaked! (line: B xtenant unchanged)"
# DELETE T1's user with T2's bearer => 404; the SCIM mapping + member survive.
C="$(scim_req DELETE "${PORT_ON}" "/scim/v2/Users/${SCIM_ID}" "${T2_BEARER}")"
[[ "${C}" == "404" ]] || fail "(B) cross-tenant DELETE expected 404, got ${C} (line: B xtenant delete)"
[[ "$(psql_val "SELECT count(*) FROM public.org_members WHERE org_id='${ORG_1}' AND user_id='m111-alice'")" == "1" ]] \
  || fail "(B) a cross-tenant DELETE removed T1's member — the wall leaked! (line: B xtenant member survives)"
ok "(B) cross-tenant wall holds: T2 bearer => 404 on T1's user; T1 unchanged (the bearer->tenant binding IS the wall)"

# ── 9) (B) no bearer => 401; revoked/unknown bearer => 401 ─────────────────────
step "9/12 (B · LOAD-BEARING) no bearer => 401; unknown bearer => 401; REVOKED bearer => 401"
C="$(scim_req GET "${PORT_ON}" "/scim/v2/Users/${SCIM_ID}" "__NONE__")"
[[ "${C}" == "401" ]] || fail "(B) no-bearer expected 401, got ${C} (line: B no bearer)"
C="$(scim_req GET "${PORT_ON}" "/scim/v2/Users/${SCIM_ID}" "scim_totally-unknown-token")"
[[ "${C}" == "401" ]] || fail "(B) unknown-bearer expected 401, got ${C} (line: B unknown bearer)"
# Revoke T1's token, then a call with it must 401.
T1_TOKEN_ID="$(psql_val "SELECT id FROM public.scim_tokens WHERE tenant_id='${TENANT_1}'")"
[[ -n "${T1_TOKEN_ID}" ]] || fail "(B) could not read T1 token id for revoke (line: B token id)"
C="$(admin_req DELETE "${PORT_ON}" "/v1/tenants/${TENANT_1}/scim/tokens/${T1_TOKEN_ID}")"
[[ "${C}" == "204" ]] || fail "(B) token revoke expected 204, got ${C} (line: B revoke 204)"
C="$(scim_req GET "${PORT_ON}" "/scim/v2/Users/${SCIM_ID}" "${T1_BEARER}")"
[[ "${C}" == "401" ]] || fail "(B) a REVOKED bearer expected 401, got ${C} — revocation broken! (line: B revoked 401)"
ok "(B) no/unknown/revoked bearer all 401 — the bearer gate + revocation fire"

# ── 10) (A) DELETE => 204 + member gone (re-issue a fresh token first) ──────────
step "10/12 (A) DELETE /scim/v2/Users/${SCIM_ID} => 204 and the org member is GONE"
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_1}/scim/tokens" "{\"org_id\":\"${ORG_1}\",\"description\":\"okta-2\"}")"
[[ "${C}" == "201" ]] || fail "(A) re-issue token expected 201, got ${C} (line: A reissue)"
T1_BEARER2="$(json_str token)"
C="$(scim_req DELETE "${PORT_ON}" "/scim/v2/Users/${SCIM_ID}" "${T1_BEARER2}")"
[[ "${C}" == "204" ]] || fail "(A) delete expected 204, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A delete 204)"
[[ "$(psql_val "SELECT count(*) FROM public.scim_users WHERE scim_id='${SCIM_ID}'")" == "0" ]] \
  || fail "(A) DELETE left the SCIM mapping behind (line: A mapping gone)"
[[ "$(psql_val "SELECT count(*) FROM public.org_members WHERE org_id='${ORG_1}' AND user_id='m111-alice'")" == "0" ]] \
  || fail "(A) DELETE did NOT deprovision the org member (line: A member gone)"
C="$(scim_req GET "${PORT_ON}" "/scim/v2/Users/${SCIM_ID}" "${T1_BEARER2}")"
[[ "${C}" == "404" ]] || fail "(A) GET after delete expected 404, got ${C} (line: A get-after-delete)"
ok "(A) DELETE => 204; SCIM mapping + org member both removed (deprovision)"

# ── 11) (C) FLAG-OFF PARITY — boot with SCIM_ENABLED unset ──────────────────────
step "11/12 (C · FLAG-OFF PARITY) STOP the ON container; boot with SCIM_ENABLED unset (same DB)"
docker rm -fv "${TC_ON}" >/dev/null 2>&1 || true
TOK_BEFORE="$(psql_val "SELECT count(*) FROM public.scim_tokens")"
docker run -d --name "${TC_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TENANT_CONTROL_PORT=3070 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_OFF}:3070" "${TC_IMG}" >/dev/null
wait_ready "${TC_OFF}" "${PORT_OFF}" || fail "scim-OFF tenant-control not ready (line: wait_ready TC_OFF)"
docker logs "${TC_OFF}" 2>&1 | grep -q "SCIM .* disabled" \
  || { docker logs "${TC_OFF}" 2>&1 | tail -20; fail "OFF tenant-control did not report SCIM disabled (flag default not OFF?) (line: TC_OFF disabled log)"; }
ok "scim-OFF tenant-control up (SCIM_ENABLED unset)"

step "11b/12 (C) EVERY /scim/v2/* route 404 with the flag OFF (byte-parity — gotrue has no SCIM)"
for path in "/scim/v2/Users" "/scim/v2/Users/${SCIM_ID}"; do
  C="$(scim_req GET "${PORT_OFF}" "${path}" "anything")"
  [[ "${C}" == "404" ]] \
    || fail "(C) PARITY: GET ${path} with SCIM_ENABLED off expected 404 (route absent), got ${C} (line: C 404 ${path})"
done
C="$(scim_req POST "${PORT_OFF}" "/scim/v2/Users" "anything" '{"userName":"x"}')"
[[ "${C}" == "404" ]] || fail "(C) PARITY: POST /scim/v2/Users off expected 404, got ${C} (line: C 404 post)"
# the admin token route is also gated by SCIM_ENABLED.
C="$(admin_req POST "${PORT_OFF}" "/v1/tenants/${TENANT_1}/scim/tokens" '{"org_id":"x"}')"
[[ "${C}" == "404" ]] || fail "(C) PARITY: admin scim/tokens route off expected 404, got ${C} (line: C 404 admin)"
ok "(C) all /scim/v2/* + the admin token route 404 with the flag OFF"

step "11c/12 (C) the base admin surface STILL works on the OFF router (only SCIM is gated)"
C="$(admin_req GET "${PORT_OFF}" "/v1/tenants")"
[[ "${C}" == "200" ]] \
  || fail "(C) PARITY: base admin GET /v1/tenants expected 200 on OFF router, got ${C} — $(head -c 200 "${BODY_TMP}") (line: C admin 200)"
ok "(C) base admin GET /v1/tenants => 200 — baseline untouched; only SCIM is flag-gated"

step "11d/12 (C) the OFF router NEVER wrote scim_tokens (count unchanged)"
TOK_AFTER="$(psql_val "SELECT count(*) FROM public.scim_tokens")"
[[ "${TOK_BEFORE}" == "${TOK_AFTER}" ]] \
  || fail "(C) PARITY: scim_tokens changed under the OFF router (before=${TOK_BEFORE} after=${TOK_AFTER}) (line: C no writes)"
ok "(C) scim_tokens unchanged (${TOK_AFTER}) — never touched with the flag OFF"

# ── 12) summary ────────────────────────────────────────────────────────────────
step "12/12 summary"
green "[M111] (A) POSITIVE:  issue bearer (sha256-stored) -> POST /scim/v2/Users 201 (org member added via orgs.AddMember) -> GET 200 -> filter 1 -> PATCH active:false (org_members.active=false) -> DELETE 204 (member + mapping gone)"
green "[M111] (B) REJECT:    no/unknown/revoked bearer => 401; cross-tenant T2 bearer => 404 on T1's user, T1 UNCHANGED (the bearer->tenant binding IS the wall) — LOAD-BEARING"
green "[M111] (C) PARITY:    SCIM_ENABLED off => all /scim/v2/* + admin token route 404 while admin GET /v1/tenants 200; scim_tokens never touched — byte-identical to today (gotrue has no SCIM)"

step "log GATE m111=PASS"
emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-d2b-scim}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m111=PASS" --outcome pass \
      --msg "D2b SCIM 2.0: a SCIM client (bearer token, sha256-stored) drives the full Users lifecycle — POST 201 (org member added via orgs.AddMember) -> GET 200 -> filter=userName eq 1 -> PATCH active:false (org_members.active=false) -> DELETE 204 (member+mapping gone); no/unknown/revoked bearer 401, cross-tenant T2 bearer 404 on T1's user with T1 UNCHANGED (load-bearing wall); SCIM_ENABLED OFF -> all /scim/v2/* + admin token route 404 while admin 200, scim_tokens never touched (byte-parity, gotrue has no SCIM)" \
      --ref "scripts/verify/m111-scim.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M111] ALL GATES GREEN — D2b SCIM: provision/read/filter/deactivate/deprovision via bearer token work end-to-end, reject no/unknown/revoked + cross-tenant (the per-tenant wall), and are byte-parity (routes 404) when OFF"
exit 0
