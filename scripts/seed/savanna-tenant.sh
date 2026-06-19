#!/usr/bin/env bash
# **************************************************************************** #
#  savanna-tenant.sh — add a MongoDB plane to the Savanna Zoo app on Grobase  #
#                                                                             #
#  The zoo's core (animals/tickets/staff) runs on PostgREST+Postgres. This    #
#  script bolts on the DOCUMENT engine to showcase Grobase's multi-engine     #
#  reach from one frontend: every visitor keeps a private "Visit Journal" of  #
#  animal observations stored as MongoDB documents, owner-scoped per GoTrue    #
#  user through the query-router (POST /query/v1/{dbId}/tables/observations).  #
#                                                                             #
#  It provisions a `savanna` tenant, an enterprise entitlement spanning both  #
#  engines, an mbk_ API key, and a `savanna-mongo` mount → the zoo_app Mongo   #
#  database, then emits the mongo dbId + app key into front/.env for the SPA. #
#                                                                             #
#  Idempotent: re-runs reuse the key + mount (probed live) and re-seed the    #
#  demo visitor's journal. State → .savanna-tenant.env (gitignored).          #
# **************************************************************************** #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/service-auth.sh
source "${SCRIPT_DIR}/../lib/service-auth.sh"
# shellcheck source=../lib/lib-live-tenant.sh
source "${SCRIPT_DIR}/../lib/lib-live-tenant.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATE_ENV="${REPO_ROOT}/.savanna-tenant.env"
FRONT_ENV="${REPO_ROOT}/vendor/savanna-zoo/front/.env"
MONGO_CTN="mini-baas-mongo"
ZOO_DB="zoo_app"
MONGO_MOUNT_NAME="savanna-mongo"
TENANT_SLUG="savanna"
DEMO_EMAIL="visitor@savanna-zoo.com"
DEMO_PASSWORD="${ZOO_PASSWORD:-zoo-admin-2024}"

cyan() { printf '\033[0;36m[savanna-tenant] %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[savanna-tenant] FAIL: %s\033[0m\n' "$*" >&2
  exit 1
}
urlenc() { python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"; }

# gw_q DBID TABLE BODY [BEARER] — query-router CRUD; body→/tmp/savanna-q.json, echoes status.
gw_q() {
  local extra=()
  [[ -n "${4:-}" ]] && extra=(-H "Authorization: Bearer $4")
  curl -s -o /tmp/savanna-q.json -w '%{http_code}' -X POST "${KONG_URL}/query/v1/$1/tables/$2" \
    -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: ${API_KEY}" "${extra[@]}" \
    -H 'Content-Type: application/json' -d "$3"
}

# ── 0) endpoints + secrets from the running stack ────────────────────────────
kong_port="$(_lt_host_port mini-baas-kong 8000/tcp)"
tc_port="$(_lt_host_port mini-baas-tenant-control 3022/tcp)"
[[ -n "${kong_port}" && -n "${tc_port}" ]] || fail "mini-baas stack not running (kong/tenant-control ports)"
KONG_URL="http://127.0.0.1:${kong_port}"
TC_URL="http://127.0.0.1:${tc_port}"
SERVICE_TOKEN="$(_lt_env mini-baas-tenant-control INTERNAL_SERVICE_TOKEN)"
[[ -n "${SERVICE_TOKEN}" ]] || fail "INTERNAL_SERVICE_TOKEN not found on tenant-control"
ANON_KEY="$(_lt_env mini-baas-kong KONG_PUBLIC_API_KEY)"
SERVICE_KEY="$(_lt_env mini-baas-kong KONG_SERVICE_API_KEY)"
[[ -n "${ANON_KEY}" && -n "${SERVICE_KEY}" ]] || fail "stack secrets not found (anon/service key)"
MONGO_USER="$(_lt_env "${MONGO_CTN}" MONGO_INITDB_ROOT_USERNAME)"; MONGO_USER="${MONGO_USER:-mongo}"
MONGO_PASS="$(_lt_env "${MONGO_CTN}" MONGO_INITDB_ROOT_PASSWORD)"; MONGO_PASS="${MONGO_PASS:-mongo}"

# ── 1) tenant + enterprise plan (unlocks both engines) ───────────────────────
cyan "ensuring tenant '${TENANT_SLUG}'"
tbody="{\"id\":\"${TENANT_SLUG}\",\"name\":\"Savanna Park Zoo\"}"
svc_auth POST /v1/tenants "${tbody}"
code=$(curl -s -o /tmp/savanna-tenant.json -w '%{http_code}' -X POST "${TC_URL}/v1/tenants" \
  "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${tbody}")
[[ "${code}" == "201" || "${code}" == "409" ]] || fail "tenant create (${code}): $(cat /tmp/savanna-tenant.json)"

pbody='{"plan":"enterprise"}'
svc_auth PATCH "/v1/tenants/${TENANT_SLUG}" "${pbody}"
curl -s -o /dev/null -X PATCH "${TC_URL}/v1/tenants/${TENANT_SLUG}" \
  "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${pbody}" || true

cyan "setting custom entitlement (engines=[postgresql,mongodb])"
ebody='{"ceiling_plan":"enterprise","status":"active","entitlement":{"label":"savanna","engines":["postgresql","mongodb"],"capabilities":{"read":true,"write":true,"insert":true,"update":true,"delete":true,"upsert":true,"batch":true,"aggregate":true},"limits":{"rps":250,"burst":500,"max_rows":1000,"quota.query.count":5000000},"max_mounts":2}}'
svc_auth PUT "/v1/tenants/${TENANT_SLUG}/entitlement" "${ebody}"
curl -s -o /tmp/savanna-ent.json -w '%{http_code}' -X PUT \
  "${TC_URL}/v1/tenants/${TENANT_SLUG}/entitlement" \
  "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${ebody}" >/dev/null || true

# ── 2) API key + mongo mount — reuse if still valid ──────────────────────────
API_KEY=""; KEY_ID=""; MONGO_DB_ID=""
if [[ -f "${STATE_ENV}" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_ENV}"
  API_KEY="${SAVANNA_API_KEY:-}"; KEY_ID="${SAVANNA_KEY_ID:-}"; MONGO_DB_ID="${SAVANNA_MONGO_DB_ID:-}"
fi
key_ok=0
if [[ -n "${API_KEY}" && -n "${MONGO_DB_ID}" ]]; then
  m1=$(curl -s -o /dev/null -w '%{http_code}' "${KONG_URL}/query/v1/${MONGO_DB_ID}/schema" \
    -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: ${API_KEY}")
  [[ "${m1}" == "200" ]] && key_ok=1
fi

# register_mount NAME ENGINE DSN — POST /admin/v1/databases; echoes mount id
register_mount() {
  local code
  code=$(curl -s -o /tmp/savanna-mount.json -w '%{http_code}' -X POST \
    "${KONG_URL}/admin/v1/databases" \
    -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${TENANT_SLUG}" \
    -H 'Content-Type: application/json' \
    -d "{\"engine\":\"$2\",\"name\":\"$1\",\"connection_string\":\"$3\"}")
  if [[ "${code}" == "201" ]]; then
    _lt_json_field id </tmp/savanna-mount.json
  elif [[ "${code}" == "409" ]]; then
    curl -fsS "${KONG_URL}/admin/v1/databases" \
      -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${TENANT_SLUG}" |
      python3 -c "import json,sys;rows=json.load(sys.stdin);print(next(r['id'] for r in rows if r.get('name')=='$1'))"
  else
    fail "mount $1 register failed (${code}): $(cat /tmp/savanna-mount.json)"
  fi
}

if [[ "${key_ok}" == "1" ]]; then
  cyan "reusing existing key + mount (mongo=${MONGO_DB_ID})"
else
  cyan "minting API key (scopes read,write)"
  kbody='{"name":"savanna-app","scopes":["read","write"]}'
  svc_auth POST "/v1/tenants/${TENANT_SLUG}/keys" "${kbody}"
  code=$(curl -s -o /tmp/savanna-key.json -w '%{http_code}' -X POST \
    "${TC_URL}/v1/tenants/${TENANT_SLUG}/keys" \
    "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${kbody}")
  [[ "${code}" == "201" ]] || fail "key mint (${code}): $(cat /tmp/savanna-key.json)"
  API_KEY="$(_lt_json_field key </tmp/savanna-key.json)"
  KEY_ID="$(_lt_json_field id </tmp/savanna-key.json)"
  [[ "${API_KEY}" == mbk_* ]] || fail "minted key has unexpected shape"

  cyan "registering MongoDB mount '${MONGO_MOUNT_NAME}' → ${ZOO_DB}"
  MONGO_DB_ID="$(register_mount "${MONGO_MOUNT_NAME}" mongodb \
    "mongodb://$(urlenc "${MONGO_USER}"):$(urlenc "${MONGO_PASS}")@mongo:27017/${ZOO_DB}?authSource=admin")"
  [[ -n "${MONGO_DB_ID}" ]] || fail "mount registration returned empty id"
fi
cyan "mount: mongo=${MONGO_DB_ID}"

# ── 3) seed the demo visitor's journal (owner-scoped via their JWT) ──────────
cyan "logging in demo visitor '${DEMO_EMAIL}' for owner-scoped seed"
DEMO_TOK="$(curl -s -X POST "${KONG_URL}/auth/v1/token?grant_type=password" \
  -H "apikey: ${ANON_KEY}" -H 'Content-Type: application/json' \
  -d "{\"email\":\"${DEMO_EMAIL}\",\"password\":\"${DEMO_PASSWORD}\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")"
[[ -n "${DEMO_TOK}" ]] || cyan "WARN: demo visitor login failed — journal seed skipped (run infra/init.sh first)"

if [[ -n "${DEMO_TOK}" ]]; then
  cyan "clearing + seeding the demo visitor's observations (owner-scoped)"
  gw_q "${MONGO_DB_ID}" observations '{"op":"delete","filter":{"seed":{"$eq":true}}}' "${DEMO_TOK}" >/dev/null 2>&1 || true
  seed_obs() {
    gw_q "${MONGO_DB_ID}" observations \
      "{\"op\":\"insert\",\"data\":{\"animal\":\"$1\",\"zone\":\"$2\",\"note\":\"$3\",\"rating\":$4,\"tags\":$5,\"seed\":true,\"created_at\":\"$6\"}}" \
      "${DEMO_TOK}" >/dev/null || cyan "WARN: seed insert '$1' returned non-2xx ($(head -c 160 /tmp/savanna-q.json))"
  }
  seed_obs "Kesi the Lioness" savannah "Watched the morning feed — she let out a huge yawn!" 5 '["big-cat","feeding"]' "2026-06-10T09:30:00Z"
  seed_obs "Pip the Penguin"  arctic   "The chicks took their first swim today."             5 '["bird","cute"]'      "2026-06-12T11:00:00Z"
  seed_obs "Banjo the Sloth"  rainforest "Moved exactly one branch in an hour. Iconic."        4 '["slow","relaxing"]'  "2026-06-14T15:45:00Z"
  obs_count="$(python3 -c 'import json;d=json.load(open("/tmp/savanna-q.json"));print(d.get("rowCount", len(d.get("rows",[]))))' 2>/dev/null || echo '?')"
  cyan "demo journal seeded (last insert rowCount=${obs_count})"
fi

# ── 4) emit frontend env + state ─────────────────────────────────────────────
# front/.env already carries VITE_BAAS_ENDPOINT (same-origin proxy) +
# VITE_BAAS_API_KEY (the Kong anon key for PostgREST/GoTrue). Append the mongo
# coordinates without clobbering those.
cyan "writing mongo coordinates into front/.env"
touch "${FRONT_ENV}"
grep -v -E '^VITE_BAAS_(MONGO_DBID|APP_KEY)=' "${FRONT_ENV}" >"${FRONT_ENV}.tmp" || true
mv "${FRONT_ENV}.tmp" "${FRONT_ENV}"
{
  echo "VITE_BAAS_MONGO_DBID=${MONGO_DB_ID}"
  echo "VITE_BAAS_APP_KEY=${API_KEY}"
} >>"${FRONT_ENV}"

cat >"${STATE_ENV}" <<EOF
# generated by scripts/seed/savanna-tenant.sh — DO NOT COMMIT
SAVANNA_TENANT_SLUG=${TENANT_SLUG}
SAVANNA_API_KEY=${API_KEY}
SAVANNA_KEY_ID=${KEY_ID}
SAVANNA_MONGO_DB_ID=${MONGO_DB_ID}
SAVANNA_DB_NAME=${ZOO_DB}
SAVANNA_KONG_URL=${KONG_URL}
SAVANNA_ANON_APIKEY=${ANON_KEY}
SAVANNA_SERVICE_APIKEY=${SERVICE_KEY}
EOF
cyan "DONE: tenant=${TENANT_SLUG} mongo=${MONGO_DB_ID} (state → ${STATE_ENV})"
