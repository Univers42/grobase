#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m231-authz-tuples.sh — relationship authz (AUTHZ_ENABLED): who may call it, #
#  that one app never sees another's tuples, and that a revoke bites at once.  #
#                                                                              #
#    A throwaway postgres (tenant tables 005+032, the authz schema) and the    #
#    REAL tenant-control binary built from this tree, run twice: flag off and  #
#    on. Two tenants (A, B) each get an API key. Asserted over HTTP:           #
#      flag off -> 404 (route absent, not refused) · a valid GoTrue JWT -> 401 #
#      · key without authz:read/authz:write -> 403 · body "app"/"app_id" ->400 #
#      · B's key never sees A's tuples (C-isolation) · a revoke is visible to  #
#      the very next check (C5) · a model change that orphans tuples -> 409.   #
#    Asserted in SQL and through PostgREST (schema exposed on purpose): anon   #
#    and authenticated get 42501 on authz.*, tables and the write primitive.   #
#                                                                              #
#  --self-test plants five bugs one at a time in a scratch copy of the source  #
#  (JWT accepted, scope ignored, app filter dropped, route always mounted,    #
#  anon granted the authz schema) and requires THIS gate to fail on each:     #
#  a negative is only proven by failing.                                       #
#                                                                              #
#  Needs docker, curl, jq, openssl and the images below locally; no stack.     #
#  AUTHZ_SCHEMA_SQL=<file> applies another schema than 091_authz_tuples.sql.   #
#  Caveat: containers use --network host (docker0 is missing on the build      #
#  hosts), so M231_PG_PORT / M231_TC_PORT / M231_REST_PORT must be free; the   #
#  tenant-control image is alpine + a static binary, not the production image. #
#                                                                              #
# **************************************************************************** #
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${M231_SRC:-${ROOT}/src/control-plane}"
MIG="${ROOT}/scripts/migrations/postgresql"
SCHEMA_SQL="${AUTHZ_SCHEMA_SQL:-${MIG}/091_authz_tuples.sql}"
PG_IMAGE="${M231_PG_IMAGE:-postgres:16-alpine}"
TC_IMAGE="${M231_TC_IMAGE:-alpine:latest}"
REST_IMAGE="${M231_REST_IMAGE:-ghcr.io/univers42/grobase-postgrest:latest}"
GO_IMG="${GO_IMG:-$(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -m1 'golang:1\.26' || echo golang:1.26-bookworm)}"
PG_PORT="${M231_PG_PORT:-55431}"
TC_PORT="${M231_TC_PORT:-19231}"
REST_PORT="${M231_REST_PORT:-19232}"
PGPW="pw-$$"
SVC_TOKEN="m231-service-token-$$"
JWT_SECRET="m231-gotrue-jwt-secret-0123456789abcdef-$$"
ISSUER="http://m231.invalid"
PG="authz-b-m231-pg-$$"
CLI="authz-b-m231-cli-$$"
TC="authz-b-m231-tc-$$"
REST="authz-b-m231-rest-$$"
WORK="$(mktemp -d)"
DSN="postgres://postgres:${PGPW}@127.0.0.1:${PG_PORT}/postgres"

ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M231] FAIL: %s\033[0m\n' "$*" >&2
  exit 1
}
cleanup() {
  docker rm -fv "${PG}" "${TC}" "${REST}" "${CLI}" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

# Plants one bug in a scratch copy of the source and requires the gate to fail
# with the named check. Caveat: greps the gate's own FAIL text, so renaming a
# message without updating this table makes a mutation "survive" noisily.
self_test() {
  local name file from to expect scratch out
  while IFS='~' read -r name file from to expect; do
    scratch="${WORK}/mut-${name}"
    mkdir -p "${scratch}" && cp -r "${SRC}/." "${scratch}/"
    # A mig/ path plants the bug in a copy of a migration, handed over as AUTHZ_SCHEMA_SQL.
    local orig="${SRC}/${file}" planted="${scratch}/${file}" schema="${SCHEMA_SQL}"
    if [ "${file#mig/}" != "${file}" ]; then
      orig="${MIG}/${file#mig/}" planted="${scratch}/${file#mig/}" schema="${planted}"
      cp "${orig}" "${planted}"
    fi
    sed -i "s#${from}#${to}#" "${planted}"
    cmp -s "${orig}" "${planted}" && fail "self-test ${name}: the edit changed nothing"
    out="$(M231_SRC="${scratch}" AUTHZ_SCHEMA_SQL="${schema}" bash "$0" 2>&1 </dev/null)" && fail "self-test ${name}: gate PASSED with the bug planted"
    grep -q "${expect}" <<<"${out}" || fail "self-test ${name}: failed, but not on '${expect}': $(tail -3 <<<"${out}")"
    ok "mutation ${name}: gate fails on '${expect}'"
  done <<'MUT'
jwt-accepted~internal/tenants/authenticator.go~^func (a \*SelfAuthenticator) AuthenticateAPIKey(w http.ResponseWriter, r \*http.Request) (tenantID string, scopes \[\]string, ok bool) {~&\n\treturn a.Authenticate(w, r)~JWT
scope-ignored~internal/authz/handler.go~if s == want || s == "admin" {~if s == want || s == "admin" || true {~missing scope
app-filter-dropped~internal/authz/frontier.sql~ON t.app = \$1~ON $1 <> ""~isolation
always-mounted~cmd/tenant-control/mount_authz.go~if !config.EnvBool("AUTHZ_ENABLED") {~if false {~flag off
anon-granted~mig/091_authz_tuples.sql~REVOKE ALL ON SCHEMA authz FROM PUBLIC;~GRANT ALL ON SCHEMA authz TO PUBLIC;#;s#REVOKE ALL ON ALL TABLES IN SCHEMA authz FROM PUBLIC;#GRANT ALL ON ALL TABLES IN SCHEMA authz TO PUBLIC;~grants:
MUT
  printf '\033[1;32mm231 self-test PASS\033[0m — 5/5 planted bugs were caught\n'
}
[ "${1:-}" = "--self-test" ] && {
  self_test
  exit 0
}

# Rootless docker keeps --network host sockets in its own netns, so the host cannot curl
# them: every request goes through a client container in that same netns.
start_client() {
  docker run -d --name "${CLI}" --network host -v "${WORK}:/w" --entrypoint sleep "${GO_IMG}" infinity >/dev/null
}
curl_in() { docker exec -i "${CLI}" curl "$@"; }

# psql inside the container must be told the non-default port.
psql_in() { docker exec -i -e PGPORT="${PG_PORT}" "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q "$@"; }
psql_as() { psql_in -tA -c "SET ROLE $1; $2" 2>&1 || true; }

build_binary() {
  docker run --rm --network host -e CGO_ENABLED=0 -e GOFLAGS=-mod=mod \
    -v "${SRC}:/src" -v "${WORK}:/out" -v mini-baas-gomod:/go/pkg/mod \
    -v mini-baas-gobuild:/root/.cache/go-build -w /src "${GO_IMG}" \
    go build -o /out/tenant-control ./cmd/tenant-control >"${WORK}/build.log" 2>&1 ||
    {
      tail -20 "${WORK}/build.log"
      fail "tenant-control build failed"
    }
}

start_postgres() {
  docker run -d --name "${PG}" --network host -e POSTGRES_PASSWORD="${PGPW}" -e PGPORT="${PG_PORT}" \
    "${PG_IMAGE}" >/dev/null
  local i
  for i in $(seq 1 60); do
    docker exec "${PG}" pg_isready -p "${PG_PORT}" -q 2>/dev/null && return 0
    sleep 0.5
  done
  fail "postgres never became ready"
}

apply_sql() { sed '/^#/d' "$1" | psql_in -f - >/dev/null; }

migrate() {
  psql_in >/dev/null <<'SQL'
CREATE TABLE IF NOT EXISTS public.schema_migrations (version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS text LANGUAGE sql STABLE AS $f$ SELECT current_setting('request.tenant_id', true) $f$;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
DO $r$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role; END IF;
END $r$;
SQL
  apply_sql "${MIG}/005_add_tenant_table.sql"
  apply_sql "${MIG}/032_tenants.sql"
  apply_sql "${SCHEMA_SQL}"
}

# start_tenant_control <authz flag value or empty>
start_tenant_control() {
  docker rm -fv "${TC}" >/dev/null 2>&1 || true
  docker run -d --name "${TC}" --network host -v "${WORK}:/w:ro" \
    -e DATABASE_URL="${DSN}" -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" -e TENANT_CONTROL_PORT="${TC_PORT}" \
    -e TENANT_CONTROL_PRODUCT_MODE=enabled -e GOTRUE_JWT_SECRET="${JWT_SECRET}" -e GOTRUE_JWT_ISSUER="${ISSUER}" \
    ${1:+-e AUTHZ_ENABLED="$1"} "${TC_IMAGE}" /w/tenant-control >/dev/null
  local i
  for i in $(seq 1 60); do
    [ "$(curl_in -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${TC_PORT}/health/live")" = 200 ] && return 0
    docker inspect "${TC}" >/dev/null 2>&1 || break
    sleep 0.5
  done
  docker logs "${TC}" 2>&1 | tail -15
  fail "tenant-control never became ready"
}

CODE=""
# call <method> <path> <key|-> [json]; leaves the status in CODE and the body in ${WORK}/body.
call() {
  local args=(-s -o /w/body -w '%{http_code}' -X "$1" "http://127.0.0.1:${TC_PORT}$2")
  [ "$3" != "-" ] && args+=(-H "X-API-Key: $3")
  [ -n "${4:-}" ] && args+=(-H 'Content-Type: application/json' -d "$4")
  CODE="$(curl_in "${args[@]}")"
}
expect() { # <what> <want status>
  [ "${CODE}" = "$2" ] || fail "$1: want $2, got ${CODE}: $(head -c 300 "${WORK}/body")"
  ok "$1 -> $2"
}
admin() { # <path> <json>
  curl_in -s -X POST "http://127.0.0.1:${TC_PORT}$1" -H "X-Service-Token: ${SVC_TOKEN}" -H 'Content-Type: application/json' -d "$2"
}

provision() { # <slug> <owner uuid> <scopes json> -> prints the key
  admin /v1/tenants "{\"id\":\"$1\",\"name\":\"$1\",\"plan\":\"free\",\"owner_user_id\":\"$2\"}" >/dev/null
  admin "/v1/tenants/$1/keys" "{\"name\":\"k-$$\",\"scopes\":$3}" | jq -r '.key // .api_key // empty'
}

mint_jwt() { # <sub> -> HS256 GoTrue-shaped token
  local b64 h p s
  b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
  h="$(printf '{"alg":"HS256","typ":"JWT"}' | b64)"
  p="$(printf '{"sub":"%s","iss":"%s","exp":%s,"role":"authenticated"}' "$1" "${ISSUER}" "$(($(date +%s) + 3600))" | b64)"
  s="$(printf '%s.%s' "${h}" "${p}" | openssl dgst -sha256 -hmac "${JWT_SECRET}" -binary | b64)"
  printf '%s.%s.%s' "${h}" "${p}" "${s}"
}

MODEL='{"types":{"workspace":{"relations":{"member":{"types":["user"]}}},"page":{"relations":{"owner":{"types":["user"]},"viewer":{"types":["user","workspace#member"]}},"permissions":{"read":{"union":[{"relation":"owner"},{"relation":"viewer"}]}}}}}'
SLIM='{"types":{"page":{"relations":{"owner":{"types":["user"]}},"permissions":{"read":{"relation":"owner"}}}}}'
OWNER_A="11111111-1111-4111-8111-111111111111"
OWNER_B="22222222-2222-4222-8222-222222222222"

allowed() { # <key> <user> <object> -> true|false
  call POST /v1/authz/check "$1" "{\"subject\":\"user:$2\",\"permission\":\"read\",\"object\":\"$3\"}"
  [ "${CODE}" = 200 ] || fail "check: want 200, got ${CODE}: $(head -c 300 "${WORK}/body")"
  jq -r '.allowed' "${WORK}/body"
}
put_tuples() { # <key> <object> <tuples json>
  call POST /v1/authz/tuples "$1" "{\"source\":\"gate\",\"object\":\"$2\",\"tuples\":$3}"
  [ "${CODE}" = 200 ] || fail "tuples write: want 200, got ${CODE}: $(head -c 300 "${WORK}/body")"
}

check_access_rules() {
  call POST /v1/authz/check "${KEY_RW_A}" '{"subject":"user:alice","permission":"read","object":"page:1"}'
  expect "flag off: route is absent" 404
  start_tenant_control 1
  call POST /v1/authz/check - '{}'
  expect "no credential" 401
  call POST /v1/authz/check "$(mint_jwt "${OWNER_A}")" '{}'
  expect "JWT in X-API-Key is refused (JWT)" 401
  CODE="$(curl_in -s -o /w/body -w '%{http_code}' -X POST "http://127.0.0.1:${TC_PORT}/v1/authz/check" \
    -H "Authorization: Bearer $(mint_jwt "${OWNER_A}")" -H 'Content-Type: application/json' -d '{}')"
  expect "a valid GoTrue JWT owning the tenant is refused (JWT)" 401
  call PUT /v1/authz/model "${KEY_RO_A}" "${MODEL}"
  expect "missing scope: read-only key cannot PUT the model" 403
  call POST /v1/authz/check "${KEY_NONE_A}" '{"subject":"user:a","permission":"read","object":"page:1"}'
  expect "missing scope: key without authz:read cannot check" 403
  call PUT /v1/authz/model "${KEY_RW_A}" "${MODEL}"
  expect "PUT model with authz:write" 200
  call POST /v1/authz/check "${KEY_RW_A}" '{"app":"b","subject":"user:a","permission":"read","object":"page:1"}'
  expect "body app is refused" 400
  call POST /v1/authz/tuples "${KEY_RW_A}" '{"app_id":"b","source":"gate","object":"page:1","tuples":[]}'
  expect "body app_id is refused" 400
}

check_isolation_and_revocation() {
  call PUT /v1/authz/model "${KEY_RW_B}" "${MODEL}"
  expect "tenant B PUT model" 200
  put_tuples "${KEY_RW_A}" page:1 '[{"relation":"owner","subject":"user:alice"}]'
  put_tuples "${KEY_RW_B}" page:1 '[{"relation":"owner","subject":"user:bob"}]'
  [ "$(allowed "${KEY_RW_A}" alice page:1)" = true ] || fail "isolation: A's key does not see A's own tuple"
  [ "$(allowed "${KEY_RW_B}" alice page:1)" = false ] || fail "isolation: B's key sees A's tuple"
  [ "$(allowed "${KEY_RW_A}" bob page:1)" = false ] || fail "isolation: A's key sees B's tuple"
  ok "isolation: each key sees only its own app's tuples"
  put_tuples "${KEY_RW_A}" page:1 '[]'
  [ "$(allowed "${KEY_RW_A}" alice page:1)" = false ] || fail "revocation (C5): the check after a revoke still allows"
  ok "revocation is visible to the very next check (C5)"
  put_tuples "${KEY_RW_A}" page:2 '[{"relation":"viewer","subject":"user:carol"}]'
  call PUT /v1/authz/model "${KEY_RW_A}" "${SLIM}"
  expect "model change that orphans tuples" 409
}

check_database_grants() {
  local out role
  for role in anon authenticated; do
    out="$(psql_as "${role}" 'SELECT 1 FROM authz.tuples LIMIT 1')"
    grep -q 'permission denied' <<<"${out}" || fail "grants: ${role} can read authz.tuples: ${out}"
    out="$(psql_as "${role}" "SELECT authz.replace_source_tuples('a','page','1','s','[]'::jsonb)")"
    grep -q 'permission denied' <<<"${out}" || fail "grants: ${role} can run the write primitive: ${out}"
  done
  ok "grants: anon and authenticated are denied (42501) on authz tables and the primitive"
}

check_postgrest_grants() {
  psql_in -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticator') THEN CREATE ROLE authenticator LOGIN PASSWORD '${PGPW}'; END IF; END \$\$; GRANT anon, authenticated TO authenticator;" >/dev/null
  docker run -d --name "${REST}" --network host -e PGRST_DB_URI="postgres://authenticator:${PGPW}@127.0.0.1:${PG_PORT}/postgres" \
    -e PGRST_DB_SCHEMAS=public,authz -e PGRST_DB_ANON_ROLE=anon -e PGRST_JWT_SECRET="${JWT_SECRET}" \
    -e PGRST_SERVER_PORT="${REST_PORT}" "${REST_IMAGE}" >/dev/null
  local i role token url="http://127.0.0.1:${REST_PORT}"
  for i in $(seq 1 60); do
    [ "$(curl_in -s -o /dev/null -w '%{http_code}' "${url}/")" = 200 ] && break
    sleep 0.5
  done
  [ "${i}" -lt 60 ] || {
    docker logs "${REST}" 2>&1 | tail -8
    fail "PostgREST never loaded its schema cache"
  }
  for role in anon authenticated; do
    token=()
    [ "${role}" = authenticated ] && token=(-H "Authorization: Bearer $(mint_jwt "${OWNER_A}")")
    for req in "GET ${url}/tuples|Accept-Profile" "POST ${url}/rpc/replace_source_tuples|Content-Profile"; do
      curl_in -s -X "${req%% *}" "${token[@]}" -H "${req##*|}: authz" -H 'Content-Type: application/json' \
        -d '{"p_app":"a","p_object_type":"page","p_object_id":"1","p_source":"s","p_tuples":[]}' \
        "$(cut -d' ' -f2 <<<"${req%|*}")" >"${WORK}/rest.json"
      jq -e '.code == "42501"' "${WORK}/rest.json" >/dev/null ||
        fail "grants: ${role} via PostgREST (${req%%|*}) not 42501: $(head -c 200 "${WORK}/rest.json")"
    done
  done
  ok "grants: PostgREST (authz schema exposed on purpose) answers 42501 to anon and authenticated"
}

printf '\033[1m── m231: relationship authz ──\033[0m\n'
build_binary
start_client
ok "tenant-control built from ${SRC}"
start_postgres
migrate
ok "postgres up; tenant tables and the authz schema applied (${SCHEMA_SQL##*/})"
start_tenant_control ""
KEY_RW_A="$(provision m231a "${OWNER_A}" '["authz:read","authz:write"]')"
KEY_RO_A="$(admin /v1/tenants/m231a/keys '{"name":"ro","scopes":["authz:read"]}' | jq -r '.key // .api_key // empty')"
KEY_NONE_A="$(admin /v1/tenants/m231a/keys '{"name":"none","scopes":["read"]}' | jq -r '.key // .api_key // empty')"
KEY_RW_B="$(provision m231b "${OWNER_B}" '["authz:read","authz:write"]')"
[ -n "${KEY_RW_A}" ] && [ -n "${KEY_RO_A}" ] && [ -n "${KEY_NONE_A}" ] && [ -n "${KEY_RW_B}" ] || fail "key provisioning failed"
ok "two tenants provisioned; keys: read+write, read-only, no authz scope"
check_access_rules
check_isolation_and_revocation
check_database_grants
check_postgrest_grants
printf '\033[1;32mm231 PASS\033[0m — flag-off 404, JWT 401, scope 403, body app 400, isolation, revocation, 409, 42501 grants\n'
