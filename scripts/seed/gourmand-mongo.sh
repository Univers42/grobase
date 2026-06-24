#!/usr/bin/env bash
# **************************************************************************** #
#  gourmand-mongo.sh — add a MongoDB analytics mount to the gourmand tenant   #
#                                                                              #
#  vite-gourmand's NestJS backend used MongoDB for analytics (events). This    #
#  reproduces that as a Grobase MongoDB mount alongside the Postgres app mount #
#  (dual-engine), seeds the `events` + `menu_views` collections, and makes     #
#  them readable through the gateway. Idempotent. Run AFTER gourmand-baas.sh.  #
#                                                                              #
#  Owner model: the mongo mount is owner-scoped (shared_rls; mongo fails-closed #
#  on tenant_owned). Owner-scoping filters on {owner_id, tenant_id}, so the     #
#  bulk-seeded docs are stamped with the app-key principal (discovered live by  #
#  inserting a probe through the gateway) + tenant_id so the app key can read   #
#  them — the same identity the SPA uses.                                       #
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
MONGO_CTN="mini-baas-mongo"
MONGO_NET_HOST="mongo"
MONGO_DB="gourmand"
MOUNT_NAME="gourmand-mongo"

cyan() { printf '\033[0;36m[gourmand-mongo] %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[gourmand-mongo] FAIL: %s\033[0m\n' "$*" >&2
  exit 1
}

[[ -f "${STATE_ENV}" ]] || fail "run scripts/seed/gourmand-baas.sh first (${STATE_ENV} missing)"
# shellcheck disable=SC1090
source "${STATE_ENV}"
KONG="${VG_KONG_URL}"
ANON="${VG_ANON_APIKEY}"
AK="${VG_API_KEY}"
SERVICE_KEY="${VG_SERVICE_APIKEY}"
TENANT="${VG_TENANT_SLUG}"
export SERVICE_TOKEN="$(_lt_env mini-baas-tenant-control INTERNAL_SERVICE_TOKEN)"
TC_URL="http://127.0.0.1:$(_lt_host_port mini-baas-tenant-control 3022/tcp)"
MUSER="$(_lt_env "${MONGO_CTN}" MONGO_INITDB_ROOT_USERNAME)"; MUSER="${MUSER:-mongo}"
MPASS="$(_lt_env "${MONGO_CTN}" MONGO_INITDB_ROOT_PASSWORD)"; MPASS="${MPASS:-mongo}"

mongosh_eval() { docker exec -i "${MONGO_CTN}" mongosh -u "${MUSER}" -p "${MPASS}" --authenticationDatabase admin --quiet --eval "$1"; }
gq() { # $1 table, $2 json → echoes status, body in /tmp/gm-q.json
  curl -s -o /tmp/gm-q.json -w '%{http_code}' -X POST "${KONG}/query/v1/${MONGO_DB_ID}/tables/$1" \
    -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${AK}" -H 'Content-Type: application/json' -d "$2"
}

# ── 1) entitlement: add mongodb to the gourmand tenant ───────────────────────
cyan "ensuring entitlement engines=[postgresql, mongodb]"
ebody='{"ceiling_plan":"enterprise","status":"active","entitlement":{"label":"gourmand","engines":["postgresql","mongodb"],"capabilities":{"read":true,"write":true,"insert":true,"update":true,"delete":true,"upsert":true,"aggregate":true},"addons":["realtime"],"max_mounts":3}}'
svc_auth PUT "/v1/tenants/${TENANT}/entitlement" "${ebody}"
curl -s -o /dev/null -X PUT "${TC_URL}/v1/tenants/${TENANT}/entitlement" "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${ebody}" || true

# ── 2) register the mongo mount (reuse if present) ───────────────────────────
MONGO_DB_ID="${VG_MONGO_DB_ID:-}"
if [[ -n "${MONGO_DB_ID}" ]] && [[ "$(curl -s -o /dev/null -w '%{http_code}' "${KONG}/query/v1/${MONGO_DB_ID}/schema" -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${AK}")" == "200" ]]; then
  cyan "reusing mongo mount ${MONGO_DB_ID}"
else
  cyan "registering mongo mount '${MOUNT_NAME}' → ${MONGO_DB}"
  dsn="mongodb://${MUSER}:${MPASS}@${MONGO_NET_HOST}:27017/${MONGO_DB}?authSource=admin"
  code=$(curl -s -o /tmp/gm-mount.json -w '%{http_code}' -X POST "${KONG}/admin/v1/databases" \
    -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${TENANT}" -H 'Content-Type: application/json' \
    -d "{\"engine\":\"mongodb\",\"name\":\"${MOUNT_NAME}\",\"connection_string\":\"${dsn}\"}")
  if [[ "${code}" == "201" ]]; then
    MONGO_DB_ID="$(_lt_json_field id </tmp/gm-mount.json)"
  elif [[ "${code}" == "409" ]]; then
    MONGO_DB_ID="$(curl -fsS "${KONG}/admin/v1/databases" -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${TENANT}" \
      | MOUNT_NAME="${MOUNT_NAME}" python3 -c 'import json,sys,os; print(next(r["id"] for r in json.load(sys.stdin) if r.get("name")==os.environ["MOUNT_NAME"]))')"
  else
    fail "mongo mount register (${code}): $(cat /tmp/gm-mount.json)"
  fi
fi
[[ -n "${MONGO_DB_ID}" ]] || fail "no mongo mount id"

# ── 3) seed events + menu_views (deterministic, idempotent reseed) ───────────
cyan "seeding analytics collections (events, menu_views)"
mongosh_eval "
const db = db.getSiblingDB('${MONGO_DB}');
const types = ['page_view','menu_view','order_placed','review_submitted','login'];
const ops = [];
for (let i = 0; i < 120; i++) ops.push({ event_type: types[i % types.length], user_id: (i % 20) + 1,
  menu_id: (i % 8) + 1, ts: new Date(Date.UTC(2026, 5, 1 + (i % 18), 9 + (i % 12))),
  data: { source: ['web','mobile','email'][i % 3], session: 'sess-' + (1000 + i) } });
db.events.deleteMany({}); db.events.insertMany(ops);
db.menu_views.deleteMany({});
db.menu_views.insertMany(Array.from({length: 8}, (_, i) => ({ menu_id: i + 1, views: 50 + i * 17, last_viewed: new Date() })));
print('events=' + db.events.countDocuments() + '  menu_views=' + db.menu_views.countDocuments());" >&2

# ── 4) discover the app-key owner principal (insert a probe through Grobase) ──
cyan "discovering the app-key owner principal via a probe insert"
gq events '{"op":"insert","data":{"event_type":"__probe__","user_id":0}}' >/dev/null
OWNER="$(mongosh_eval "const d=db.getSiblingDB('${MONGO_DB}').events.findOne({event_type:'__probe__'}); print(d ? d.owner_id : '')" | tr -d '[:space:]')"
[[ "${OWNER}" == api-key:* ]] || fail "could not derive owner principal (got '${OWNER}')"
cyan "owner principal = ${OWNER}"

# ── 5) stamp owner_id + tenant_id so the app key can read the seeded docs ─────
mongosh_eval "
const db = db.getSiblingDB('${MONGO_DB}');
db.events.deleteMany({event_type:'__probe__'});
db.events.updateMany({}, {\$set:{owner_id:'${OWNER}', tenant_id:'${TENANT}'}});
db.menu_views.updateMany({}, {\$set:{owner_id:'${OWNER}', tenant_id:'${TENANT}'}});
print('stamped events='+db.events.countDocuments()+'  menu_views='+db.menu_views.countDocuments());" >&2

# ── 6) wire mongoDbId into the frontend config + state ───────────────────────
python3 - "${MONGO_DB_ID}" "${VIEW_DIR}" "${STATE_ENV}" <<'PY'
import sys, pathlib
mid, view, state = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
cfg = view / "public" / "baas-config.js"
if cfg.exists():
    s = cfg.read_text()
    if "mongoDbId" not in s:
        cfg.write_text(s.replace("pgDbId:", f'mongoDbId: "{mid}",\n  pgDbId:', 1))
env = view / ".env"
if env.exists():
    e = env.read_text()
    if "VITE_BAAS_MONGO_DB_ID" not in e:
        env.write_text(e.rstrip() + f"\nVITE_BAAS_MONGO_DB_ID={mid}\n")
t = state.read_text()
if "VG_MONGO_DB_ID" not in t:
    state.write_text(t.rstrip() + f"\nVG_MONGO_DB_ID={mid}\n")
print(f"[gourmand-mongo] wired mongoDbId={mid}")
PY

# ── 7) verify readability through Grobase ────────────────────────────────────
gq events '{"op":"list","limit":200}' >/dev/null
n="$(python3 -c 'import json;print(len(json.load(open("/tmp/gm-q.json")).get("rows",[])))' 2>/dev/null || echo 0)"
[[ "${n}" -ge 120 ]] || fail "expected ≥120 events readable through Grobase, got ${n}"
cyan "DONE: mongo mount ${MONGO_DB_ID} — ${n} events readable through the gateway"
