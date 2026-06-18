#!/usr/bin/env bash
# **************************************************************************** #
#  nimbus-tenant.sh — provision the Nimbus SaaS app on Grobase                #
#                                                                              #
#  A CUSTOM-composed BaaS spanning TWO engines on one tenant:                  #
#    - PostgreSQL `nimbus` db (ACID money model: app_users / accounts / txns / #
#      ledger_entries / subscriptions / invoices) — the transactional plane    #
#    - MongoDB `nimbus` db (messages / content / activity collections) — the   #
#      document plane, NO transactions                                         #
#                                                                              #
#  The tenant carries a CUSTOM entitlement (enterprise ceiling) that turns the #
#  `transactions` capability ON across both engines, so POST /query/v1/txn     #
#  commits/rolls-back atomically on the PG mount.                              #
#                                                                              #
#  Idempotent: re-runs reuse the API key + mounts, re-apply the schema (IF NOT #
#  EXISTS), and converge the demo seed. State lands in .nimbus-tenant.env at   #
#  the repo root (gitignored) and a baas-config.js / .env for the frontend.    #
# **************************************************************************** #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/service-auth.sh
source "${SCRIPT_DIR}/../lib/service-auth.sh"
# shellcheck source=../lib/lib-live-tenant.sh
source "${SCRIPT_DIR}/../lib/lib-live-tenant.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATE_ENV="${REPO_ROOT}/.nimbus-tenant.env"
SCHEMA_FILE="${REPO_ROOT}/vendor/saas/sql/schema.sql"
WEB_CFG="${REPO_ROOT}/vendor/saas/web/public/baas-config.js"
WEB_ENV="${REPO_ROOT}/vendor/saas/web/.env"
PG_CTN="mini-baas-postgres"
MONGO_CTN="mini-baas-mongo"
NIMBUS_DB="nimbus"
PG_MOUNT_NAME="nimbus-pg"
MONGO_MOUNT_NAME="nimbus-mongo"
TENANT_SLUG="nimbus"
ADMIN_EMAIL="admin@nimbus.local"
ADMIN_PASSWORD="Nimbus#2026"

cyan() { printf '\033[0;36m[nimbus-tenant] %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[nimbus-tenant] FAIL: %s\033[0m\n' "$*" >&2
  exit 1
}

urlenc() { python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"; }

# gw_q DBID RESOURCE BODY — gateway CRUD; body→/tmp/nimbus-q.json, echoes status.
gw_q() {
  curl -s -o /tmp/nimbus-q.json -w '%{http_code}' -X POST "${KONG_URL}/query/v1/$1/tables/$2" \
    -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: ${API_KEY}" \
    -H 'Content-Type: application/json' -d "$3"
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
GOTRUE_SERVICE_ROLE="$(_lt_env mini-baas-gotrue SERVICE_ROLE_KEY)"
[[ -n "${GOTRUE_SERVICE_ROLE}" ]] || GOTRUE_SERVICE_ROLE="${SERVICE_KEY}"
[[ -n "${SERVICE_TOKEN}" && -n "${ANON_KEY}" && -n "${SERVICE_KEY}" ]] || fail "stack secrets not found"

PG_USER="$(_lt_env "${PG_CTN}" POSTGRES_USER)"; PG_USER="${PG_USER:-postgres}"
PG_PASS="$(_lt_env "${PG_CTN}" POSTGRES_PASSWORD)"; PG_PASS="${PG_PASS:-postgres}"
MONGO_USER="$(_lt_env "${MONGO_CTN}" MONGO_INITDB_ROOT_USERNAME)"; MONGO_USER="${MONGO_USER:-mongo}"
MONGO_PASS="$(_lt_env "${MONGO_CTN}" MONGO_INITDB_ROOT_PASSWORD)"; MONGO_PASS="${MONGO_PASS:-mongo}"

# ── 1) dedicated PostgreSQL database ─────────────────────────────────────────
cyan "ensuring PostgreSQL database '${NIMBUS_DB}' on ${PG_CTN}"
docker exec "${PG_CTN}" psql -U "${PG_USER}" -d postgres -tc \
  "SELECT 1 FROM pg_database WHERE datname='${NIMBUS_DB}'" | grep -q 1 ||
  docker exec "${PG_CTN}" psql -U "${PG_USER}" -d postgres -c "CREATE DATABASE ${NIMBUS_DB}" >/dev/null

# ── 2) tenant + enterprise plan ──────────────────────────────────────────────
cyan "ensuring tenant '${TENANT_SLUG}'"
tbody="{\"id\":\"${TENANT_SLUG}\",\"name\":\"Nimbus\"}"
svc_auth POST /v1/tenants "${tbody}"
code=$(curl -s -o /tmp/nimbus-tenant.json -w '%{http_code}' -X POST "${TC_URL}/v1/tenants" \
  "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${tbody}")
[[ "${code}" == "201" || "${code}" == "409" ]] || fail "tenant create (${code}): $(cat /tmp/nimbus-tenant.json)"

# Enterprise ceiling unlocks both engines + transactions even if the custom
# entitlement PUT is unavailable (BUILDER_ENABLED off).
pbody='{"plan":"enterprise"}'
svc_auth PATCH "/v1/tenants/${TENANT_SLUG}" "${pbody}"
curl -s -o /dev/null -X PATCH "${TC_URL}/v1/tenants/${TENANT_SLUG}" \
  "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${pbody}" || true

# ── 3) custom entitlement (engines=pg+mongo, transactions ON) ────────────────
cyan "setting custom entitlement (engines=[postgresql,mongodb], +transactions)"
ebody='{"ceiling_plan":"enterprise","status":"active","entitlement":{"label":"nimbus","engines":["postgresql","mongodb"],"capabilities":{"read":true,"write":true,"insert":true,"update":true,"delete":true,"upsert":true,"batch":true,"aggregate":true,"transactions":true},"limits":{"rps":250,"burst":500,"max_rows":1000,"quota.query.count":5000000},"max_mounts":2}}'
svc_auth PUT "/v1/tenants/${TENANT_SLUG}/entitlement" "${ebody}"
code=$(curl -s -o /tmp/nimbus-ent.json -w '%{http_code}' -X PUT \
  "${TC_URL}/v1/tenants/${TENANT_SLUG}/entitlement" \
  "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${ebody}")
[[ "${code}" == "200" ]] || cyan "WARN: entitlement set returned ${code}: $(head -c 200 /tmp/nimbus-ent.json) (continuing — tenant is enterprise-tier, which unlocks both engines + txns)"

# ── 4) API key + BOTH mounts — reuse if still valid ──────────────────────────
API_KEY=""; KEY_ID=""; PG_DB_ID=""; MONGO_DB_ID=""
if [[ -f "${STATE_ENV}" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_ENV}"
  API_KEY="${NIMBUS_API_KEY:-}"; KEY_ID="${NIMBUS_KEY_ID:-}"
  PG_DB_ID="${NIMBUS_PG_DB_ID:-}"; MONGO_DB_ID="${NIMBUS_MONGO_DB_ID:-}"
fi
key_ok=0
if [[ -n "${API_KEY}" && -n "${PG_DB_ID}" && -n "${MONGO_DB_ID}" ]]; then
  p1=$(curl -s -o /dev/null -w '%{http_code}' "${KONG_URL}/query/v1/${PG_DB_ID}/schema" \
    -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: ${API_KEY}")
  p2=$(curl -s -o /dev/null -w '%{http_code}' "${KONG_URL}/query/v1/${MONGO_DB_ID}/schema" \
    -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: ${API_KEY}")
  [[ "${p1}" == "200" && "${p2}" == "200" ]] && key_ok=1
fi

# register_mount NAME ENGINE DSN — POST /admin/v1/databases; echoes mount id
register_mount() {
  local code
  code=$(curl -s -o /tmp/nimbus-mount.json -w '%{http_code}' -X POST \
    "${KONG_URL}/admin/v1/databases" \
    -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${TENANT_SLUG}" \
    -H 'Content-Type: application/json' \
    -d "{\"engine\":\"$2\",\"name\":\"$1\",\"connection_string\":\"$3\"}")
  if [[ "${code}" == "201" ]]; then
    _lt_json_field id </tmp/nimbus-mount.json
  elif [[ "${code}" == "409" ]]; then
    curl -fsS "${KONG_URL}/admin/v1/databases" \
      -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${TENANT_SLUG}" |
      python3 -c "import json,sys;rows=json.load(sys.stdin);print(next(r['id'] for r in rows if r.get('name')=='$1'))"
  else
    fail "mount $1 register failed (${code}): $(cat /tmp/nimbus-mount.json)"
  fi
}

if [[ "${key_ok}" == "1" ]]; then
  cyan "reusing existing key + mounts (pg=${PG_DB_ID} mongo=${MONGO_DB_ID})"
else
  cyan "minting API key (scopes read,write)"
  kbody='{"name":"nimbus-app","scopes":["read","write"]}'
  svc_auth POST "/v1/tenants/${TENANT_SLUG}/keys" "${kbody}"
  code=$(curl -s -o /tmp/nimbus-key.json -w '%{http_code}' -X POST \
    "${TC_URL}/v1/tenants/${TENANT_SLUG}/keys" \
    "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${kbody}")
  [[ "${code}" == "201" ]] || fail "key mint (${code}): $(cat /tmp/nimbus-key.json)"
  API_KEY="$(_lt_json_field key </tmp/nimbus-key.json)"
  KEY_ID="$(_lt_json_field id </tmp/nimbus-key.json)"
  [[ "${API_KEY}" == mbk_* ]] || fail "minted key has unexpected shape"

  cyan "registering PostgreSQL mount '${PG_MOUNT_NAME}' → ${NIMBUS_DB}"
  PG_DB_ID="$(register_mount "${PG_MOUNT_NAME}" postgresql \
    "postgres://$(urlenc "${PG_USER}"):$(urlenc "${PG_PASS}")@postgres:5432/${NIMBUS_DB}")"
  cyan "registering MongoDB mount '${MONGO_MOUNT_NAME}' → ${NIMBUS_DB}"
  MONGO_DB_ID="$(register_mount "${MONGO_MOUNT_NAME}" mongodb \
    "mongodb://$(urlenc "${MONGO_USER}"):$(urlenc "${MONGO_PASS}")@mongo:27017/${NIMBUS_DB}?authSource=admin")"
  [[ -n "${PG_DB_ID}" && -n "${MONGO_DB_ID}" ]] || fail "mount registration returned empty ids"
fi
cyan "mounts: pg=${PG_DB_ID} mongo=${MONGO_DB_ID}"

# ── 5) apply the PostgreSQL schema (idempotent) ──────────────────────────────
cyan "applying schema from $(basename "${SCHEMA_FILE}")"
[[ -f "${SCHEMA_FILE}" ]] || fail "schema file missing: ${SCHEMA_FILE}"
docker exec -i "${PG_CTN}" psql -U "${PG_USER}" -d "${NIMBUS_DB}" -v ON_ERROR_STOP=1 -q <"${SCHEMA_FILE}" \
  || fail "schema apply failed"

# ── 6) GoTrue admin user (role=admin) + an app_users row ─────────────────────
cyan "ensuring GoTrue admin '${ADMIN_EMAIL}' (role=admin)"
ADMIN_SUB=""
code=$(curl -s -o /tmp/nimbus-admin.json -w '%{http_code}' -X POST "${KONG_URL}/auth/v1/admin/users" \
  -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${GOTRUE_SERVICE_ROLE}" -H 'Content-Type: application/json' \
  -d "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASSWORD}\",\"role\":\"admin\",\"email_confirm\":true}")
if [[ "${code}" == "200" || "${code}" == "201" ]]; then
  ADMIN_SUB="$(_lt_json_field id </tmp/nimbus-admin.json)"
else
  curl -s -o /tmp/nimbus-admin-list.json "${KONG_URL}/auth/v1/admin/users" \
    -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${GOTRUE_SERVICE_ROLE}" || true
  ADMIN_SUB="$(python3 -c '
import json
try:
  d=json.load(open("/tmp/nimbus-admin-list.json"))
  for u in d.get("users",[]):
    if u.get("email")=="'"${ADMIN_EMAIL}"'": print(u.get("id","")); break
except Exception: pass' 2>/dev/null)"
fi
[[ -n "${ADMIN_SUB}" ]] || fail "could not create/find GoTrue admin (${code}): $(head -c 200 /tmp/nimbus-admin.json)"
cyan "admin sub=${ADMIN_SUB:0:8}…"

# ── 7) demo seed via the gateway (idempotent — skip if app_users already seeded) ──
seeded=0
gw_q "${PG_DB_ID}" app_users '{"op":"list","filter":{"id":{"$eq":"'"${ADMIN_SUB}"'"}}}' >/dev/null 2>&1 || true
grep -q "\"id\":\"${ADMIN_SUB}\"" /tmp/nimbus-q.json 2>/dev/null && seeded=1
if [[ "${seeded}" == "1" ]]; then
  cyan "demo data already present — skipping seed (idempotent)"
else
  cyan "seeding demo data through the gateway"
  # app_users — the admin + two customers + one staff.
  gw_q "${PG_DB_ID}" app_users "{\"op\":\"insert\",\"data\":{\"id\":\"${ADMIN_SUB}\",\"email\":\"${ADMIN_EMAIL}\",\"name\":\"Nimbus Admin\",\"role\":\"admin\"}}" >/dev/null
  gw_q "${PG_DB_ID}" app_users '{"op":"insert","data":{"id":"nimbus-cust-1","email":"alice@nimbus.local","name":"Alice Customer","role":"customer"}}' >/dev/null
  gw_q "${PG_DB_ID}" app_users '{"op":"insert","data":{"id":"nimbus-cust-2","email":"bob@nimbus.local","name":"Bob Customer","role":"customer"}}' >/dev/null
  gw_q "${PG_DB_ID}" app_users '{"op":"insert","data":{"id":"nimbus-staff-1","email":"carol@nimbus.local","name":"Carol Staff","role":"staff"}}' >/dev/null

  # accounts — order matters: id 1 customer, id 2 revenue, id 3 fees.
  gw_q "${PG_DB_ID}" accounts '{"op":"insert","data":{"owner_user_id":"nimbus-cust-1","kind":"customer","balance_cents":100000,"currency":"USD"}}' >/dev/null
  gw_q "${PG_DB_ID}" accounts '{"op":"insert","data":{"kind":"revenue","balance_cents":0,"currency":"USD"}}' >/dev/null
  gw_q "${PG_DB_ID}" accounts '{"op":"insert","data":{"kind":"fees","balance_cents":0,"currency":"USD"}}' >/dev/null

  # subscription + invoice for the first customer.
  gw_q "${PG_DB_ID}" subscriptions '{"op":"insert","data":{"user_id":"nimbus-cust-1","plan":"pro","amount_cents":2999,"currency":"USD","status":"active"}}' >/dev/null
  SUB_ID="$(python3 -c 'import json;d=json.load(open("/tmp/nimbus-q.json"));print(d["rows"][0]["id"])' 2>/dev/null || echo "")"
  gw_q "${PG_DB_ID}" invoices "{\"op\":\"insert\",\"data\":{\"subscription_id\":${SUB_ID:-null},\"user_id\":\"nimbus-cust-1\",\"amount_cents\":2999,\"currency\":\"USD\",\"status\":\"open\"}}" >/dev/null

  # Mongo: messages (open + closed), a settings content doc, an activity doc.
  gw_q "${MONGO_DB_ID}" messages '{"op":"insert","data":{"subject":"Welcome to Nimbus","body":"Thanks for joining.","status":"open"}}' >/dev/null
  gw_q "${MONGO_DB_ID}" messages '{"op":"insert","data":{"subject":"Resolved ticket","body":"Closed by staff.","status":"closed"}}' >/dev/null
  gw_q "${MONGO_DB_ID}" content '{"op":"upsert","filter":{"key":"site.settings"},"data":{"key":"site.settings","type":"settings","value":{"siteName":"Nimbus","supportEmail":"support@nimbus.local"}}}' >/dev/null
  gw_q "${MONGO_DB_ID}" activity '{"op":"insert","data":{"action":"tenant.provisioned","actor":"system","detail":"nimbus seeded"}}' >/dev/null
  cyan "demo data seeded"
fi

# ── 8) emit frontend config + state ──────────────────────────────────────────
cyan "writing frontend config"
mkdir -p "$(dirname "${WEB_CFG}")"
cat >"${WEB_CFG}" <<EOF
// generated by scripts/seed/nimbus-tenant.sh — $(date -Iseconds) — DO NOT COMMIT
window.__BAAS__ = {
  url: "${KONG_URL}",
  anonKey: "${ANON_KEY}",
  apiKey: "${API_KEY}",
  tenantId: "${TENANT_SLUG}",
  pgDbId: "${PG_DB_ID}",
  mongoDbId: "${MONGO_DB_ID}"
};
EOF

mkdir -p "$(dirname "${WEB_ENV}")"
cat >"${WEB_ENV}" <<EOF
# generated by scripts/seed/nimbus-tenant.sh — $(date -Iseconds)
VITE_BAAS_URL=${KONG_URL}
VITE_BAAS_KONG_KEY=${ANON_KEY}
VITE_BAAS_API_KEY=${API_KEY}
VITE_BAAS_TENANT_ID=${TENANT_SLUG}
VITE_BAAS_PG_DB_ID=${PG_DB_ID}
VITE_BAAS_MONGO_DB_ID=${MONGO_DB_ID}
EOF

cat >"${STATE_ENV}" <<EOF
# generated by scripts/seed/nimbus-tenant.sh — $(date -Iseconds)
NIMBUS_TENANT_SLUG=${TENANT_SLUG}
NIMBUS_API_KEY=${API_KEY}
NIMBUS_KEY_ID=${KEY_ID}
NIMBUS_PG_DB_ID=${PG_DB_ID}
NIMBUS_MONGO_DB_ID=${MONGO_DB_ID}
NIMBUS_DB_NAME=${NIMBUS_DB}
NIMBUS_KONG_URL=${KONG_URL}
NIMBUS_ANON_APIKEY=${ANON_KEY}
NIMBUS_SERVICE_APIKEY=${SERVICE_KEY}
NIMBUS_ADMIN_EMAIL=${ADMIN_EMAIL}
NIMBUS_ADMIN_PASSWORD=${ADMIN_PASSWORD}
NIMBUS_ADMIN_SUB=${ADMIN_SUB}
EOF
cyan "DONE: tenant=${TENANT_SLUG} pg=${PG_DB_ID} mongo=${MONGO_DB_ID} (state → ${STATE_ENV})"
