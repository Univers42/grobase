#!/usr/bin/env bash
# **************************************************************************** #
#  hambooking-tenant.sh — provision the HamBooking app on Grobase (MariaDB)   #
#                                                                              #
#  Backs the java-dam-baas "HamBooking" app with a Grobase (tenant, custom     #
#  entitlement, mariadb mount, API key, GoTrue admin) bundle and KEEPS it      #
#  (idempotent re-runs reuse the key + mount). The mount declares              #
#  shared_resources=[services,carvers] so those catalog tables skip            #
#  owner-scoping (F1 per-table isolation); users/reservations/notifications    #
#  stay owner-scoped (a CLIENT reads only their own profile row — no PII       #
#  firehose), and an `admin` JWT reads across owners (F2 admin bypass).        #
#                                                                              #
#  Targets the RECOVERED MariaDB container (mini-baas-mysql) — it CREATES a    #
#  NEW database `hambooking` inside it and NEVER touches mini_baas / ops.       #
#                                                                              #
#  State lands in .hambooking-tenant.env at the repo root (gitignored) and a   #
#  frontend baas.properties is emitted for the java-dam-baas app.              #
# **************************************************************************** #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/service-auth.sh
source "${SCRIPT_DIR}/../lib/service-auth.sh"
# shellcheck source=../lib/lib-live-tenant.sh
source "${SCRIPT_DIR}/../lib/lib-live-tenant.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATE_ENV="${REPO_ROOT}/.hambooking-tenant.env"
SCHEMA_FILE="${HB_SCHEMA_FILE:-/home/dlesieur/Documents/java-dam-baas/database/schema.grobase.sql}"
PROPS_FILE="${HB_PROPS_FILE:-/home/dlesieur/Documents/java-dam-baas/frontend/frontend/src/main/resources/baas.properties}"
MYSQL_CTN="mini-baas-mysql"
MYSQL_NET_HOST="mysql" # in-network alias the data plane dials (docker inspect: aliases=[mini-baas-mysql mysql])
HB_DB="hambooking"
MOUNT_NAME="hambooking-db"
TENANT_SLUG="hambooking"
ADMIN_EMAIL="admin@hambooking.com"
ADMIN_PASSWORD="HamBooking#2026"
NODE_IMAGE="${NODE_IMAGE:-node:20-alpine}"

cyan() { printf '\033[0;36m[hambooking-tenant] %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[hambooking-tenant] FAIL: %s\033[0m\n' "$*" >&2
  exit 1
}

# mint_jwt SECRET SUB — HS256 realtime WS token (role authenticated, 30 days).
mint_jwt() {
  docker run --rm --network none -e JWT_SECRET="$1" -e JWT_SUB="$2" "${NODE_IMAGE}" node -e '
const { createHmac } = require("node:crypto");
const b64u = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const head = b64u({ alg: "HS256", typ: "JWT" });
const body = b64u({ iss: "supabase", sub: process.env.JWT_SUB, role: "authenticated",
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
[[ -n "${SERVICE_TOKEN}" && -n "${ANON_KEY}" && -n "${SERVICE_KEY}" ]] || fail "stack secrets not found"

# MariaDB creds from the recovered container (root for DDL, app user for the DSN).
MY_ROOT_PW="$(_lt_env "${MYSQL_CTN}" MYSQL_ROOT_PASSWORD)"; MY_ROOT_PW="${MY_ROOT_PW:-mysqlroot}"
MY_APP_USER="$(_lt_env "${MYSQL_CTN}" MYSQL_USER)"; MY_APP_USER="${MY_APP_USER:-mini_baas}"
MY_APP_PW="$(_lt_env "${MYSQL_CTN}" MYSQL_PASSWORD)"; MY_APP_PW="${MY_APP_PW:-mini_baas_pw}"

# ── 1) database + schema (inside the recovered MariaDB, never touch mini_baas/ops) ──
cyan "ensuring database '${HB_DB}' on ${MYSQL_CTN} (recovered container — only CREATE)"
docker exec "${MYSQL_CTN}" mariadb -uroot -p"${MY_ROOT_PW}" \
  -e "CREATE DATABASE IF NOT EXISTS ${HB_DB} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null \
  || fail "create database ${HB_DB} failed"
cyan "granting app user '${MY_APP_USER}' on ${HB_DB}"
docker exec "${MYSQL_CTN}" mariadb -uroot -p"${MY_ROOT_PW}" \
  -e "GRANT ALL PRIVILEGES ON ${HB_DB}.* TO '${MY_APP_USER}'@'%'; FLUSH PRIVILEGES;" 2>/dev/null \
  || fail "grant on ${HB_DB} failed"
[[ -f "${SCHEMA_FILE}" ]] || fail "schema file missing: ${SCHEMA_FILE}"
cyan "applying schema from $(basename "${SCHEMA_FILE}")"
docker exec -i "${MYSQL_CTN}" mariadb -uroot -p"${MY_ROOT_PW}" "${HB_DB}" <"${SCHEMA_FILE}" 2>/dev/null \
  || fail "schema apply failed"
cyan "enabling event scheduler (for evt_reservation_rollover)"
docker exec "${MYSQL_CTN}" mariadb -uroot -p"${MY_ROOT_PW}" \
  -e "SET GLOBAL event_scheduler=ON;" 2>/dev/null || cyan "WARN: could not enable event_scheduler (non-fatal)"

# ── 2) tenant ─────────────────────────────────────────────────────────────────
cyan "ensuring tenant '${TENANT_SLUG}'"
tbody="{\"id\":\"${TENANT_SLUG}\",\"name\":\"HamBooking\"}"
svc_auth POST /v1/tenants "${tbody}"
code=$(curl -s -o /tmp/hb-tenant.json -w '%{http_code}' -X POST "${TC_URL}/v1/tenants" \
  "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${tbody}")
[[ "${code}" == "201" || "${code}" == "409" ]] || fail "tenant create (${code}): $(cat /tmp/hb-tenant.json)"

# Enterprise ceiling so the operator entitlement (mariadb + realtime) is in-bounds.
pbody='{"plan":"enterprise"}'
svc_auth PATCH "/v1/tenants/${TENANT_SLUG}" "${pbody}"
curl -s -o /dev/null -X PATCH "${TC_URL}/v1/tenants/${TENANT_SLUG}" \
  "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${pbody}" || true

# ── 3) custom entitlement via the builder OPERATOR route (BUILDER_ENABLED) ────
cyan "setting custom entitlement (engines=[mariadb], read/write/upsert, +realtime)"
ebody='{"ceiling_plan":"enterprise","status":"active","entitlement":{"label":"hambooking","engines":["mariadb"],"capabilities":{"read":true,"write":true,"upsert":true},"addons":["realtime"]}}'
svc_auth PUT "/v1/tenants/${TENANT_SLUG}/entitlement" "${ebody}"
code=$(curl -s -o /tmp/hb-ent.json -w '%{http_code}' -X PUT \
  "${TC_URL}/v1/tenants/${TENANT_SLUG}/entitlement" \
  "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${ebody}")
[[ "${code}" == "200" ]] || cyan "WARN: entitlement set returned ${code}: $(head -c 200 /tmp/hb-ent.json) (continuing — tenant is enterprise-tier already)"

# ── 4) API key + mariadb mount with shared_resources — reuse if still valid ───
API_KEY=""; KEY_ID=""; DB_ID=""
if [[ -f "${STATE_ENV}" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_ENV}"
  API_KEY="${HB_API_KEY:-}"; KEY_ID="${HB_KEY_ID:-}"; DB_ID="${HB_DB_ID:-}"
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
  cyan "minting API key (scopes read,write)"
  kbody='{"name":"hambooking-app","scopes":["read","write"]}'
  svc_auth POST "/v1/tenants/${TENANT_SLUG}/keys" "${kbody}"
  code=$(curl -s -o /tmp/hb-key.json -w '%{http_code}' -X POST \
    "${TC_URL}/v1/tenants/${TENANT_SLUG}/keys" \
    "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${kbody}")
  [[ "${code}" == "201" ]] || fail "key mint (${code}): $(cat /tmp/hb-key.json)"
  API_KEY="$(_lt_json_field key </tmp/hb-key.json)"
  KEY_ID="$(_lt_json_field id </tmp/hb-key.json)"
  [[ "${API_KEY}" == mbk_* ]] || fail "minted key has unexpected shape"

  cyan "registering mariadb mount '${MOUNT_NAME}' → ${HB_DB} (shared_resources=services,carvers)"
  mbody="{\"engine\":\"mariadb\",\"name\":\"${MOUNT_NAME}\",\"connection_string\":\"mysql://${MY_APP_USER}:${MY_APP_PW}@${MYSQL_NET_HOST}:3306/${HB_DB}\",\"shared_resources\":[\"services\",\"carvers\"]}"
  code=$(curl -s -o /tmp/hb-mount.json -w '%{http_code}' -X POST \
    "${KONG_URL}/admin/v1/databases" \
    -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${TENANT_SLUG}" \
    -H 'Content-Type: application/json' -d "${mbody}")
  if [[ "${code}" == "201" ]]; then
    DB_ID="$(_lt_json_field id </tmp/hb-mount.json)"
  elif [[ "${code}" == "409" && -n "${DB_ID}" ]]; then
    cyan "mount already registered, keeping ${DB_ID}"
  else
    fail "mount register (${code}): $(cat /tmp/hb-mount.json)"
  fi
  [[ -n "${DB_ID}" ]] || fail "no mount id"
fi

# ── 5) GoTrue admin user (role=admin) + users profile row ────────────────────
cyan "ensuring GoTrue admin '${ADMIN_EMAIL}' (role=admin)"
ADMIN_SUB=""
code=$(curl -s -o /tmp/hb-admin.json -w '%{http_code}' -X POST "${KONG_URL}/auth/v1/admin/users" \
  -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${SERVICE_KEY}" -H 'Content-Type: application/json' \
  -d "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASSWORD}\",\"role\":\"admin\",\"email_confirm\":true}")
if [[ "${code}" == "200" || "${code}" == "201" ]]; then
  ADMIN_SUB="$(_lt_json_field id </tmp/hb-admin.json)"
else
  # Already exists (422) → page through the GoTrue admin list to find it by email.
  # GoTrue paginates and the instance is shared across every app, so the admin is
  # rarely on page 1 — walk pages until found or a page comes back empty.
  page=1
  while [[ -z "${ADMIN_SUB}" && "${page}" -le 100 ]]; do
    curl -s -o /tmp/hb-admin-list.json \
      "${KONG_URL}/auth/v1/admin/users?page=${page}&per_page=200" \
      -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${SERVICE_KEY}" || true
    _res="$(ADMIN_EMAIL="${ADMIN_EMAIL}" python3 -c '
import json,os
try:
  us=json.load(open("/tmp/hb-admin-list.json")).get("users",[])
  sub=next((u.get("id","") for u in us if u.get("email")==os.environ["ADMIN_EMAIL"]),"")
  print(sub, len(us))
except Exception: print("",0)' 2>/dev/null)"
    ADMIN_SUB="${_res%% *}"
    [[ "${_res##* }" == "0" ]] && break
    page=$((page+1))
  done
fi
[[ -n "${ADMIN_SUB}" ]] || fail "could not create/find GoTrue admin (${code}): $(head -c 200 /tmp/hb-admin.json)"
cyan "admin sub=${ADMIN_SUB:0:8}…"

cyan "inserting users profile row for the admin (owner_id=user:sub, auth_id=sub, role=ADMIN)"
docker exec "${MYSQL_CTN}" mariadb -uroot -p"${MY_ROOT_PW}" "${HB_DB}" 2>/dev/null -e "
INSERT INTO users (owner_id,auth_id,dni,first_name,last_name,email,phone,role,is_active)
VALUES ('user:${ADMIN_SUB}','${ADMIN_SUB}','12345678A','System','Administrator','${ADMIN_EMAIL}','600000000','ADMIN',1)
ON DUPLICATE KEY UPDATE owner_id=VALUES(owner_id), auth_id=VALUES(auth_id), is_active=1;" \
  || cyan "WARN: admin profile insert returned non-zero (may already exist)"

# ── 6) realtime WS token + frontend config + state ───────────────────────────
RT_TOKEN=""
if [[ -n "${RT_JWT_SECRET}" ]]; then
  RT_TOKEN="$(mint_jwt "${RT_JWT_SECRET}" hambooking-app)"
fi

cyan "writing frontend baas.properties → ${PROPS_FILE}"
mkdir -p "$(dirname "${PROPS_FILE}")"
cat >"${PROPS_FILE}" <<EOF
# generated by scripts/seed/hambooking-tenant.sh — $(date -Iseconds)
baas.url=http://127.0.0.1:${kong_port}
baas.dbId=${DB_ID}
baas.anonKey=${ANON_KEY}
baas.tenantId=${TENANT_SLUG}
EOF

cat >"${STATE_ENV}" <<EOF
# generated by scripts/seed/hambooking-tenant.sh — $(date -Iseconds)
HB_TENANT_SLUG=${TENANT_SLUG}
HB_API_KEY=${API_KEY}
HB_KEY_ID=${KEY_ID}
HB_DB_ID=${DB_ID}
HB_DB_NAME=${HB_DB}
HB_KONG_URL=${KONG_URL}
HB_ANON_APIKEY=${ANON_KEY}
HB_SERVICE_APIKEY=${SERVICE_KEY}
HB_ADMIN_EMAIL=${ADMIN_EMAIL}
HB_ADMIN_PASSWORD=${ADMIN_PASSWORD}
HB_ADMIN_SUB=${ADMIN_SUB}
HB_REALTIME_TOKEN=${RT_TOKEN}
EOF
cyan "DONE: tenant=${TENANT_SLUG} mount=${DB_ID} (state → ${STATE_ENV})"
