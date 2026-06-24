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

# register_mount NAME ENGINE DSN [READ_SCOPED] — POST /admin/v1/databases; echoes
# mount id. READ_SCOPED (4th arg, "true"/"false", default false) rides the SAME
# registration-body contract as shared_resources (snake_case `read_scoped`): when
# true the data plane owner-scopes reads on this mount, so an app-key-only read
# returns 0 unless the caller is an admin JWT (F2 bypass). The data plane reads
# read_scoped from the mount's capability_overrides exactly like shared_resources.
# A re-register (409) does NOT update an existing row, so the UPDATE convergence
# in step 4b is the authority that flips the flag on every run.
register_mount() {
  local code read_scoped
  read_scoped="${4:-false}"
  code=$(curl -s -o /tmp/nimbus-mount.json -w '%{http_code}' -X POST \
    "${KONG_URL}/admin/v1/databases" \
    -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${TENANT_SLUG}" \
    -H 'Content-Type: application/json' \
    -d "{\"engine\":\"$2\",\"name\":\"$1\",\"connection_string\":\"$3\",\"read_scoped\":${read_scoped}}")
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

  cyan "registering PostgreSQL mount '${PG_MOUNT_NAME}' → ${NIMBUS_DB} (read_scoped=true)"
  PG_DB_ID="$(register_mount "${PG_MOUNT_NAME}" postgresql \
    "postgres://$(urlenc "${PG_USER}"):$(urlenc "${PG_PASS}")@postgres:5432/${NIMBUS_DB}" true)"
  cyan "registering MongoDB mount '${MONGO_MOUNT_NAME}' → ${NIMBUS_DB}"
  MONGO_DB_ID="$(register_mount "${MONGO_MOUNT_NAME}" mongodb \
    "mongodb://$(urlenc "${MONGO_USER}"):$(urlenc "${MONGO_PASS}")@mongo:27017/${NIMBUS_DB}?authSource=admin")"
  [[ -n "${PG_DB_ID}" && -n "${MONGO_DB_ID}" ]] || fail "mount registration returned empty ids"
fi
cyan "mounts: pg=${PG_DB_ID} mongo=${MONGO_DB_ID}"

# ── 4b) flip read_scoped=true on the live PG mount (authoritative convergence) ─
# The registration body carries read_scoped, but a re-register (409) never updates
# an existing row and the inline-INSERT may not yet thread the column on every
# build, so this UPDATE is the source of truth that converges the live row to the
# secure state on EVERY run. The column is added by migration 068's sibling
# (read_scoped boolean NOT NULL DEFAULT false); guarded with to_regclass +
# information_schema so an un-migrated stack degrades to a clear hint instead of a
# psql error. The data plane caches read_scoped at open_pool, so the orchestrator
# restarts data-plane-router after this flips (see the runbook).
cyan "flipping read_scoped=true on the nimbus PG mount (id=${PG_DB_ID})"
RS_OUT="$(docker exec "${PG_CTN}" psql -U "${PG_USER}" -d postgres -tA -v ON_ERROR_STOP=1 <<SQL 2>&1 || true
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='tenant_databases'
                   AND column_name='read_scoped') THEN
    RAISE NOTICE 'NO_READ_SCOPED_COLUMN';
    RETURN;
  END IF;
  UPDATE public.tenant_databases SET read_scoped = true
   WHERE id = '${PG_DB_ID}'::uuid AND tenant_id = '${TENANT_SLUG}';
  RAISE NOTICE 'READ_SCOPED_SET';
END \$\$;
SQL
)"
case "${RS_OUT}" in
  *NO_READ_SCOPED_COLUMN*)
    cyan "WARN: tenant_databases.read_scoped column absent — run migrations first (068 sibling), then re-run. App-key isolation will NOT be enforced until then." ;;
  *READ_SCOPED_SET*)
    cyan "read_scoped=true on nimbus PG mount — restart data-plane-router for it to take effect" ;;
  *)
    cyan "WARN: read_scoped UPDATE produced: ${RS_OUT}" ;;
esac

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
# find_admin_sub_by_email — PAGE through GET /auth/v1/admin/users (per_page=200)
# to find the admin by email. The shared GoTrue holds many users from sibling
# seeds, so a page-1-only lookup misses an admin that landed on a later page
# (the hambooking idempotency bug); stop at the first page with <200 users.
find_admin_sub_by_email() {
  local page sub
  page=1
  while [[ "${page}" -le 50 ]]; do
    curl -s -o /tmp/nimbus-admin-list.json \
      "${KONG_URL}/auth/v1/admin/users?page=${page}&per_page=200" \
      -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${GOTRUE_SERVICE_ROLE}" || break
    sub="$(python3 -c '
import json,sys
try:
  users=json.load(open("/tmp/nimbus-admin-list.json")).get("users",[])
except Exception:
  print("|0"); sys.exit()
hit=next((u.get("id","") for u in users if u.get("email")==sys.argv[1]), "")
print(f"{hit}|{len(users)}")' "${ADMIN_EMAIL}" 2>/dev/null)"
    [[ "${sub%%|*}" != "" ]] && { printf '%s' "${sub%%|*}"; return 0; }
    [[ "${sub##*|}" -lt 200 ]] && break
    page=$((page + 1))
  done
  return 0
}

# When the admin already exists, the create returns 422 (email_exists); page the
# admin list to recover the sub. A fresh create returns the sub directly.
if [[ "${code}" == "200" || "${code}" == "201" ]]; then
  ADMIN_SUB="$(_lt_json_field id </tmp/nimbus-admin.json)"
else
  ADMIN_SUB="$(find_admin_sub_by_email)"
fi
[[ -n "${ADMIN_SUB}" ]] || fail "could not create/find GoTrue admin (${code}): $(head -c 200 /tmp/nimbus-admin.json)"
cyan "admin sub=${ADMIN_SUB:0:8}…"

# ── 7) generated business seed (deterministic · idempotent · ledger-balanced) ──
# Probe the gateway once for the app-key principal the data plane stamps as
# owner_id, then bulk-load the generated business under that exact owner so the
# app's owner-scoped reads see every row. TRUNCATE in the generated SQL +
# deleteMany in the mongo script make re-runs converge (byte-identical output).
cyan "probing gateway for the owner principal (one PG row)"
gw_q "${PG_DB_ID}" app_users \
  '{"op":"insert","data":{"id":"nimbus-owner-probe","email":"probe@nimbus.local","name":"Probe","role":"customer","status":"active"}}' >/dev/null
SEED_OWNER="$(python3 -c 'import json;print(json.load(open("/tmp/nimbus-q.json"))["rows"][0]["owner_id"])' 2>/dev/null || echo "")"
gw_q "${PG_DB_ID}" app_users '{"op":"delete","filter":{"id":{"$eq":"nimbus-owner-probe"}}}' >/dev/null 2>&1 || true
[[ -n "${SEED_OWNER}" ]] || fail "could not read owner_id from the gateway probe"
cyan "owner principal: ${SEED_OWNER}"

NODE_IMAGE="${NIMBUS_NODE_IMAGE:-node:22-alpine}"
GEN_MJS="${SCRIPT_DIR}/nimbus-data-generate.mjs"
[[ -f "${GEN_MJS}" ]] || fail "generator missing: ${GEN_MJS}"
OUT_DIR="$(mktemp -d /tmp/nimbus-seed.XXXXXX)"
trap 'rm -rf "${OUT_DIR}"' EXIT

cyan "generating the Nimbus business (seed 42, deterministic)"
docker run --rm --network none \
  -v "${GEN_MJS}:/gen.mjs:ro" -v "${OUT_DIR}:/out" \
  -e SEED_OWNER="${SEED_OWNER}" -e SEED_TENANT="${TENANT_SLUG}" \
  "${NODE_IMAGE}" node /gen.mjs || fail "generator failed (ledger imbalance or error)"

cyan "loading PostgreSQL business (TRUNCATE + COPY, idempotent)"
docker exec -i "${PG_CTN}" psql -U "${PG_USER}" -d "${NIMBUS_DB}" -q -v ON_ERROR_STOP=1 \
  <"${OUT_DIR}/pg-nimbus.sql" >/dev/null || fail "postgres business load failed"

# Re-stamp the GoTrue admin as an app_users row (TRUNCATE removed it) so the
# admin can sign in and appear in the console under their real auth sub. The
# owner-scoped mount has no ON CONFLICT target, so delete-then-insert is the
# idempotent path (re-runs converge on one admin row).
gw_q "${PG_DB_ID}" app_users '{"op":"delete","filter":{"id":{"$eq":"'"${ADMIN_SUB}"'"}}}' >/dev/null 2>&1 || true
gw_q "${PG_DB_ID}" app_users \
  "{\"op\":\"insert\",\"data\":{\"id\":\"${ADMIN_SUB}\",\"email\":\"${ADMIN_EMAIL}\",\"name\":\"Nimbus Admin\",\"role\":\"admin\",\"status\":\"active\"}}" >/dev/null

# ── 7b) re-own seeded business to system:nimbus (close the app-key read hole) ──
# The bulk load + the admin re-stamp both went through the gateway, so every row
# is owner-stamped `api-key:<key uuid>` — readable by anyone holding the public
# mbk_ key. Re-own them to `system:nimbus`, a principal NO login resolves to, so
# with read_scoped ON an app-key-only read returns 0. The admin JWT (role=admin)
# still reads them via the F2 owner-scope bypass; a customer JWT (owner user:<sub>)
# never matches them. Idempotent: re-runs converge (the WHERE re-matches api-key:%
# fresh-loaded rows; already-system rows are untouched). Done in-DB (the seed
# already has psql to ${NIMBUS_DB}); the data plane never blocks an owner rewrite
# it doesn't see (the rows belong to the platform, not a tenant user).
cyan "re-owning seeded business rows → system:nimbus (api-key:% → system:nimbus)"
docker exec -i "${PG_CTN}" psql -U "${PG_USER}" -d "${NIMBUS_DB}" -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null \
  || fail "re-own to system:nimbus failed"
UPDATE public.app_users      SET owner_id = 'system:nimbus' WHERE owner_id LIKE 'api-key:%';
UPDATE public.accounts       SET owner_id = 'system:nimbus' WHERE owner_id LIKE 'api-key:%';
UPDATE public.txns           SET owner_id = 'system:nimbus' WHERE owner_id LIKE 'api-key:%';
UPDATE public.ledger_entries SET owner_id = 'system:nimbus' WHERE owner_id LIKE 'api-key:%';
UPDATE public.subscriptions  SET owner_id = 'system:nimbus' WHERE owner_id LIKE 'api-key:%';
UPDATE public.invoices       SET owner_id = 'system:nimbus' WHERE owner_id LIKE 'api-key:%';
SQL

cyan "loading MongoDB collections (drop + insert, owner-stamped)"
STACK_NET="$(docker inspect "${MONGO_CTN}" \
  --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' | head -1)"
MONGO_IMAGE="$(docker inspect "${MONGO_CTN}" --format '{{.Config.Image}}')"
docker run --rm --network "${STACK_NET}" \
  -v "${OUT_DIR}/mongo-nimbus.js:/seed.js:ro" "${MONGO_IMAGE}" \
  mongosh --quiet \
  "mongodb://$(urlenc "${MONGO_USER}"):$(urlenc "${MONGO_PASS}")@mongo:27017/${NIMBUS_DB}?authSource=admin" \
  /seed.js >/dev/null || fail "mongo business load failed"
cyan "business seeded — $(python3 -c 'import json;c=json.load(open("'"${OUT_DIR}"'/counts.json"));print("pg",c["pg"],"mongo",c["mongo"])')"

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
NIMBUS_SECURE_OWNER=system:nimbus
EOF
cyan "DONE: tenant=${TENANT_SLUG} pg=${PG_DB_ID} mongo=${MONGO_DB_ID} (state → ${STATE_ENV})"
