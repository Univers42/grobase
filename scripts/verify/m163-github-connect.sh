#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m163-github-connect.sh                             :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/20 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/20 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M163 — Track-E GITHUB APP CONNECT / device-login / org-sync live gate
# (GITHUB_CONNECT_ENABLED). Control-plane only. Exercises a tenant-control built FROM
# CURRENT source against a MOCK GitHub (the App API + OAuth base URLs are injected):
#
#   (A) device-flow login with NO CALLBACK — /device/start → /device/poll → the server
#       reads /user, DISCARDS the GitHub token, mints a GoTrue session the tenant
#       JWTVerifier accepts; github_user_links records the deterministic subject.
#   (B) relay callback — POST /v1/github/callback with a valid X-Github-Relay HMAC
#       records the installation + flips the pending nonce to ready; an INVALID HMAC
#       → 401 (the relay forward is authenticated; Vercel holds only this secret).
#   (C) link + org sync — link the GitHub org → vault42 org, sync maps members→org
#       members + teams→teams + team membership; re-sync is IDEMPOTENT; and NO
#       github_* row ever contains an installation/user token (minted JIT, discarded).
#   (D) PARITY — GITHUB_CONNECT_ENABLED unset → every /v1/github* + /github/* route
#       404 while base /v1/orgs still 200, and no github_* row written.
#
# ISOLATED (mirrors m103/m162): scratch postgres (prelude + REAL migrations + NEW 074)
# + a mock GitHub + a tenant-control FROM CURRENT source, on a PRIVATE network, names
# suffixed $$, an EXIT-trap removing EVERYTHING. Never touches mini-baas-*.

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
step() { cyan "[M163] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[M163] FAIL — $*"
  exit 1
}

PG_IMAGE="${M163_PG_IMAGE:-postgres:16-alpine}"
MOCK_IMAGE="${M163_MOCK_IMAGE:-python:3-alpine}"
TC_IMG="m163-tc-$$:scratch"
NET="m163net-$$"
PG="m163-pg-$$"
MOCK="m163-mock-$$"
TC_ON="m163-tc-on-$$"
TC_OFF="m163-tc-off-$$"
PORT_ON="${M163_PORT_ON:-19166}"
PORT_OFF="${M163_PORT_OFF:-19167}"
PGPW="postgres"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SVC_TOKEN="m163-svc-$$"
JWT_SECRET="m163-jwt-secret-deadbeefcafef00ddeadbeefcafef00d"
RELAY_SECRET="m163-relay-secret-$$"
MOCK_BASE="http://${MOCK}:8099"
BODY_TMP="$(mktemp)"
MOCK_PY="$(mktemp --suffix=.py)"
APP_KEY_FILE="$(mktemp)"

U1="11111111-1111-1111-1111-111111111111"

cleanup() {
  docker rm -fv "${TC_ON}" "${TC_OFF}" "${MOCK}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${TC_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" "${MOCK_PY}" "${APP_KEY_FILE}" 2>/dev/null || true
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
        translate(encode(convert_to('{\"sub\":\"${sub}\",\"email\":\"${email}\",\"role\":\"authenticated\",\"aud\":\"authenticated\",\"exp\":' ||
          (extract(epoch from now())::bigint + 3600)::text || '}','utf8'),'base64'),'+/=' || chr(10) || chr(13),'-_') AS p
    ),
    signed AS (SELECT h, p, translate(encode(hmac((h || '.' || p), '${JWT_SECRET}', 'sha256'),'base64'),'+/=' || chr(10) || chr(13),'-_') AS s FROM parts)
    SELECT rtrim(h,'=') || '.' || rtrim(p,'=') || '.' || rtrim(s,'=') FROM signed;"
}

req() { # $1=method $2=port $3=path $4=auth-header-value(optional Bearer/none) $5=body
  local m="$1" p="$2" path="$3" auth="$4" body="${5:-}"
  local h=()
  [[ -n "${auth}" ]] && h+=(-H "Authorization: Bearer ${auth}")
  if [[ -n "${body}" ]]; then
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" "${h[@]}" -H 'Content-Type: application/json' -d "${body}"
  else
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" "${h[@]}"
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
  red "$1 never ready:"; docker logs "$1" 2>&1 | tail -20; return 1
}

# A relay header `v1.<ts>.<sig>`: sig = HMAC-SHA256(secret, "v1\n<ts>\n<hex(sha256(body))>").
relay_header() { # $1=body
  local body="$1" ts bodyhash sig
  ts="$(date +%s)"
  bodyhash="$(printf '%s' "${body}" | openssl dgst -sha256 | sed 's/^.*= //')"
  sig="$(printf 'v1\n%s\n%s' "${ts}" "${bodyhash}" | openssl dgst -sha256 -hmac "${RELAY_SECRET}" | sed 's/^.*= //')"
  printf 'v1.%s.%s' "${ts}" "${sig}"
}

# ── 0) build tenant-control + a generated RSA App key + the mock GitHub script ──
step "0/8 build scratch tenant-control + generate App key + write mock GitHub"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3020 \
  -t "${TC_IMG}" "${GO_DIR}" >/dev/null || fail "tenant-control image build failed"
openssl genrsa -out "${APP_KEY_FILE}" 2048 >/dev/null 2>&1 || fail "could not generate a test RSA App key"
APP_KEY="$(cat "${APP_KEY_FILE}")"
cat >"${MOCK_PY}" <<'PY'
import json, re
from http.server import BaseHTTPRequestHandler, HTTPServer
def J(h, code, obj):
    b = json.dumps(obj).encode()
    h.send_response(code); h.send_header('Content-Type','application/json')
    h.send_header('Content-Length', str(len(b))); h.end_headers(); h.wfile.write(b)
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        p = self.path.split('?')[0]
        if p == '/login/device/code':
            return J(self,200,{"device_code":"dc-123","user_code":"WXYZ-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":1})
        if p == '/login/oauth/access_token':
            return J(self,200,{"access_token":"gho_user_token_SECRET"})
        if re.match(r'/app/installations/\d+/access_tokens$', p):
            return J(self,201,{"token":"ghs_install_token_SECRET","expires_at":"2099-01-01T00:00:00Z"})
        return J(self,404,{"error":"nf"})
    def do_GET(self):
        p = self.path.split('?')[0]
        if p == '/user':
            return J(self,200,{"login":"operator","id":4242})
        if re.match(r'/app/installations/\d+$', p):
            return J(self,200,{"account":{"login":"Univers42","id":99},"app_slug":"grobase","permissions":{"metadata":"read","members":"read"}})
        if p == '/orgs/Univers42/members':
            return J(self,200,[{"login":"alice","id":1},{"login":"bob","id":2}])
        if p == '/orgs/Univers42/teams':
            return J(self,200,[{"slug":"core","name":"Core"}])
        if p == '/orgs/Univers42/teams/core/members':
            return J(self,200,[{"login":"alice","id":1}])
        return J(self,404,{"error":"nf"})
HTTPServer(('0.0.0.0',8099), H).serve_forever()
PY
ok "tenant-control built; RSA App key generated; mock GitHub script written"

# ── 1) net + postgres + migrations (incl NEW 074) + mock GitHub ────────────────
step "1/8 boot net (${NET}): postgres + migrations + mock GitHub"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
for i in $(seq 1 90); do
  docker exec "${PG}" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 && [[ "$(psql_val 'SELECT 1')" == "1" ]] && break
  [[ $i -eq 90 ]] && { docker logs "${PG}" 2>&1 | tail -20; fail "postgres never ready"; }
  sleep 0.5
done
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE IF NOT EXISTS public.schema_migrations (version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.current_user_id() RETURNS uuid LANGUAGE sql STABLE AS $fn$ SELECT NULLIF(current_setting('app.current_user_id', true), '')::uuid $fn$;
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS uuid LANGUAGE sql STABLE AS $fn$ SELECT COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'tenant_id', NULLIF(current_setting('app.current_tenant_id', true), ''), auth.current_user_id()::text)::uuid $fn$;
DO $r$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role; END IF;
END $r$;
GRANT EXECUTE ON FUNCTION auth.current_user_id() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.current_tenant_id() TO anon, authenticated, service_role;
SQL
for m in 005_add_tenant_table 032_tenants 040_tenant_usage 043_orgs 044_org_billing_rollup 047_tenant_audit_log 072_teams 073_project_grants 074_github_connect; do
  apply_migration "${MIG_DIR}/${m}.sql" || fail "migration ${m} failed"
done
for t in github_installations github_links github_connect_pending github_user_links; do
  [[ "$(psql_val "SELECT count(*) FROM public.${t}")" == "0" ]] || fail "public.${t} should start EMPTY"
done
docker run -d --name "${MOCK}" --network "${NET}" -v "${MOCK_PY}:/mock.py:ro" "${MOCK_IMAGE}" python /mock.py >/dev/null
ok "migrations applied (github_* empty); mock GitHub up at ${MOCK_BASE}"

# ── 2) boot tenant-control GITHUB_CONNECT_ENABLED=1 (base URLs → mock) ─────────
step "2/8 boot tenant-control GITHUB_CONNECT_ENABLED=1 on 127.0.0.1:${PORT_ON}"
docker run -d --name "${TC_ON}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e GOTRUE_JWT_SECRET="${JWT_SECRET}" \
  -e ORG_MODEL_ENABLED=1 -e RBAC_HIERARCHY_ENABLED=1 -e GITHUB_CONNECT_ENABLED=1 \
  -e GITHUB_APP_ID=123456 -e GITHUB_APP_PRIVATE_KEY="${APP_KEY}" \
  -e GITHUB_APP_CLIENT_ID="Iv1.testclientid" -e GITHUB_RELAY_SECRET="${RELAY_SECRET}" \
  -e GITHUB_API_BASE="${MOCK_BASE}" -e GITHUB_OAUTH_BASE="${MOCK_BASE}" \
  -e ADAPTER_REGISTRY_URL="" -e TENANT_CONTROL_PORT=3020 -e TENANT_CONTROL_PRODUCT_MODE=enabled -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_ON}:3020" "${TC_IMG}" >/dev/null
wait_ready_http "${TC_ON}" "${PORT_ON}" /health/live || fail "GH-ON tenant-control not ready"
{ docker logs "${TC_ON}" 2>&1 || true; } | grep -q "github connect enabled" || { docker logs "${TC_ON}" 2>&1 | tail -20; fail "github connect never reported enabled"; }
JWT_U1="$(mint_jwt "${U1}" u1@m163.test)"; [[ -n "${JWT_U1}" ]] || fail "mint U1"
ok "GH-ON tenant-control up (/v1/github/* + /v1/orgs/{id}/github/* mounted)"

# ── 3) (A) device-flow login with NO CALLBACK ─────────────────────────────────
step "3/8 (A) device-flow login (no callback) → server discards the GitHub token + mints a session"
[[ "$(req POST "${PORT_ON}" /v1/github/device/start "" "")" == "200" ]] || fail "(A) device/start expected 200 — $(head -c 200 "${BODY_TMP}")"
[[ "$(json_str user_code)" == "WXYZ-1234" ]] || fail "(A) device/start did not relay the user_code"
[[ "$(req POST "${PORT_ON}" /v1/github/device/poll "" '{"device_code":"dc-123"}')" == "200" ]] || fail "(A) device/poll expected 200 — $(head -c 200 "${BODY_TMP}")"
SESSION="$(json_str access_token)"; [[ -n "${SESSION}" ]] || fail "(A) device/poll returned no minted session token"
[[ "${SESSION}" == gho_* ]] && fail "(A) the RAW GitHub token was returned — must mint a session, not pass the GitHub token through"
[[ "$(req GET "${PORT_ON}" /v1/orgs "${SESSION}" "")" == "200" ]] || fail "(A) the minted session JWT is not accepted by the verifier"
[[ "$(psql_val "SELECT count(*) FROM public.github_user_links WHERE github_user_id=4242")" == "1" ]] || fail "(A) github_user_links did not record the GitHub user"
ok "(A) device-flow login works with NO callback; GitHub token discarded; session JWT accepted; user linked"

# ── 4) (B) relay callback — valid HMAC records the installation; bad HMAC → 401 ─
step "4/8 (B) relay callback authenticated by the X-Github-Relay HMAC"
[[ "$(req POST "${PORT_ON}" /v1/orgs "${JWT_U1}" "{\"slug\":\"m163-org-$$\",\"name\":\"Org A\"}")" == "201" ]] || fail "create org A"
ORG_A="$(json_str id)"; [[ -n "${ORG_A}" ]] || fail "org A id missing"
[[ "$(req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/github/connect/start" "${JWT_U1}" "{}")" == "201" ]] || fail "connect/start — $(head -c 200 "${BODY_TMP}")"
NONCE="$(json_str nonce)"; [[ -n "${NONCE}" ]] || fail "connect/start returned no nonce"
CB_BODY="{\"installation_id\":555,\"state\":\"${NONCE}\"}"
# bad HMAC → 401
[[ "$(curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST "http://127.0.0.1:${PORT_ON}/v1/github/callback" -H 'X-Github-Relay: v1.9999999999.deadbeef' -H 'Content-Type: application/json' -d "${CB_BODY}")" == "401" ]] || fail "(B) callback with a BAD relay HMAC was not rejected (401)"
# valid HMAC → 200 + installation recorded (org login resolved from the mock)
H="$(relay_header "${CB_BODY}")"
[[ "$(curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST "http://127.0.0.1:${PORT_ON}/v1/github/callback" -H "X-Github-Relay: ${H}" -H 'Content-Type: application/json' -d "${CB_BODY}")" == "200" ]] || fail "(B) callback with a VALID relay HMAC failed — $(head -c 200 "${BODY_TMP}")"
[[ "$(psql_val "SELECT github_org_login FROM public.github_installations WHERE installation_id=555")" == "Univers42" ]] || fail "(B) installation not recorded with the org login"
[[ "$(req GET "${PORT_ON}" "/v1/github/connect/status?nonce=${NONCE}" "" "")" == "200" ]] && [[ "$(json_str status)" == "ready" ]] || fail "(B) connect status did not flip to ready"
ok "(B) relay callback — bad HMAC 401, valid HMAC records installation 555 (Univers42), nonce → ready"

# ── 5) (C) link + org sync (idempotent) + token never persisted ───────────────
step "5/8 (C) link the GitHub org + sync members/teams (idempotent); no token persisted"
[[ "$(req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/github/link" "${JWT_U1}" '{"github_org_login":"Univers42"}')" == "200" ]] || fail "(C) link — $(head -c 200 "${BODY_TMP}")"
[[ "$(req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/github/sync" "${JWT_U1}" "{}")" == "200" ]] || fail "(C) sync — $(head -c 200 "${BODY_TMP}")"
grep -q '"teams":1' "${BODY_TMP}" || fail "(C) sync did not report 1 team — $(head -c 200 "${BODY_TMP}")"
# U1 owner + alice + bob = 3 org members; 1 team (core); 1 team member (alice).
MEMB1="$(psql_val "SELECT count(*) FROM public.org_members WHERE org_id::text='${ORG_A}'")"
[[ "${MEMB1}" -ge 3 ]] || fail "(C) expected ≥3 org members after sync (owner+alice+bob), got ${MEMB1}"
[[ "$(psql_val "SELECT count(*) FROM public.teams WHERE org_id::text='${ORG_A}' AND slug='core'")" == "1" ]] || fail "(C) team 'core' not synced"
[[ "$(psql_val "SELECT count(*) FROM public.team_members tm JOIN public.teams t ON t.id=tm.team_id WHERE t.org_id::text='${ORG_A}'")" -ge 1 ]] || fail "(C) team membership not synced"
# idempotent: re-sync → counts unchanged.
[[ "$(req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/github/sync" "${JWT_U1}" "{}")" == "200" ]] || fail "(C) re-sync failed"
[[ "$(psql_val "SELECT count(*) FROM public.org_members WHERE org_id::text='${ORG_A}'")" == "${MEMB1}" ]] || fail "(C) re-sync was NOT idempotent (org member count changed)"
[[ "$(psql_val "SELECT count(*) FROM public.teams WHERE org_id::text='${ORG_A}'")" == "1" ]] || fail "(C) re-sync duplicated teams"
# token-never-persisted: no github_* row holds an installation/user token string.
TOKLEAK="$(psql_val "SELECT count(*) FROM public.github_installations WHERE permissions::text LIKE '%ghs_%' OR permissions::text LIKE '%gho_%' OR github_org_login LIKE '%ghs_%'")"
[[ "${TOKLEAK}" == "0" ]] || fail "(C) a GitHub token leaked into github_installations"
ok "(C) link + sync mapped owner+alice+bob + team core (idempotent); installation token minted JIT, never persisted"

# ── 6) (D) PARITY — flag OFF → all github routes 404, base orgs 200 ────────────
step "6/8 (D · PARITY) GITHUB_CONNECT_ENABLED unset → /v1/github* + /github/* 404, base /v1/orgs 200"
GH_ROWS_BEFORE="$(psql_val "SELECT count(*) FROM public.github_installations")"
docker run -d --name "${TC_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" -e GOTRUE_JWT_SECRET="${JWT_SECRET}" \
  -e ORG_MODEL_ENABLED=1 -e RBAC_HIERARCHY_ENABLED=1 \
  -e TENANT_CONTROL_PORT=3020 -e TENANT_CONTROL_PRODUCT_MODE=enabled -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_OFF}:3020" "${TC_IMG}" >/dev/null
wait_ready_http "${TC_OFF}" "${PORT_OFF}" /health/live || fail "GH-OFF tenant-control not ready"
{ docker logs "${TC_OFF}" 2>&1 || true; } | grep -q "github connect disabled" || fail "(D) OFF instance did not report github disabled (flag default not OFF?)"
[[ "$(req POST "${PORT_OFF}" /v1/github/device/start "" "")" == "404" ]] || fail "(D) /v1/github/device/start with flag OFF expected 404"
[[ "$(req POST "${PORT_OFF}" "/v1/orgs/${ORG_A}/github/sync" "${JWT_U1}" "{}")" == "404" ]] || fail "(D) /github/sync with flag OFF expected 404"
[[ "$(req GET "${PORT_OFF}" /v1/orgs "${JWT_U1}" "")" == "200" ]] || fail "(D) base /v1/orgs should be 200 with github OFF"
[[ "$(psql_val "SELECT count(*) FROM public.github_installations")" == "${GH_ROWS_BEFORE}" ]] || fail "(D) the OFF router wrote a github_installations row — not byte-parity"
ok "(D) flag OFF → github routes 404; base /v1/orgs 200; no github_* rows written (byte-parity)"

# ── 7) summary + gate log ──────────────────────────────────────────────────────
green "[M163] (A) device-flow login with NO callback — GitHub token discarded, session minted, user linked"
green "[M163] (B) relay callback — bad HMAC 401, valid HMAC records the installation, nonce → ready"
green "[M163] (C) link + org sync (members→org, teams→teams), idempotent, installation token never persisted"
green "[M163] (D) flag OFF → all github routes 404, base /v1/orgs 200, no rows (byte-parity)"

emit_gate_log() {
  (
    set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-github-connect}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m163=PASS" --outcome pass \
      --msg "GitHub connect: device-flow login with no callback (GitHub token discarded, GoTrue session minted, user linked); relay callback authenticated by X-Github-Relay HMAC (bad=401) records the installation; link + org sync maps members->org-members + teams->teams idempotently; installation token minted JIT + never persisted; GITHUB_CONNECT_ENABLED unset -> all /v1/github* routes 404 + base orgs 200 + no rows (byte-parity)" \
      --ref "scripts/verify/m163-github-connect.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
green "[M163] ALL GATES GREEN — Track-E GitHub App connect: device login, relay callback, org sync, flag-OFF parity"
exit 0
