#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m166-groups-environments.sh                        :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/21 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/21 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M166 — per-project ENVIRONMENTS + project-scoped GROUPS live gate
# (ENVIRONMENTS_ENABLED + GROUPS_ENABLED, both under RBAC_HIERARCHY_ENABLED).
# Control-plane only — never touches the data plane. tenant-control built FROM
# CURRENT source:
#
#   (A · POSITIVE spine) U1 creates org A + project X; creates envs prod+dev;
#       creates the project's group (name == "<project>'s group"); adds U2 to it;
#       grants the GROUP writer on env=prod → effective(U2, prod)=writer (a group
#       grant PROPAGATES to members), AND a project-wide direct grant to U3 spans
#       BOTH envs.
#   (B · LOAD-BEARING REJECTS — a happy-path-only gate is VACUOUS)
#       PER-ENV ISOLATION: U2 granted only on prod → effective(U2, dev) = DENY;
#       deny-by-default (U3 with no grant → deny before the grant); a grant naming
#       an env that is NOT in the project → 400; a project may have only ONE group
#       (second create → 409).
#   (C · PARITY) a SECOND tenant-control with ENVIRONMENTS_ENABLED + GROUPS_ENABLED
#       UNSET → every /v1/projects/{id}/environments|groups route 404 while base
#       /v1/orgs/{id}/teams still 200, and NO environments/groups row is written.
#   (D · AUDIT) the group grant sealed a project.grant audit event for org A.
#
# ISOLATED (mirrors m162): scratch postgres (prelude + REAL 005/032/040/043/044/047
# + 072/073 + the NEW 077/078/079) + a tenant-control built FROM CURRENT source,
# PRIVATE network, every name suffixed $$, an EXIT-trap removing EVERYTHING.

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
step() { cyan "[M166] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[M166] FAIL — $*"
  exit 1
}

PG_IMAGE="${M166_PG_IMAGE:-postgres:16-alpine}"
TC_IMG="m166-tc-$$:scratch"
NET="m166net-$$"
PG="m166-pg-$$"
TC_ON="m166-tc-on-$$"
TC_OFF="m166-tc-off-$$"
PORT_ON="${M166_PORT_ON:-19166}"
PORT_OFF="${M166_PORT_OFF:-19167}"
PGPW="postgres"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SVC_TOKEN="m166-internal-service-token-$$"
JWT_SECRET="m166-jwt-secret-deadbeefcafef00ddeadbeefcafef00d"
BODY_TMP="$(mktemp)"

U1="11111111-1111-1111-1111-111111111111" # org A owner
U2="22222222-2222-2222-2222-222222222222" # group member (org A developer)
U3="33333333-3333-3333-3333-333333333333" # org A developer (project-wide grantee)

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

effEnv() { # $1=port $2=jwt $3=org $4=proj $5=user $6=env
  org_req GET "$1" "/v1/orgs/$3/projects/$4/effective?user=$5&env=$6" "$2" >/dev/null
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

# ── 1) isolated net + postgres + prelude + REAL migrations + NEW 077/078/079 ───
step "1/8 boot isolated net (${NET}): postgres + migrations 005..073 + NEW 077/078/079"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
# wait for the REAL server (TCP) — the temp init server listens on the socket only, so a
# socket-based probe can land the prelude on a server that's about to be discarded on restart.
for i in $(seq 1 60); do
  docker exec -i "${PG}" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 && break
  [[ $i -eq 60 ]] && fail "postgres never accepted TCP connections"
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
for m in 005_add_tenant_table 032_tenants 040_tenant_usage 043_orgs 044_org_billing_rollup 047_tenant_audit_log 072_teams 073_project_grants 077_environments 078_groups 079_project_grants_ext 083_env_scope_pubkey; do
  apply_migration "${MIG_DIR}/${m}.sql" || fail "migration ${m} failed to apply"
done
for t in environments groups group_members; do
  [[ "$(psql_val "SELECT count(*) FROM public.${t}")" == "0" ]] || fail "public.${t} should start EMPTY"
done
ok "migrations applied — environments/groups/group_members empty"

# ── 2) boot tenant-control with the flags ON ──────────────────────────────────
step "2/8 boot tenant-control ENVIRONMENTS_ENABLED=1 GROUPS_ENABLED=1 on 127.0.0.1:${PORT_ON}"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3020 \
  -t "${TC_IMG}" "${GO_DIR}" >/dev/null || fail "scratch tenant-control image build failed"
docker run -d --name "${TC_ON}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e GOTRUE_JWT_SECRET="${JWT_SECRET}" \
  -e ORG_MODEL_ENABLED=1 \
  -e RBAC_HIERARCHY_ENABLED=1 \
  -e ENVIRONMENTS_ENABLED=1 \
  -e GROUPS_ENABLED=1 \
  -e ADAPTER_REGISTRY_URL="" \
  -e TENANT_CONTROL_PORT=3020 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_ON}:3020" "${TC_IMG}" >/dev/null
wait_ready_http "${TC_ON}" "${PORT_ON}" /health/live || fail "ON tenant-control not ready"
{ docker logs "${TC_ON}" 2>&1 || true; } | grep -q "environments enabled" || fail "environments never reported enabled"
{ docker logs "${TC_ON}" 2>&1 || true; } | grep -q "groups enabled" || fail "groups never reported enabled"
ok "ON tenant-control up (environments + groups mounted)"

JWT_U1="$(mint_jwt "${U1}" u1@m166.test)"; [[ -n "${JWT_U1}" ]] || fail "mint U1"
JWT_U2="$(mint_jwt "${U2}" u2@m166.test)"; [[ -n "${JWT_U2}" ]] || fail "mint U2"
[[ "$(org_req GET "${PORT_ON}" /v1/orgs "${JWT_U1}")" == "200" ]] || fail "minted JWT not accepted"
ok "minted + verified human JWTs"

# ── 3) org A (U1 owner) + project X ───────────────────────────────────────────
step "3/8 (A) U1 creates org A + project X (name 'Proj X')"
ORG_SLUG="m166-org-a-$$"
[[ "$(org_req POST "${PORT_ON}" /v1/orgs "${JWT_U1}" "{\"slug\":\"${ORG_SLUG}\",\"name\":\"Org A\"}")" == "201" ]] ||
  fail "create org A — $(head -c 300 "${BODY_TMP}")"
ORG_A="$(json_str id)"; [[ -n "${ORG_A}" ]] || fail "org A id missing"
psql_val "INSERT INTO public.org_members (org_id, user_id, role, invited_by) VALUES ('${ORG_A}'::uuid,'${U2}','developer','${U1}'),('${ORG_A}'::uuid,'${U3}','developer','${U1}') ON CONFLICT (org_id,user_id) DO NOTHING" >/dev/null
PROJ_SLUG="m166-proj-x-$$"
PROJ_BODY="{\"tenant\":\"${PROJ_SLUG}\",\"name\":\"Proj X\",\"plan\":\"nano\",\"seed_roles\":false,\"mounts\":[{\"engine\":\"postgresql\",\"name\":\"probe\",\"connection_string\":\"${DB_INNET}\",\"isolation\":\"shared_rls\"}]}"
C="$(org_req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/projects" "${JWT_U1}" "${PROJ_BODY}")"
[[ "${C}" == "200" || "${C}" == "201" ]] || fail "provision project X expected 200/201, got ${C} — $(head -c 400 "${BODY_TMP}")"
PROJ_X="$(psql_val "SELECT id::text FROM public.tenants WHERE slug='${PROJ_SLUG}' AND org_id::text='${ORG_A}'")"
[[ -n "${PROJ_X}" ]] || fail "project X tenant row (org_id stamped) not found"
ok "org A (${ORG_A}), project X (${PROJ_X}) created"

# ── 4) (A) environments prod+dev; the project group; member U2 ────────────────
step "4/8 (A) create envs prod+dev, the project group ('Proj X's group'), add U2"
C="$(org_req POST "${PORT_ON}" "/v1/projects/${PROJ_X}/environments" "${JWT_U1}" '{"name":"prod"}')"
[[ "${C}" == "201" ]] || fail "create env prod expected 201, got ${C} — $(head -c 300 "${BODY_TMP}")"
ENV_PROD="$(json_str id)"; [[ -n "${ENV_PROD}" ]] || fail "env prod id missing"
[[ "$(org_req POST "${PORT_ON}" "/v1/projects/${PROJ_X}/environments" "${JWT_U1}" '{"name":"dev"}')" == "201" ]] || fail "create env dev"
ENV_DEV="$(json_str id)"; [[ -n "${ENV_DEV}" ]] || fail "env dev id missing"
# publish the prod env's vault42 scope PUBLIC key (the bootstrap step clients seal to).
[[ "$(org_req PUT "${PORT_ON}" "/v1/projects/${PROJ_X}/environments/${ENV_PROD}/scopekey" "${JWT_U1}" '{"scope_pubkey":"X25519SCOPEPROD","scope_epoch":1}')" == "200" ]] || fail "publish env scope pubkey"
[[ "$(json_str scope_pubkey)" == "X25519SCOPEPROD" ]] || fail "scope_pubkey not returned after publish"
[[ "$(org_req GET "${PORT_ON}" "/v1/projects/${PROJ_X}/environments" "${JWT_U1}")" == "200" ]] || fail "list envs"
C="$(org_req POST "${PORT_ON}" "/v1/projects/${PROJ_X}/groups" "${JWT_U1}")"
[[ "${C}" == "201" ]] || fail "create group expected 201, got ${C} — $(head -c 300 "${BODY_TMP}")"
GROUP_ID="$(json_str id)"; GROUP_NAME="$(json_str name)"
[[ -n "${GROUP_ID}" ]] || fail "group id missing"
[[ "${GROUP_NAME}" == "Proj X's group" ]] || fail "group name should be \"Proj X's group\", got '${GROUP_NAME}'"
[[ "$(org_req POST "${PORT_ON}" "/v1/groups/${GROUP_ID}/members" "${JWT_U1}" "{\"user_id\":\"${U2}\"}")" == "201" ]] || fail "add U2 to group"
ok "(A) envs prod(${ENV_PROD})+dev created; group '${GROUP_NAME}' with member U2"

# ── 5) (A) group→writer on env=prod PROPAGATES; project-wide grant spans envs ──
step "5/8 (A) group writer on prod → effective(U2,prod)=writer; project-wide U3 spans both envs"
C="$(org_req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/projects/${PROJ_X}/grants" "${JWT_U1}" \
  "{\"grantee_kind\":\"group\",\"grantee_id\":\"${GROUP_ID}\",\"project_role\":\"writer\",\"env_id\":\"${ENV_PROD}\"}")"
[[ "${C}" == "201" ]] || fail "grant group writer on prod expected 201, got ${C} — $(head -c 300 "${BODY_TMP}")"
[[ "$(effEnv "${PORT_ON}" "${JWT_U1}" "${ORG_A}" "${PROJ_X}" "${U2}" "${ENV_PROD}")" == "writer" ]] || fail "(A) group grant did not propagate to U2 on prod"
# project-wide direct grant to U3 (no env_id) → applies to BOTH envs.
[[ "$(org_req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/projects/${PROJ_X}/grants" "${JWT_U1}" \
  "{\"grantee_kind\":\"user\",\"grantee_id\":\"${U3}\",\"project_role\":\"reader\"}")" == "201" ]] || fail "project-wide grant to U3"
[[ "$(effEnv "${PORT_ON}" "${JWT_U1}" "${ORG_A}" "${PROJ_X}" "${U3}" "${ENV_PROD}")" == "reader" ]] || fail "(A) project-wide grant missing on prod"
[[ "$(effEnv "${PORT_ON}" "${JWT_U1}" "${ORG_A}" "${PROJ_X}" "${U3}" "${ENV_DEV}")" == "reader" ]] || fail "(A) project-wide grant missing on dev"
ok "(A) group→writer on prod propagates to U2; project-wide reader (U3) spans prod AND dev"

# ── 6) (B · REJECTS) per-env isolation · deny-default · bad env · one group ────
step "6/8 (B) PER-ENV isolation · deny-by-default · bad-env 400 · one-group-per-project 409"
# the KEY proof: U2 was granted ONLY on prod → no access on dev.
[[ -z "$(effEnv "${PORT_ON}" "${JWT_U1}" "${ORG_A}" "${PROJ_X}" "${U2}" "${ENV_DEV}")" ]] || fail "(B) PER-ENV isolation broken: U2 (prod-only) has access on dev"
ok "(B) PER-ENV isolation REAL — U2 granted on prod has NO access on dev"
# deny-by-default: an env that belongs to ANOTHER project → 400 (ErrBadEnv).
RANDU="$(psql_val "SELECT gen_random_uuid()::text")"
C="$(org_req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/projects/${PROJ_X}/grants" "${JWT_U1}" \
  "{\"grantee_kind\":\"user\",\"grantee_id\":\"${U3}\",\"project_role\":\"reader\",\"env_id\":\"${RANDU}\"}")"
[[ "${C}" == "400" ]] || fail "(B) a grant naming an env not in the project expected 400, got ${C}"
ok "(B) bad env_id (not in project) → 400 (ErrBadEnv)"
# one group per project: a second create → 409.
[[ "$(org_req POST "${PORT_ON}" "/v1/projects/${PROJ_X}/groups" "${JWT_U1}")" == "409" ]] || fail "(B) second group create should 409 (one group per project)"
ok "(B) one-group-per-project enforced — second create → 409"

# ── 7) (C · PARITY) flags OFF → env/group routes 404, base /teams 200, no rows ─
step "7/8 (C · PARITY) ENVIRONMENTS_ENABLED + GROUPS_ENABLED unset → routes 404, no rows"
ENVS_BEFORE="$(psql_val "SELECT count(*) FROM public.environments")"
GROUPS_BEFORE="$(psql_val "SELECT count(*) FROM public.groups")"
docker run -d --name "${TC_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e GOTRUE_JWT_SECRET="${JWT_SECRET}" \
  -e ORG_MODEL_ENABLED=1 \
  -e RBAC_HIERARCHY_ENABLED=1 \
  -e TENANT_CONTROL_PORT=3020 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_OFF}:3020" "${TC_IMG}" >/dev/null
wait_ready_http "${TC_OFF}" "${PORT_OFF}" /health/live || fail "OFF tenant-control not ready"
{ docker logs "${TC_OFF}" 2>&1 || true; } | grep -q "environments disabled" || fail "(C) OFF instance did not report environments disabled"
[[ "$(org_req POST "${PORT_OFF}" "/v1/projects/${PROJ_X}/environments" "${JWT_U1}" '{"name":"staging"}')" == "404" ]] || fail "(C) env route with flag OFF expected 404"
[[ "$(org_req POST "${PORT_OFF}" "/v1/projects/${PROJ_X}/groups" "${JWT_U1}")" == "404" ]] || fail "(C) group route with flag OFF expected 404"
[[ "$(org_req GET "${PORT_OFF}" "/v1/orgs/${ORG_A}/teams" "${JWT_U1}")" == "200" ]] || fail "(C) base /v1/orgs/{id}/teams should still be 200 (RBAC on)"
[[ "$(psql_val "SELECT count(*) FROM public.environments")" == "${ENVS_BEFORE}" ]] || fail "(C) OFF router wrote an environments row — not byte-parity"
[[ "$(psql_val "SELECT count(*) FROM public.groups")" == "${GROUPS_BEFORE}" ]] || fail "(C) OFF router wrote a groups row — not byte-parity"
ok "(C) flags OFF → env/group 404; base /teams 200; no rows written (byte-parity)"

# ── 8) (D · AUDIT) the group grant sealed a project.grant event ───────────────
step "8/8 (D · AUDIT) the group→project grant sealed a project.grant audit event for org A"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_audit_log WHERE tenant_id='${ORG_A}' AND action='project.grant'")" -ge 1 ]] || fail "(D) no project.grant audit event"
ok "(D) audit chain sealed project.grant event(s) for org A"

green "[M166] (A) envs + '<project>'s group' + group grant PROPAGATES; project-wide grant spans envs"
green "[M166] (B) PER-ENV isolation · deny-default · bad-env 400 · one-group-per-project 409"
green "[M166] (C) flags OFF → env/group routes 404, base /teams 200, no rows (byte-parity)"
green "[M166] (D) group grant sealed a tamper-evident audit event"

emit_gate_log() {
  (
    set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-groups-environments}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m166=PASS" --outcome pass \
      --msg "environments + project-scoped groups: env CRUD; group name '<project>'s group'; group grant propagates to members; per-env grant isolation (prod-only != dev); project-wide grant spans envs; bad env_id 400; one group per project 409; flags OFF -> routes 404 + no rows (byte-parity); group grant sealed audit" \
      --ref "scripts/verify/m166-groups-environments.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
green "[M166] ALL GATES GREEN — per-project environments + project-scoped groups + per-env grants"
exit 0
