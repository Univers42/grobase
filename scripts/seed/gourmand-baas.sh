#!/usr/bin/env bash
# **************************************************************************** #
#  gourmand-baas.sh — provision vite-gourmand as a STATIC app on Grobase       #
#                                                                              #
#  Re-platforms vite-gourmand off its NestJS+Supabase backend onto Grobase:    #
#  a dedicated `gourmand` tenant, an mbk_ app key, and an OWNER-SCOPED          #
#  PostgreSQL mount (isolation defaults to shared_rls) over the app's OWN       #
#  database. The mount declares shared_resources=[Menu,Dish,…] so catalog        #
#  tables are world-readable (F1 per-table isolation); Order/Loyalty/… stay      #
#  owner-scoped per GoTrue user, and an `admin` JWT reads across owners (F2).   #
#  Requires the data plane started with DATA_PLANE_PER_TABLE_ISOLATION=1 and    #
#  DATA_PLANE_ADMIN_BYPASS=1.                                                   #
#                                                                              #
#  This is SEPARATE from gourmand-tenant.sh (the osionos `tenant_owned`         #
#  observability mount) — both can coexist over the same DB.                    #
#                                                                              #
#  DSN: GOURMAND_DB_DSN if set, else gourmand-local-db.sh builds the local      #
#  substrate (schema+seeds+owner-scoping overlay) and prints its DSN.           #
#                                                                              #
#  Emits vendor/vite-gourmand/View/{public/baas-config.js,.env} + a gitignored #
#  state file. Idempotent: re-runs reuse the key + mount.                       #
# **************************************************************************** #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/service-auth.sh
source "${SCRIPT_DIR}/../lib/service-auth.sh"
# shellcheck source=../lib/lib-live-tenant.sh
source "${SCRIPT_DIR}/../lib/lib-live-tenant.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATE_ENV="${REPO_ROOT}/.gourmand-baas.env"
VIEW_DIR="${REPO_ROOT}/vendor/vite-gourmand/View"
PG_CTN="mini-baas-postgres"
GOURMAND_DB="gourmand"
MOUNT_NAME="gourmand-app-db"
TENANT_SLUG="gourmand"
NODE_IMAGE="${NODE_IMAGE:-node:20-alpine}"

# Catalog tables that skip owner-scoping (readable across all users, F1).
SHARED_RESOURCES='["Menu","MenuImage","MenuIngredient","Dish","DishAllergen","DishIngredient","Ingredient","Allergen","Diet","Theme","WorkingHours","Company","CompanyOwner","CompanyWorkingHours","Event","Promotion","Discount","OrderTag","KanbanColumn","Role","Permission","RolePermission","Publish","ReviewImage","_MenuDishes","_DishAllergens"]'

# Demo accounts, one per role:  email|password|gotrue_role
ROLE_USERS=(
  "admin@gourmand.local|Gourmand#2026|admin"
  "employe@gourmand.local|Gourmand#2026|employee"
  "client@gourmand.local|Gourmand#2026|customer"
)

cyan() { printf '\033[0;36m[gourmand-baas] %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[gourmand-baas] FAIL: %s\033[0m\n' "$*" >&2
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

PSQL() { docker exec -i "${PG_CTN}" psql -U "${PG_USER}" -v ON_ERROR_STOP=1 "$@"; }

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
PG_USER="$(_lt_env "${PG_CTN}" POSTGRES_USER)"; PG_USER="${PG_USER:-postgres}"

# ── 1) resolve the gourmand DSN (local substrate unless an external one is given) ──
DSN="${GOURMAND_DB_DSN:-}"
if [[ -z "${DSN}" ]]; then
  cyan "no GOURMAND_DB_DSN — building the local substrate (schema + seeds + owner-scoping overlay)"
  DSN="$(bash "${SCRIPT_DIR}/gourmand-local-db.sh" | tail -1)"
  [[ "${DSN}" == postgres://* ]] || fail "gourmand-local-db.sh did not print a DSN"
fi
DSN_HOST="$(printf '%s' "${DSN}" | sed -E 's|.*@([^:/?]+).*|\1|')"
cyan "gourmand DSN host: ${DSN_HOST}"

# ── 2) tenant + enterprise ceiling + postgres entitlement ────────────────────
cyan "ensuring tenant '${TENANT_SLUG}'"
tbody="{\"id\":\"${TENANT_SLUG}\",\"name\":\"Vite Gourmand\"}"
svc_auth POST /v1/tenants "${tbody}"
code=$(curl -s -o /tmp/vg-tenant.json -w '%{http_code}' -X POST "${TC_URL}/v1/tenants" \
  "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${tbody}")
[[ "${code}" == "201" || "${code}" == "409" ]] || fail "tenant create (${code}): $(cat /tmp/vg-tenant.json)"

pbody='{"plan":"enterprise"}'
svc_auth PATCH "/v1/tenants/${TENANT_SLUG}" "${pbody}"
curl -s -o /dev/null -X PATCH "${TC_URL}/v1/tenants/${TENANT_SLUG}" \
  "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${pbody}" || true

ebody='{"ceiling_plan":"enterprise","status":"active","entitlement":{"label":"gourmand","engines":["postgresql"],"capabilities":{"read":true,"write":true,"insert":true,"update":true,"delete":true,"upsert":true},"addons":["realtime"]}}'
svc_auth PUT "/v1/tenants/${TENANT_SLUG}/entitlement" "${ebody}"
code=$(curl -s -o /tmp/vg-ent.json -w '%{http_code}' -X PUT \
  "${TC_URL}/v1/tenants/${TENANT_SLUG}/entitlement" \
  "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${ebody}")
[[ "${code}" == "200" ]] || cyan "WARN: entitlement set returned ${code} (continuing — tenant is enterprise-tier already)"

# ── 3) API key + owner-scoped postgres mount (shared_resources) — reuse if valid ──
API_KEY=""; KEY_ID=""; DB_ID=""
if [[ -f "${STATE_ENV}" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_ENV}"
  API_KEY="${VG_API_KEY:-}"; KEY_ID="${VG_KEY_ID:-}"; DB_ID="${VG_DB_ID:-}"
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
  kbody='{"name":"gourmand-app","scopes":["read","write"]}'
  svc_auth POST "/v1/tenants/${TENANT_SLUG}/keys" "${kbody}"
  code=$(curl -s -o /tmp/vg-key.json -w '%{http_code}' -X POST \
    "${TC_URL}/v1/tenants/${TENANT_SLUG}/keys" \
    "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${kbody}")
  [[ "${code}" == "201" ]] || fail "key mint (${code}): $(cat /tmp/vg-key.json)"
  API_KEY="$(_lt_json_field key </tmp/vg-key.json)"
  KEY_ID="$(_lt_json_field id </tmp/vg-key.json)"
  [[ "${API_KEY}" == mbk_* ]] || fail "minted key has unexpected shape"

  cyan "registering owner-scoped postgres mount '${MOUNT_NAME}' (shared_resources=${SHARED_RESOURCES:0:40}…)"
  mbody="{\"engine\":\"postgresql\",\"name\":\"${MOUNT_NAME}\",\"connection_string\":\"${DSN}\",\"shared_resources\":${SHARED_RESOURCES}}"
  code=$(curl -s -o /tmp/vg-mount.json -w '%{http_code}' -X POST \
    "${KONG_URL}/admin/v1/databases" \
    -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${TENANT_SLUG}" \
    -H 'Content-Type: application/json' -d "${mbody}")
  if [[ "${code}" == "201" ]]; then
    DB_ID="$(_lt_json_field id </tmp/vg-mount.json)"
  elif [[ "${code}" == "409" && -n "${DB_ID}" ]]; then
    cyan "mount already registered, keeping ${DB_ID}"
  else
    fail "mount register (${code}): $(cat /tmp/vg-mount.json)"
  fi
  [[ -n "${DB_ID}" ]] || fail "no mount id"
fi

# ── 4) GoTrue demo users (one per role) + linked "User" profile rows ─────────
declare -A SUBS=()
for spec in "${ROLE_USERS[@]}"; do
  IFS='|' read -r email pass role <<<"${spec}"
  code=$(curl -s -o /tmp/vg-user.json -w '%{http_code}' -X POST "${KONG_URL}/auth/v1/admin/users" \
    -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${SERVICE_KEY}" -H 'Content-Type: application/json' \
    -d "{\"email\":\"${email}\",\"password\":\"${pass}\",\"role\":\"${role}\",\"email_confirm\":true}")
  sub=""
  if [[ "${code}" == "200" || "${code}" == "201" ]]; then
    sub="$(_lt_json_field id </tmp/vg-user.json)"
  else
    curl -s -o /tmp/vg-ulist.json "${KONG_URL}/auth/v1/admin/users" \
      -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${SERVICE_KEY}" || true
    sub="$(EMAIL="${email}" python3 -c '
import json,os
try:
  d=json.load(open("/tmp/vg-ulist.json"))
  print(next((u.get("id","") for u in d.get("users",[]) if u.get("email")==os.environ["EMAIL"]), ""))
except Exception: print("")' 2>/dev/null)"
  fi
  [[ -n "${sub}" ]] || fail "could not create/find GoTrue user ${email} (${code})"
  SUBS["${email}"]="${sub}"
  cyan "GoTrue ${role} ${email} → sub ${sub:0:8}…"
  # Linked profile row in the gourmand DB (owner_id stamped so the user reads its own).
  first="${email%@*}"
  PSQL -d "${GOURMAND_DB}" -q -c "
    INSERT INTO \"User\" (email, first_name, auth_id, owner_id, is_active, is_email_verified)
    VALUES ('${email}', '${first}', '${sub}', 'user:${sub}', true, true)
    ON CONFLICT (email) DO UPDATE SET auth_id=EXCLUDED.auth_id, owner_id=EXCLUDED.owner_id;" \
    >/dev/null 2>&1 || cyan "WARN: profile upsert for ${email} non-zero (continuing)"
done

# ── 5) realtime token + frontend config + state ──────────────────────────────
RT_TOKEN=""
[[ -n "${RT_JWT_SECRET}" ]] && RT_TOKEN="$(mint_jwt "${RT_JWT_SECRET}" gourmand-app)"

cyan "writing ${VIEW_DIR}/public/baas-config.js"
mkdir -p "${VIEW_DIR}/public"
cat >"${VIEW_DIR}/public/baas-config.js" <<EOF
// generated by scripts/seed/gourmand-baas.sh — $(date -Iseconds) — DO NOT COMMIT
window.__BAAS__ = {
  url: "${KONG_URL}",
  anonKey: "${ANON_KEY}",
  apiKey: "${API_KEY}",
  tenantId: "${TENANT_SLUG}",
  pgDbId: "${DB_ID}",
  realtimeToken: "${RT_TOKEN}"
};
EOF

cyan "writing ${VIEW_DIR}/.env (VITE_BAAS_*)"
cat >"${VIEW_DIR}/.env" <<EOF
# generated by scripts/seed/gourmand-baas.sh — $(date -Iseconds)
VITE_BAAS_URL=${KONG_URL}
VITE_BAAS_KONG_KEY=${ANON_KEY}
VITE_BAAS_API_KEY=${API_KEY}
VITE_BAAS_TENANT_ID=${TENANT_SLUG}
VITE_BAAS_PG_DB_ID=${DB_ID}
VITE_BAAS_REALTIME_TOKEN=${RT_TOKEN}
EOF

cat >"${STATE_ENV}" <<EOF
# generated by scripts/seed/gourmand-baas.sh — $(date -Iseconds)
VG_TENANT_SLUG=${TENANT_SLUG}
VG_API_KEY=${API_KEY}
VG_KEY_ID=${KEY_ID}
VG_DB_ID=${DB_ID}
VG_DB_NAME=${GOURMAND_DB}
VG_KONG_URL=${KONG_URL}
VG_ANON_APIKEY=${ANON_KEY}
VG_SERVICE_APIKEY=${SERVICE_KEY}
VG_ADMIN_EMAIL=admin@gourmand.local
VG_ADMIN_PASSWORD=Gourmand#2026
VG_ADMIN_SUB=${SUBS[admin@gourmand.local]:-}
VG_CLIENT_EMAIL=client@gourmand.local
VG_CLIENT_PASSWORD=Gourmand#2026
VG_REALTIME_TOKEN=${RT_TOKEN}
EOF
chmod 600 "${STATE_ENV}"
cyan "DONE: tenant=${TENANT_SLUG} mount=${DB_ID} (owner-scoped, shared catalog); state → ${STATE_ENV}"
cyan "NOTE: data plane must run with DATA_PLANE_PER_TABLE_ISOLATION=1 DATA_PLANE_ADMIN_BYPASS=1"
