#!/usr/bin/env bash
# **************************************************************************** #
#  hypertube-tenant.sh — provision Hypertube (42 subject) on Grobase          #
#                                                                              #
#  Re-platforms the Hypertube BitTorrent video app onto Grobase: a dedicated  #
#  `hypertube` tenant, an mbk_ app key, a MongoDB mount (catalog/comments/     #
#  profiles/subtitles — shared_resources so the catalog + public profiles are  #
#  world-readable) and a DynamoDB mount (per-user watch_state + server-side    #
#  media_jobs). Auth is GoTrue (42 + Google OAuth, email/password). The        #
#  torrent/stream/transcode + search + RESTful API are custom Grobase services #
#  (vendor/hypertube/grobase/*) — this script only wires the data + auth.      #
#                                                                              #
#  MongoDB is the proven half and lights up immediately. DynamoDB is enabled   #
#  by the P1 hardening workstream (data plane built --features dynamodb +       #
#  "dynamodb" in isAllowedEngine + a dynamodb-local service); until then the    #
#  Dynamo mount registration WARNS and the script still completes the Mongo    #
#  half. Idempotent: re-runs reuse the key + mounts.                           #
#                                                                              #
#  Emits vendor/hypertube/View/{public/baas-config.js,.env} + a gitignored     #
#  state file (.hypertube-baas.env, mode 600).                                 #
# **************************************************************************** #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/service-auth.sh
source "${SCRIPT_DIR}/../lib/service-auth.sh"
# shellcheck source=../lib/lib-live-tenant.sh
source "${SCRIPT_DIR}/../lib/lib-live-tenant.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATE_ENV="${REPO_ROOT}/.hypertube-baas.env"
VIEW_DIR="${REPO_ROOT}/vendor/hypertube/View"
MONGO_CTN="mini-baas-mongo"
MONGO_NET_HOST="mongo"
MONGO_DB="hypertube"
MONGO_MOUNT="hypertube-mongo"
DYNAMO_MOUNT="hypertube-dynamo"
# The data plane dials this in-network host (the dynamodb-local service added by
# the hypertube compose profile). Static creds: dynamodb-local accepts any.
DYNAMO_DSN="dynamodb://local?endpoint=http://dynamodb-local:8000&region=us-east-1&access_key=fake&secret_key=fake"
TENANT_SLUG="hypertube"
NODE_IMAGE="${NODE_IMAGE:-node:20-alpine}"

# Catalog + public-profile + comment + subtitle collections skip owner-scoping
# (world-readable across users): the library grid, any-user profile view, and
# the prior-comment list are cross-owner by the subject's contract.
SHARED_RESOURCES='["movies","profiles","comments","subtitles"]'

# Real demo accounts (GoTrue, email-confirmed): email|password|username|first|last
DEMO_USERS=(
  "alice@hypertube.local|Hypertube#2026|alice|Alice|Martin"
  "bob@hypertube.local|Hypertube#2026|bob|Bob|Nguyen"
  "carol@hypertube.local|Hypertube#2026|carol|Carol|Dubois"
)

cyan() { printf '\033[0;36m[hypertube-tenant] %s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m[hypertube-tenant] WARN: %s\033[0m\n' "$*" >&2; }
fail() {
  printf '\033[0;31m[hypertube-tenant] FAIL: %s\033[0m\n' "$*" >&2
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

mongosh_eval() {
  docker exec -i "${MONGO_CTN}" mongosh -u "${MUSER}" -p "${MPASS}" \
    --authenticationDatabase admin --quiet --eval "$1"
}

# ── 0) endpoints + secrets from the running stack ────────────────────────────
kong_port="$(_lt_host_port mini-baas-kong 8000/tcp)"
tc_port="$(_lt_host_port mini-baas-tenant-control 3022/tcp)"
[[ -n "${kong_port}" && -n "${tc_port}" ]] || fail "mini-baas stack not running (kong/tenant-control ports)"
KONG_URL="http://127.0.0.1:${kong_port}"
TC_URL="http://127.0.0.1:${tc_port}"
export SERVICE_TOKEN="$(_lt_env mini-baas-tenant-control INTERNAL_SERVICE_TOKEN)"
ANON_KEY="$(_lt_env mini-baas-kong KONG_PUBLIC_API_KEY)"
SERVICE_KEY="$(_lt_env mini-baas-kong KONG_SERVICE_API_KEY)"
RT_JWT_SECRET="$(_lt_env mini-baas-realtime REALTIME_JWT_SECRET)"
MUSER="$(_lt_env "${MONGO_CTN}" MONGO_INITDB_ROOT_USERNAME)"; MUSER="${MUSER:-mongo}"
MPASS="$(_lt_env "${MONGO_CTN}" MONGO_INITDB_ROOT_PASSWORD)"; MPASS="${MPASS:-mongo}"
[[ -n "${SERVICE_TOKEN}" && -n "${ANON_KEY}" && -n "${SERVICE_KEY}" ]] || fail "stack secrets not found"

# ── 1) tenant + enterprise ceiling + entitlement(mongodb, dynamodb) ──────────
cyan "ensuring tenant '${TENANT_SLUG}'"
tbody="{\"id\":\"${TENANT_SLUG}\",\"name\":\"Hypertube\"}"
svc_auth POST /v1/tenants "${tbody}"
code=$(curl -s -o /tmp/ht-tenant.json -w '%{http_code}' -X POST "${TC_URL}/v1/tenants" \
  "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${tbody}")
[[ "${code}" == "201" || "${code}" == "409" ]] || fail "tenant create (${code}): $(cat /tmp/ht-tenant.json)"

pbody='{"plan":"enterprise"}'
svc_auth PATCH "/v1/tenants/${TENANT_SLUG}" "${pbody}"
curl -s -o /dev/null -X PATCH "${TC_URL}/v1/tenants/${TENANT_SLUG}" \
  "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${pbody}" || true

ebody='{"ceiling_plan":"enterprise","status":"active","entitlement":{"label":"hypertube","engines":["mongodb","dynamodb"],"capabilities":{"read":true,"write":true,"insert":true,"update":true,"delete":true,"upsert":true,"aggregate":true},"addons":["realtime"],"max_mounts":3}}'
svc_auth PUT "/v1/tenants/${TENANT_SLUG}/entitlement" "${ebody}"
curl -s -o /dev/null -X PUT "${TC_URL}/v1/tenants/${TENANT_SLUG}/entitlement" \
  "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${ebody}" || true

# ── 2) API key — reuse from state if still valid, else mint ──────────────────
API_KEY=""; KEY_ID=""; MONGO_DB_ID=""; DYNAMO_DB_ID=""
if [[ -f "${STATE_ENV}" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_ENV}"
  API_KEY="${HT_API_KEY:-}"; KEY_ID="${HT_KEY_ID:-}"
  MONGO_DB_ID="${HT_MONGO_DB_ID:-}"; DYNAMO_DB_ID="${HT_DYNAMO_DB_ID:-}"
fi
# Validate the state key against the CONTROL PLANE (key exists + not revoked),
# NOT a data-plane query: a transiently-stale data-plane pool must never make us
# re-mint, because a new key_id re-owns nothing and ORPHANS every row the old
# key principal wrote (owner_id = api-key:<old id>). Reuse keeps ownership stable.
key_reuse=0
if [[ -n "${API_KEY}" && -n "${KEY_ID}" && -n "${MONGO_DB_ID}" ]]; then
  svc_auth GET "/v1/tenants/${TENANT_SLUG}/keys" ""
  curl -s "${TC_URL}/v1/tenants/${TENANT_SLUG}/keys" "${SVC_AUTH[@]}" -o /tmp/ht-keys.json 2>/dev/null || true
  KID="${KEY_ID}" python3 -c '
import json,os,sys
try:
  ks=json.load(open("/tmp/ht-keys.json"))
  sys.exit(0 if any(r.get("id")==os.environ["KID"] and not r.get("revoked_at") for r in ks) else 1)
except Exception: sys.exit(1)' && key_reuse=1
fi
if [[ "${key_reuse}" == "1" ]]; then
  cyan "reusing existing key ${KEY_ID:0:8}… + mongo mount (${MONGO_DB_ID})"
else
  # A prior failed run can leave a 'hypertube-app' key whose cleartext we never
  # captured (returned only once at mint). Revoke it so the re-mint never 400s
  # on a name collision — true idempotency across a mid-run failure.
  cyan "purging any stale 'hypertube-app' key"
  svc_auth GET "/v1/tenants/${TENANT_SLUG}/keys" ""
  curl -s "${TC_URL}/v1/tenants/${TENANT_SLUG}/keys" "${SVC_AUTH[@]}" -o /tmp/ht-keys.json || true
  for kid in $(python3 -c '
import json
try:
  for r in json.load(open("/tmp/ht-keys.json")):
    if r.get("name")=="hypertube-app" and not r.get("revoked_at"): print(r["id"])
except Exception: pass'); do
    svc_auth DELETE "/v1/tenants/${TENANT_SLUG}/keys/${kid}" ""
    curl -s -o /dev/null -X DELETE "${TC_URL}/v1/tenants/${TENANT_SLUG}/keys/${kid}" "${SVC_AUTH[@]}" || true
  done

  cyan "minting API key (scopes read,write)"
  kbody='{"name":"hypertube-app","scopes":["read","write"]}'
  svc_auth POST "/v1/tenants/${TENANT_SLUG}/keys" "${kbody}"
  code=$(curl -s -o /tmp/ht-key.json -w '%{http_code}' -X POST \
    "${TC_URL}/v1/tenants/${TENANT_SLUG}/keys" \
    "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${kbody}")
  [[ "${code}" == "201" ]] || fail "key mint (${code}): $(cat /tmp/ht-key.json)"
  API_KEY="$(_lt_json_field key </tmp/ht-key.json)"
  KEY_ID="$(_lt_json_field id </tmp/ht-key.json)"
  [[ "${API_KEY}" == mbk_* ]] || fail "minted key has unexpected shape"
fi

# ── 3) MongoDB mount (shared_resources for catalog/profiles/comments/subs) ───
# register_mount sets two GLOBALS (REG_CODE, REG_ID) rather than echoing, so the
# status survives — a $(…) subshell would discard a plain variable assignment.
register_mount() { # $1 engine, $2 name, $3 dsn, $4 shared_json(or "")
  local body
  if [[ -n "${4:-}" ]]; then
    body="{\"engine\":\"$1\",\"name\":\"$2\",\"connection_string\":\"$3\",\"shared_resources\":$4}"
  else
    body="{\"engine\":\"$1\",\"name\":\"$2\",\"connection_string\":\"$3\"}"
  fi
  REG_ID=""
  REG_CODE=$(curl -s -o /tmp/ht-mount.json -w '%{http_code}' -X POST "${KONG_URL}/admin/v1/databases" \
    -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${TENANT_SLUG}" \
    -H 'Content-Type: application/json' -d "${body}")
  if [[ "${REG_CODE}" == "201" ]]; then
    REG_ID="$(_lt_json_field id </tmp/ht-mount.json)"
  elif [[ "${REG_CODE}" == "409" ]]; then
    REG_ID="$(curl -fsS "${KONG_URL}/admin/v1/databases" -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${TENANT_SLUG}" \
      | MNT="$2" python3 -c 'import json,sys,os; print(next((r["id"] for r in json.load(sys.stdin) if r.get("name")==os.environ["MNT"]),""))')"
  fi
}

if [[ -z "${MONGO_DB_ID}" ]] \
  || [[ "$(curl -s -o /dev/null -w '%{http_code}' "${KONG_URL}/query/v1/${MONGO_DB_ID}/schema" \
      -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: ${API_KEY}")" != "200" ]]; then
  cyan "registering mongo mount '${MONGO_MOUNT}' → ${MONGO_DB}"
  dsn="mongodb://${MUSER}:${MPASS}@${MONGO_NET_HOST}:27017/${MONGO_DB}?authSource=admin"
  register_mount mongodb "${MONGO_MOUNT}" "${dsn}" "${SHARED_RESOURCES}"
  [[ "${REG_CODE}" == "201" || "${REG_CODE}" == "409" ]] || fail "mongo mount register (${REG_CODE}): $(cat /tmp/ht-mount.json)"
  MONGO_DB_ID="${REG_ID}"
  [[ -n "${MONGO_DB_ID}" ]] || fail "no mongo mount id"
fi
cyan "mongo mount = ${MONGO_DB_ID}"

# ── 4) Mongo collections + $jsonSchema validators + indexes (idempotent) ─────
cyan "ensuring collections (movies, comments, profiles, subtitles) + validators"
mongosh_eval "
const db = db.getSiblingDB('${MONGO_DB}');
function ensure(name, schema, indexes) {
  const exists = db.getCollectionNames().includes(name);
  if (!exists) db.createCollection(name, { validator: { \$jsonSchema: schema } });
  else db.runCommand({ collMod: name, validator: { \$jsonSchema: schema }, validationLevel: 'moderate' });
  (indexes || []).forEach(ix => db[name].createIndex(ix.key, ix.opts || {}));
}
ensure('movies', { bsonType:'object', required:['movie_id','title','source'],
  properties:{ movie_id:{bsonType:'string'}, title:{bsonType:'string'}, source:{bsonType:'string'},
    popularity:{bsonType:['double','int','long']} } },
  [{key:{movie_id:1}, opts:{unique:true}}, {key:{popularity:-1}}, {key:{title:1}}]);
ensure('comments', { bsonType:'object', required:['movie_id','author_id','author_username','content','created_at'],
  properties:{ movie_id:{bsonType:'string'}, author_id:{bsonType:'string'},
    author_username:{bsonType:'string'}, content:{bsonType:'string'} } },
  [{key:{movie_id:1, created_at:-1}}, {key:{created_at:-1}}]);
ensure('profiles', { bsonType:'object', required:['user_id','username'],
  properties:{ user_id:{bsonType:'string'}, username:{bsonType:'string'},
    preferred_lang:{bsonType:'string'} } },
  [{key:{user_id:1}, opts:{unique:true}}, {key:{username:1}, opts:{unique:true}}]);
ensure('subtitles', { bsonType:'object', required:['movie_id','lang','url'],
  properties:{ movie_id:{bsonType:'string'}, lang:{bsonType:'string'}, url:{bsonType:'string'} } },
  [{key:{movie_id:1, lang:1}, opts:{unique:true}}]);
print('collections=' + db.getCollectionNames().filter(n => ['movies','comments','profiles','subtitles'].includes(n)).length);
" >&2 || warn "collection ensure had non-zero output (continuing)"

# ── 5) DynamoDB mount (tolerant until P1 enables the engine) ──────────────────
if [[ -n "${DYNAMO_DB_ID}" ]] \
  && [[ "$(curl -s -o /dev/null -w '%{http_code}' "${KONG_URL}/query/v1/${DYNAMO_DB_ID}/schema" \
      -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: ${API_KEY}")" == "200" ]]; then
  cyan "reusing dynamo mount ${DYNAMO_DB_ID}"
else
  cyan "registering dynamo mount '${DYNAMO_MOUNT}'"
  register_mount dynamodb "${DYNAMO_MOUNT}" "${DYNAMO_DSN}" ""
  if [[ "${REG_CODE}" == "201" || "${REG_CODE}" == "409" ]] && [[ -n "${REG_ID}" ]]; then
    DYNAMO_DB_ID="${REG_ID}"
    cyan "dynamo mount = ${DYNAMO_DB_ID}"
  else
    DYNAMO_DB_ID=""
    warn "dynamo mount not registered (${REG_CODE}): $(head -c 160 /tmp/ht-mount.json)"
    warn "→ enable DynamoDB first (P1: isAllowedEngine + --features dynamodb + dynamodb-local), then re-run."
  fi
fi

# ── 5b) pre-create the DynamoDB tables (Dynamo has no schema_ddl) — idempotent ─
if [[ -n "${DYNAMO_DB_ID}" ]]; then
  DDB_NET="$(docker inspect mini-baas-dynamodb-local \
    --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null | head -1)"
  if [[ -n "${DDB_NET}" ]]; then
    for tbl in watch_state media_jobs; do
      docker run --rm --network "${DDB_NET}" \
        -e AWS_ACCESS_KEY_ID=fake -e AWS_SECRET_ACCESS_KEY=fake -e AWS_DEFAULT_REGION=us-east-1 \
        amazon/aws-cli dynamodb create-table --endpoint-url http://dynamodb-local:8000 \
        --table-name "${tbl}" \
        --attribute-definitions AttributeName=owner_pk,AttributeType=S AttributeName=id,AttributeType=S \
        --key-schema AttributeName=owner_pk,KeyType=HASH AttributeName=id,KeyType=RANGE \
        --billing-mode PAY_PER_REQUEST >/dev/null 2>&1 \
        && cyan "dynamo table ${tbl} created" || cyan "dynamo table ${tbl} present"
    done
  else
    warn "dynamodb-local container not found — bring up the hypertube profile to pre-create tables"
  fi
fi

# ── 6) GoTrue demo users + public profile docs (NO email in the profile) ─────
declare -A SUBS=()
for spec in "${DEMO_USERS[@]}"; do
  IFS='|' read -r email pass username first last <<<"${spec}"
  code=$(curl -s -o /tmp/ht-user.json -w '%{http_code}' -X POST "${KONG_URL}/auth/v1/admin/users" \
    -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${SERVICE_KEY}" -H 'Content-Type: application/json' \
    -d "{\"email\":\"${email}\",\"password\":\"${pass}\",\"email_confirm\":true,\"user_metadata\":{\"username\":\"${username}\",\"first_name\":\"${first}\",\"last_name\":\"${last}\"}}")
  sub=""
  if [[ "${code}" == "200" || "${code}" == "201" ]]; then
    sub="$(_lt_json_field id </tmp/ht-user.json)"
  else
    sub="$(EMAIL="${email}" KURL="${KONG_URL}" ANON="${ANON_KEY}" SVC="${SERVICE_KEY}" python3 -c '
import json,os,urllib.request
email,base,anon,svc=os.environ["EMAIL"],os.environ["KURL"],os.environ["ANON"],os.environ["SVC"]
def page(n):
  req=urllib.request.Request(f"{base}/auth/v1/admin/users?page={n}&per_page=200",
    headers={"apikey":anon,"Authorization":f"Bearer {svc}"})
  with urllib.request.urlopen(req,timeout=10) as r: return json.load(r).get("users",[])
found=""
for n in range(1,26):
  try: us=page(n)
  except Exception: break
  if not us: break
  m=next((u.get("id","") for u in us if u.get("email")==email),"")
  if m: found=m; break
print(found)' 2>/dev/null)"
  fi
  [[ -n "${sub}" ]] || fail "could not create/find GoTrue user ${email} (${code})"
  SUBS["${email}"]="${sub}"
  cyan "GoTrue ${email} → sub ${sub:0:8}… (username ${username})"
  # Public profile doc — email lives ONLY in GoTrue; never written here.
  mongosh_eval "
  db.getSiblingDB('${MONGO_DB}').profiles.updateOne(
    { user_id: '${sub}' },
    { \$set: { user_id:'${sub}', username:'${username}', first_name:'${first}', last_name:'${last}',
      avatar_url:null, info:'', preferred_lang:'en', owner_id:'user:${sub}', tenant_id:'${TENANT_SLUG}' } },
    { upsert: true });" >/dev/null 2>&1 || warn "profile upsert for ${username} non-zero (continuing)"
done

# ── 7) realtime token + frontend config + state ──────────────────────────────
RT_TOKEN=""
[[ -n "${RT_JWT_SECRET}" ]] && RT_TOKEN="$(mint_jwt "${RT_JWT_SECRET}" hypertube-app)"

mkdir -p "${VIEW_DIR}/public"
cyan "writing ${VIEW_DIR}/public/baas-config.js"
cat >"${VIEW_DIR}/public/baas-config.js" <<EOF
// generated by scripts/seed/hypertube-tenant.sh — $(date -Iseconds) — DO NOT COMMIT
window.__BAAS__ = {
  url: "${KONG_URL}",
  anonKey: "${ANON_KEY}",
  apiKey: "${API_KEY}",
  tenantId: "${TENANT_SLUG}",
  mongoDbId: "${MONGO_DB_ID}",
  dynamoDbId: "${DYNAMO_DB_ID}",
  realtimeToken: "${RT_TOKEN}"
};
EOF

cyan "writing ${VIEW_DIR}/.env (VITE_BAAS_*)"
cat >"${VIEW_DIR}/.env" <<EOF
# generated by scripts/seed/hypertube-tenant.sh — $(date -Iseconds)
VITE_BAAS_URL=${KONG_URL}
VITE_BAAS_KONG_KEY=${ANON_KEY}
VITE_BAAS_API_KEY=${API_KEY}
VITE_BAAS_TENANT_ID=${TENANT_SLUG}
VITE_BAAS_MONGO_DB_ID=${MONGO_DB_ID}
VITE_BAAS_DYNAMO_DB_ID=${DYNAMO_DB_ID}
VITE_BAAS_REALTIME_TOKEN=${RT_TOKEN}
EOF

# Custom-services env (consumed by the hypertube compose profile). The media +
# api services read movies/comments/media_jobs from the Mongo mount; watch_state
# lives in the Dynamo mount (written by the SPA). Stable OAuth/JWT secrets reuse
# from state if present, else generate once.
API_OAUTH_CLIENT_SECRET="${HT_API_OAUTH_CLIENT_SECRET:-$(openssl rand -hex 24)}"
API_JWT_SECRET_VAL="${HT_API_JWT_SECRET:-$(openssl rand -hex 32)}"
cat >"${REPO_ROOT}/vendor/hypertube/.services.env" <<EOF
# generated by scripts/seed/hypertube-tenant.sh — $(date -Iseconds) — DO NOT COMMIT
MEDIA_DB_ID=${MONGO_DB_ID}
MEDIA_ANON_APIKEY=${ANON_KEY}
MEDIA_APP_API_KEY=${API_KEY}
STREAM_DB_ID=${MONGO_DB_ID}
STREAM_ANON_APIKEY=${ANON_KEY}
STREAM_APP_API_KEY=${API_KEY}
API_MONGO_DB_ID=${MONGO_DB_ID}
API_ANON_APIKEY=${ANON_KEY}
API_APP_API_KEY=${API_KEY}
API_OAUTH_CLIENT_ID=hypertube
API_OAUTH_CLIENT_SECRET=${API_OAUTH_CLIENT_SECRET}
API_JWT_SECRET=${API_JWT_SECRET_VAL}
GOTRUE_SERVICE_KEY=${SERVICE_KEY}
EOF
chmod 600 "${REPO_ROOT}/vendor/hypertube/.services.env"

cat >"${STATE_ENV}" <<EOF
# generated by scripts/seed/hypertube-tenant.sh — $(date -Iseconds)
HT_TENANT_SLUG=${TENANT_SLUG}
HT_API_KEY=${API_KEY}
HT_KEY_ID=${KEY_ID}
HT_MONGO_DB_ID=${MONGO_DB_ID}
HT_DYNAMO_DB_ID=${DYNAMO_DB_ID}
HT_MONGO_DB_NAME=${MONGO_DB}
HT_KONG_URL=${KONG_URL}
HT_ANON_APIKEY=${ANON_KEY}
HT_SERVICE_APIKEY=${SERVICE_KEY}
HT_REALTIME_TOKEN=${RT_TOKEN}
HT_ALICE_SUB=${SUBS[alice@hypertube.local]:-}
HT_BOB_SUB=${SUBS[bob@hypertube.local]:-}
HT_CAROL_SUB=${SUBS[carol@hypertube.local]:-}
HT_API_OAUTH_CLIENT_SECRET=${API_OAUTH_CLIENT_SECRET}
HT_API_JWT_SECRET=${API_JWT_SECRET_VAL}
EOF
chmod 600 "${STATE_ENV}"
cyan "DONE: tenant=${TENANT_SLUG} mongo=${MONGO_DB_ID} dynamo=${DYNAMO_DB_ID:-<pending P1>} (state → ${STATE_ENV})"
