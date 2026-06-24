#!/usr/bin/env bash
# **************************************************************************** #
#  canagrou-tenant.sh — provision the Canagrou photo-app tenant on Grobase     #
#                                                                              #
#  Replaces Canagrou's PHP+MariaDB backend with a Grobase (tenant, API key,    #
#  postgresql mount) triple and KEEPS it (idempotent re-runs reuse the key):   #
#    - dedicated Postgres database `canagrou` on the stack's own postgres      #
#      (the shared `postgres` DB already has unrelated public.posts/likes)     #
#    - tenant id `canagrou` via tenant-control (201/409 both fine)             #
#    - mbk_ app API key (reused across runs when still valid)                  #
#    - adapter-registry mount `canagrou-db` through Kong /admin/v1/databases   #
#    - the 4 app tables (profiles/posts/likes/comments) applied via psql from  #
#      vendor/Canagrou/sql/grobase-schema.sql                                  #
#    - a `post-images` storage bucket for composed photos                      #
#    - an HS256 realtime WS token + the VITE_BAAS_* env both frontends read    #
#                                                                              #
#  State lands in .canagrou-tenant.env at the repo root so re-runs and the     #
#  m146 gate can source it. Realtime fires via the query-router app-publish    #
#  path (topic table:<dbId>:<table>), so writes through /query/v1 reflect.     #
# **************************************************************************** #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# v1 HMAC service auth — signs tenant-control calls under SERVICE_TOKEN_MODE=hmac.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/service-auth.sh"
# shellcheck source=../lib/lib-live-tenant.sh
source "${SCRIPT_DIR}/../lib/lib-live-tenant.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATE_ENV="${REPO_ROOT}/.canagrou-tenant.env"
SCHEMA_FILE="${REPO_ROOT}/vendor/Canagrou/sql/grobase-schema.sql"
WEB_ENV="${REPO_ROOT}/vendor/Canagrou/web/.env"
MOBILE_ENV="${REPO_ROOT}/vendor/Canagrou/mobile/.env"
PG_CTN="mini-baas-postgres"
CANAGROU_DB="canagrou"
MOUNT_NAME="canagrou-db"
TENANT_SLUG="canagrou"
BUCKET="post-images"
NODE_IMAGE="${NODE_IMAGE:-node:20-alpine}"

cyan() { printf '\033[0;36m[canagrou-tenant] %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[canagrou-tenant] FAIL: %s\033[0m\n' "$*" >&2
  exit 1
}

# mint_jwt SECRET SUB [ROLE] — HS256 JWT (iss=supabase, role=ROLE|authenticated, 30 days)
# signed in a throwaway node container so no host node is required. ROLE defaults to
# authenticated; pass service_role for privileged storage ops (F3 bucket creation).
mint_jwt() {
  docker run --rm --network none -e JWT_SECRET="$1" -e JWT_SUB="$2" -e JWT_ROLE="${3:-authenticated}" "${NODE_IMAGE}" node -e '
const { createHmac } = require("node:crypto");
const b64u = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const head = b64u({ alg: "HS256", typ: "JWT" });
const body = b64u({ iss: "supabase", sub: process.env.JWT_SUB, role: process.env.JWT_ROLE,
  exp: Math.floor(Date.now() / 1000) + 30 * 86400 });
const sig = createHmac("sha256", process.env.JWT_SECRET).update(`${head}.${body}`).digest("base64url");
console.log(`${head}.${body}.${sig}`);'
}

# ── 0) endpoints + secrets from the running stack ────────────────────────────
kong_port="$(_lt_host_port mini-baas-kong 8000/tcp)"
tc_port="$(_lt_host_port mini-baas-tenant-control 3022/tcp)"
[[ -n "${kong_port}" && -n "${tc_port}" ]] || fail "mini-baas stack not running (kong/tenant-control ports)"
KONG_URL="http://127.0.0.1:${kong_port}"
TC_URL="http://127.0.0.1:${tc_port}"
SERVICE_TOKEN="$(_lt_env mini-baas-tenant-control INTERNAL_SERVICE_TOKEN)"
ANON_KEY="$(_lt_env mini-baas-kong KONG_PUBLIC_API_KEY)"
SERVICE_KEY="$(_lt_env mini-baas-kong KONG_SERVICE_API_KEY)"
RT_JWT_SECRET="$(_lt_env mini-baas-realtime REALTIME_JWT_SECRET)"
# Storage requires a verified user JWT (sub→X-User-Id); object keys are
# auto-prefixed with the sub. A public wall needs ONE shared read namespace, so
# every client uses a single app storage identity (sub=canagrou-app) — there is
# no anon/public-bucket GET (S3_PUBLIC_ENDPOINT is unset) so the browser fetches
# images through Kong with this token and blob-URLs them.
STORAGE_JWT_SECRET="$(_lt_env mini-baas-gotrue GOTRUE_JWT_SECRET)"
[[ -n "${STORAGE_JWT_SECRET}" ]] || STORAGE_JWT_SECRET="$(_lt_env mini-baas-storage-router JWT_SECRET)"
[[ -n "${SERVICE_TOKEN}" && -n "${ANON_KEY}" && -n "${SERVICE_KEY}" ]] || fail "stack secrets not found"
[[ -n "${RT_JWT_SECRET}" ]] || fail "REALTIME_JWT_SECRET not found on mini-baas-realtime"
[[ -n "${STORAGE_JWT_SECRET}" ]] || fail "GOTRUE_JWT_SECRET not found (storage identity)"
PG_USER="$(_lt_env "${PG_CTN}" POSTGRES_USER)"; PG_USER="${PG_USER:-postgres}"
PG_PASS="$(_lt_env "${PG_CTN}" POSTGRES_PASSWORD)"; PG_PASS="${PG_PASS:-postgres}"

# ── 1) dedicated database ─────────────────────────────────────────────────────
cyan "ensuring database '${CANAGROU_DB}' on ${PG_CTN}"
docker exec "${PG_CTN}" psql -U "${PG_USER}" -d postgres -tc \
  "SELECT 1 FROM pg_database WHERE datname='${CANAGROU_DB}'" | grep -q 1 ||
  docker exec "${PG_CTN}" psql -U "${PG_USER}" -d postgres -c "CREATE DATABASE ${CANAGROU_DB}" >/dev/null

# ── 2) tenant ─────────────────────────────────────────────────────────────────
cyan "ensuring tenant '${TENANT_SLUG}'"
tbody="{\"id\":\"${TENANT_SLUG}\",\"name\":\"Canagrou\"}"
svc_auth POST /v1/tenants "${tbody}"
code=$(curl -s -o /tmp/canagrou-tenant.json -w '%{http_code}' -X POST "${TC_URL}/v1/tenants" \
  "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${tbody}")
[[ "${code}" == "201" || "${code}" == "409" ]] || fail "tenant create (${code}): $(cat /tmp/canagrou-tenant.json)"

# Put the tenant on the max tier so storage + realtime + every op are unlocked.
pbody='{"plan":"enterprise"}'
svc_auth PATCH "/v1/tenants/${TENANT_SLUG}" "${pbody}"
curl -s -o /dev/null -X PATCH "${TC_URL}/v1/tenants/${TENANT_SLUG}" \
  "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${pbody}" || true

# ── 3) API key — reuse a still-valid key from a previous run ──────────────────
API_KEY=""; KEY_ID=""; DB_ID=""
if [[ -f "${STATE_ENV}" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_ENV}"
  API_KEY="${CANAGROU_API_KEY:-}"; KEY_ID="${CANAGROU_KEY_ID:-}"; DB_ID="${CANAGROU_DB_ID:-}"
fi
key_ok=0
if [[ -n "${API_KEY}" && -n "${DB_ID}" ]]; then
  probe=$(curl -s -o /dev/null -w '%{http_code}' "${KONG_URL}/query/v1/${DB_ID}/schema" \
    -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: ${API_KEY}")
  [[ "${probe}" == "200" ]] && key_ok=1
fi
if [[ "${key_ok}" == "1" ]]; then
  cyan "reusing existing key + mount (${DB_ID})"
else
  cyan "minting API key"
  kbody='{"name":"canagrou-app","scopes":["read","write"]}'
  svc_auth POST "/v1/tenants/${TENANT_SLUG}/keys" "${kbody}"
  code=$(curl -s -o /tmp/canagrou-key.json -w '%{http_code}' -X POST \
    "${TC_URL}/v1/tenants/${TENANT_SLUG}/keys" \
    "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${kbody}")
  [[ "${code}" == "201" ]] || fail "key mint (${code}): $(cat /tmp/canagrou-key.json)"
  API_KEY="$(_lt_json_field key </tmp/canagrou-key.json)"
  KEY_ID="$(_lt_json_field id </tmp/canagrou-key.json)"
  [[ "${API_KEY}" == mbk_* ]] || fail "minted key has unexpected shape"

  cyan "registering mount '${MOUNT_NAME}' → ${CANAGROU_DB} database"
  code=$(curl -s -o /tmp/canagrou-mount.json -w '%{http_code}' -X POST \
    "${KONG_URL}/admin/v1/databases" \
    -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${TENANT_SLUG}" \
    -H 'Content-Type: application/json' \
    -d "{\"engine\":\"postgresql\",\"name\":\"${MOUNT_NAME}\",\"connection_string\":\"postgres://${PG_USER}:${PG_PASS}@postgres:5432/${CANAGROU_DB}\"}")
  if [[ "${code}" == "201" ]]; then
    DB_ID="$(_lt_json_field id </tmp/canagrou-mount.json)"
  elif [[ "${code}" == "409" && -n "${DB_ID}" ]]; then
    cyan "mount already registered, keeping ${DB_ID}"
  else
    fail "mount register (${code}): $(cat /tmp/canagrou-mount.json)"
  fi
  [[ -n "${DB_ID}" ]] || fail "no mount id"
fi

# ── 4) schema (psql — FK + UNIQUE + identity the DDL contract can't express) ──
cyan "applying schema from $(basename "${SCHEMA_FILE}")"
[[ -f "${SCHEMA_FILE}" ]] || fail "schema file missing: ${SCHEMA_FILE}"
docker exec -i "${PG_CTN}" psql -U "${PG_USER}" -d "${CANAGROU_DB}" -v ON_ERROR_STOP=1 -q <"${SCHEMA_FILE}" \
  || fail "schema apply failed"

# ── 5) shared storage identity + bucket for composed photos ──────────────────
cyan "minting shared storage token (sub=canagrou-app)"
STORAGE_TOKEN="$(mint_jwt "${STORAGE_JWT_SECRET}" canagrou-app)"
[[ -n "${STORAGE_TOKEN}" ]] || fail "storage token mint failed"
cyan "ensuring storage bucket '${BUCKET}' (privileged role — F3 bucket-scope)"
BUCKET_ADMIN_TOKEN="$(mint_jwt "${STORAGE_JWT_SECRET}" canagrou-app service_role)"
code=$(curl -s -o /tmp/canagrou-bucket.json -w '%{http_code}' -X POST \
  "${KONG_URL}/storage/v1/bucket/${BUCKET}" \
  -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${BUCKET_ADMIN_TOKEN}" \
  -H 'Content-Type: application/json' -d '{"public":true}')
[[ "${code}" == "200" || "${code}" == "201" || "${code}" == "409" ]] \
  || fail "bucket create (${code}): $(cat /tmp/canagrou-bucket.json)"

# ── 6) realtime WS token (HS256, 30 days) ────────────────────────────────────
cyan "minting realtime WS token"
RT_TOKEN="$(mint_jwt "${RT_JWT_SECRET}" canagrou-app)"
[[ -n "${RT_TOKEN}" ]] || fail "realtime token mint failed"

LIVE_MOUNTS_JSON="[{\"dbId\":\"${DB_ID}\",\"name\":\"${MOUNT_NAME}\",\"engine\":\"postgresql\"}]"

# ── 7) emit the VITE_BAAS_* env for both frontends ───────────────────────────
emit_env() { # $1 path, $2 kong host (127.0.0.1 | 10.0.2.2)
  local path="$1" host="$2"
  mkdir -p "$(dirname "${path}")"
  cat >"${path}" <<EOF
# generated by scripts/seed/canagrou-tenant.sh — $(date -Iseconds)
VITE_BAAS_URL=http://${host}:${kong_port}
VITE_BAAS_KONG_KEY=${ANON_KEY}
VITE_BAAS_API_KEY=${API_KEY}
VITE_BAAS_TENANT_ID=${TENANT_SLUG}
VITE_BAAS_LIVE_MOUNTS=${LIVE_MOUNTS_JSON}
VITE_BAAS_REALTIME_TOKEN=${RT_TOKEN}
VITE_BAAS_STORAGE_BUCKET=${BUCKET}
VITE_BAAS_STORAGE_TOKEN=${STORAGE_TOKEN}
EOF
  cyan "wrote ${path}"
}
emit_env "${WEB_ENV}" "127.0.0.1"
emit_env "${MOBILE_ENV}" "10.0.2.2"

# Browser config for the zero-build static SPA (window.__BAAS__). The web app
# reads this instead of import.meta.env, so no bundler step is required.
WEB_CFG="${REPO_ROOT}/vendor/Canagrou/web/public/baas-config.js"
mkdir -p "$(dirname "${WEB_CFG}")"
cat >"${WEB_CFG}" <<EOF
// generated by scripts/seed/canagrou-tenant.sh — $(date -Iseconds) — DO NOT COMMIT
window.__BAAS__ = {
  url: "http://127.0.0.1:${kong_port}",
  anonKey: "${ANON_KEY}",
  apiKey: "${API_KEY}",
  tenantId: "${TENANT_SLUG}",
  dbId: "${DB_ID}",
  storageBucket: "${BUCKET}",
  storageToken: "${STORAGE_TOKEN}",
  realtimeToken: "${RT_TOKEN}"
};
EOF
cyan "wrote ${WEB_CFG}"

# ── 8) persist state ──────────────────────────────────────────────────────────
cat >"${STATE_ENV}" <<EOF
# generated by scripts/seed/canagrou-tenant.sh — $(date -Iseconds)
CANAGROU_TENANT_SLUG=${TENANT_SLUG}
CANAGROU_API_KEY=${API_KEY}
CANAGROU_KEY_ID=${KEY_ID}
CANAGROU_DB_ID=${DB_ID}
CANAGROU_DB_NAME=${CANAGROU_DB}
CANAGROU_KONG_URL=${KONG_URL}
CANAGROU_ANON_APIKEY=${ANON_KEY}
CANAGROU_SERVICE_APIKEY=${SERVICE_KEY}
CANAGROU_BUCKET=${BUCKET}
EOF
cyan "DONE: tenant=${TENANT_SLUG} mount=${DB_ID} (state → ${STATE_ENV})"
