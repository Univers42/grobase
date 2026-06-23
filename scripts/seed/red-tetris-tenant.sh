#!/usr/bin/env bash
# **************************************************************************** #
#  red-tetris-tenant.sh — seed the red-tetris competitive platform on Grobase  #
#                                                                              #
#  Runs AFTER scripts/provision-contract.sh has created the `red-tetris`       #
#  tenant + the `red-tetris-pg` Postgres mount + applied red-tetris.schema.sql #
#  (it is the contract's `seed.script`, also runnable standalone). It:         #
#    • patches the PG mount's shared_resources so the leaderboard / profiles /  #
#      standings / ratings / tiers / seasons are world-readable (the contract   #
#      cannot set this; read_scoped=true would otherwise blank them);          #
#    • registers a Mongo mount (game replays/events) + a Redis mount (hot      #
#      leaderboard cache) — the contract can't (its DSN builder is PG-only);   #
#    • creates an `avatars` storage bucket;                                    #
#    • seeds GoTrue demo users + profiles + league tiers + an active season +  #
#      historical games (the apply_game_result trigger derives stats/ratings)  #
#      + an initial standings snapshot, so the leaderboard/leagues are alive;  #
#    • mints a realtime token + emits vendor/red-tetris/public/baas-config.js. #
#  Idempotent: re-runs converge (ON CONFLICT upserts, mount/user reuse).       #
#  Demo password for every account: Tetris#2026                                #
# **************************************************************************** #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/service-auth.sh
source "${SCRIPT_DIR}/../lib/service-auth.sh"
# shellcheck source=../lib/lib-live-tenant.sh
source "${SCRIPT_DIR}/../lib/lib-live-tenant.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATE_ENV="${REPO_ROOT}/.red-tetris-baas.env"
PUBLIC_DIR="${REPO_ROOT}/vendor/red-tetris/public"
TENANT_SLUG="red-tetris"
RT_DB="red-tetris"
PG_CTN="${PG_CTN:-mini-baas-postgres}"
MONGO_CTN="mini-baas-mongo"
MONGO_DB="red-tetris"
MONGO_MOUNT="red-tetris-mongo"
REDIS_MOUNT="red-tetris-redis"
PG_MOUNT="red-tetris-pg"
NODE_IMAGE="${NODE_IMAGE:-node:20-alpine}"
DEMO_PASS="Tetris#2026"

# World-readable across users: the leaderboard, any player's profile, league
# reference data, ratings and the classement. `games` stays owner-scoped.
SHARED_RESOURCES='["profiles","player_stats","ratings","league_tiers","seasons","standings","games_leaderboard"]'

# email|username|first|last|country
DEMO_USERS=(
  "alice@tetris.local|alice|Alice|Martin|France"
  "bob@tetris.local|bob|Bob|Nguyen|Vietnam"
  "carol@tetris.local|carol|Carol|Dubois|Canada"
  "dave@tetris.local|dave|Dave|Smith|USA"
  "eve@tetris.local|eve|Eve|Kowalski|Poland"
  "frank@tetris.local|frank|Frank|Yamamoto|Japan"
  "grace@tetris.local|grace|Grace|Silva|Brazil"
  "heidi@tetris.local|heidi|Heidi|Mueller|Germany"
)

cyan() { printf '\033[0;36m[red-tetris] %s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m[red-tetris] WARN: %s\033[0m\n' "$*" >&2; }
fail() { printf '\033[0;31m[red-tetris] FAIL: %s\033[0m\n' "$*" >&2; exit 1; }

# mint_jwt SECRET SUB — HS256 realtime WS token (role authenticated, 30 days).
# Carries explicit realtime grants (namespaces ["*"], can_publish/can_subscribe)
# so this shared WS token may BROADCAST + TRACK presence — GoTrue user tokens
# default can_publish=false, hence the game WS uses this token; per-user identity
# rides in the presence meta and DB writes keep the user's own GoTrue token.
mint_jwt() {
  docker run --rm --network none -e JWT_SECRET="$1" -e JWT_SUB="$2" "${NODE_IMAGE}" node -e '
const { createHmac } = require("node:crypto");
const b64u = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const head = b64u({ alg: "HS256", typ: "JWT" });
const body = b64u({ iss: "supabase", sub: process.env.JWT_SUB, role: "authenticated",
  namespaces: ["*"], can_publish: true, can_subscribe: true,
  exp: Math.floor(Date.now() / 1000) + 30 * 86400 });
const sig = createHmac("sha256", process.env.JWT_SECRET).update(`${head}.${body}`).digest("base64url");
console.log(`${head}.${body}.${sig}`);'
}

psql_rt()    { docker exec -i -e PGPASSWORD="${PG_PASS}" "${PG_CTN}" psql -U "${PG_USER}" -d "${RT_DB}"  -v ON_ERROR_STOP=1 -tA "$@"; }
psql_admin() { docker exec -i -e PGPASSWORD="${PG_PASS}" "${PG_CTN}" psql -U "${PG_USER}" -d postgres   -v ON_ERROR_STOP=1 -tA "$@"; }
mongosh_eval() { docker exec -i "${MONGO_CTN}" mongosh -u "${MUSER}" -p "${MPASS}" --authenticationDatabase admin --quiet --eval "$1"; }

# ── 0) endpoints + secrets from the running stack ────────────────────────────
kong_port="$(_lt_host_port mini-baas-kong 8000/tcp)"
tc_port="$(_lt_host_port mini-baas-tenant-control 3022/tcp)"
[[ -n "${kong_port}" && -n "${tc_port}" ]] || fail "stack not running (kong/tenant-control)"
KONG_URL="http://127.0.0.1:${kong_port}"
TC_URL="http://127.0.0.1:${tc_port}"
export SERVICE_TOKEN="$(_lt_env mini-baas-tenant-control INTERNAL_SERVICE_TOKEN)"
ANON_KEY="${ANON_KEY:-$(_lt_env mini-baas-kong KONG_PUBLIC_API_KEY)}"
SERVICE_KEY="$(_lt_env mini-baas-kong KONG_SERVICE_API_KEY)"
RT_JWT_SECRET="$(_lt_env mini-baas-realtime REALTIME_JWT_SECRET)"
PG_USER="${PG_USER:-$(_lt_env "${PG_CTN}" POSTGRES_USER)}"; PG_USER="${PG_USER:-postgres}"
PG_PASS="${PG_PASS:-$(_lt_env "${PG_CTN}" POSTGRES_PASSWORD)}"; PG_PASS="${PG_PASS:-postgres}"
MUSER="$(_lt_env "${MONGO_CTN}" MONGO_INITDB_ROOT_USERNAME)"; MUSER="${MUSER:-mongo}"
MPASS="$(_lt_env "${MONGO_CTN}" MONGO_INITDB_ROOT_PASSWORD)"; MPASS="${MPASS:-mongo}"
[[ -n "${SERVICE_TOKEN}" && -n "${ANON_KEY}" && -n "${SERVICE_KEY}" ]] || fail "stack secrets not found"

# API key: prefer the provisioner-passed one, else the contract emit, else state.
API_KEY="${API_KEY:-}"
if [[ -z "${API_KEY}" && -f "${REPO_ROOT}/build/red-tetris.env" ]]; then
  API_KEY="$(grep -hoE 'PUBLIC_API_KEY=mbk_[A-Za-z0-9_-]+' "${REPO_ROOT}/build/red-tetris.env" 2>/dev/null | head -1 | cut -d= -f2-)"
fi
[[ -n "${API_KEY:-}" && -f "${STATE_ENV}" ]] || true
if [[ -z "${API_KEY:-}" && -f "${STATE_ENV}" ]]; then source "${STATE_ENV}"; API_KEY="${RT_API_KEY:-}"; fi
[[ "${API_KEY:-}" == mbk_* ]] || fail "no app key (run scripts/provision-contract.sh first)"

# ── 1) patch PG mount shared_resources (the contract can't set this) ──────────
PG_DB_ID="$(curl -s "${KONG_URL}/admin/v1/databases" -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${TENANT_SLUG}" \
  | jq -r --arg n "${PG_MOUNT}" '.[]? | select(.name==$n) | .id' | head -1)"
[[ -n "${PG_DB_ID}" ]] || fail "PG mount '${PG_MOUNT}' not found (provision the contract first)"
psql_admin -c "UPDATE public.tenant_databases SET shared_resources='${SHARED_RESOURCES}'::jsonb WHERE id='${PG_DB_ID}' AND tenant_id='${TENANT_SLUG}';" >/dev/null
cyan "PG mount ${PG_DB_ID}: shared_resources patched (world-readable leaderboard)"

# ── 2) Mongo + Redis mounts (seed-registered; contract DSN builder is PG-only) ─
register_mount() { # $1 engine, $2 name, $3 dsn, $4 shared_json(or "")
  local body
  if [[ -n "${4:-}" ]]; then body="{\"engine\":\"$1\",\"name\":\"$2\",\"connection_string\":\"$3\",\"shared_resources\":$4}"
  else body="{\"engine\":\"$1\",\"name\":\"$2\",\"connection_string\":\"$3\"}"; fi
  REG_ID=""
  REG_CODE=$(curl -s -o /tmp/rt-mount.json -w '%{http_code}' -X POST "${KONG_URL}/admin/v1/databases" \
    -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${TENANT_SLUG}" -H 'Content-Type: application/json' -d "${body}")
  if [[ "${REG_CODE}" == "201" ]]; then REG_ID="$(_lt_json_field id </tmp/rt-mount.json)"
  elif [[ "${REG_CODE}" == "409" ]]; then
    REG_ID="$(curl -fsS "${KONG_URL}/admin/v1/databases" -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${TENANT_SLUG}" \
      | jq -r --arg n "$2" '.[]? | select(.name==$n) | .id' | head -1)"; fi
}

MONGO_DB_ID=""; REDIS_DB_ID=""
register_mount mongodb "${MONGO_MOUNT}" "mongodb://${MUSER}:${MPASS}@mongo:27017/${MONGO_DB}?authSource=admin" '["replays"]'
if [[ "${REG_CODE}" == "201" || "${REG_CODE}" == "409" ]]; then MONGO_DB_ID="${REG_ID}"; cyan "mongo mount = ${MONGO_DB_ID}"
else warn "mongo mount not registered (${REG_CODE}) — replays disabled until 'data' plane is up"; fi

register_mount redis "${REDIS_MOUNT}" "redis://redis:6379" ""
if [[ "${REG_CODE}" == "201" || "${REG_CODE}" == "409" ]]; then REDIS_DB_ID="${REG_ID}"; cyan "redis mount = ${REDIS_DB_ID}"
else warn "redis mount not registered (${REG_CODE}) — hot cache disabled (Phase 6)"; fi

# Mongo replay collection (idempotent) — only if the mount + mongo are up.
if [[ -n "${MONGO_DB_ID}" ]]; then
  mongosh_eval "
  const db = db.getSiblingDB('${MONGO_DB}');
  if (!db.getCollectionNames().includes('replays')) db.createCollection('replays');
  db.replays.createIndex({ game_id: 1 }, { unique: true });
  db.replays.createIndex({ player_id: 1, created_at: -1 });
  print('replays ok');" >/dev/null 2>&1 || warn "mongo replays collection ensure failed (continuing)"
fi

# ── 3) avatars storage bucket (tolerant — storage plane/route may be off) ─────
# storage-router verifies with the shared JWT_SECRET (no dedicated STORAGE_JWT_SECRET).
STORAGE_SECRET="$(_lt_env mini-baas-storage-router JWT_SECRET 2>/dev/null || true)"
if [[ -n "${STORAGE_SECRET}" ]]; then
  STOR_TOKEN="$(mint_jwt "${STORAGE_SECRET}" red-tetris-app)"
  bcode=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${KONG_URL}/storage/v1/bucket" \
    -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${STOR_TOKEN}" -H 'Content-Type: application/json' \
    -d '{"name":"avatars","public":true}' 2>/dev/null || true)
  case "${bcode}" in
    2*|409) cyan "avatars bucket ready (HTTP ${bcode})" ;;
    *)      warn "avatars bucket skipped (storage route → HTTP ${bcode:-000}); profile falls back to initials" ;;
  esac
else warn "storage-router not up — skipping avatars bucket (Phase 6)"; fi

# ── 4) league tiers + active season (idempotent reference data) ──────────────
psql_rt <<'SQL' >/dev/null
INSERT INTO public.league_tiers (tier, min_rating, max_rating, rank_order, color) VALUES
  ('Bronze',   0,    1099,    1, '#cd7f32'),
  ('Silver',   1100, 1299,    2, '#c0c0c0'),
  ('Gold',     1300, 1499,    3, '#ffd700'),
  ('Platinum', 1500, 1799,    4, '#5fd0e0'),
  ('Diamond',  1800, 100000,  5, '#7af0ff')
ON CONFLICT (tier) DO UPDATE SET min_rating=EXCLUDED.min_rating, max_rating=EXCLUDED.max_rating,
  rank_order=EXCLUDED.rank_order, color=EXCLUDED.color;
INSERT INTO public.seasons (name, active) SELECT 'Season 1', true
  WHERE NOT EXISTS (SELECT 1 FROM public.seasons WHERE active);
SQL
cyan "league tiers + active season seeded"

# ── 5) GoTrue demo users + profiles ──────────────────────────────────────────
declare -A SUBS=()
for spec in "${DEMO_USERS[@]}"; do
  IFS='|' read -r email username first last country <<<"${spec}"
  code=$(curl -s -o /tmp/rt-user.json -w '%{http_code}' -X POST "${KONG_URL}/auth/v1/admin/users" \
    -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${SERVICE_KEY}" -H 'Content-Type: application/json' \
    -d "{\"email\":\"${email}\",\"password\":\"${DEMO_PASS}\",\"email_confirm\":true,\"user_metadata\":{\"username\":\"${username}\",\"first_name\":\"${first}\",\"last_name\":\"${last}\"}}")
  sub=""
  if [[ "${code}" == "200" || "${code}" == "201" ]]; then sub="$(_lt_json_field id </tmp/rt-user.json)"
  else
    sub="$(EMAIL="${email}" KURL="${KONG_URL}" ANON="${ANON_KEY}" SVC="${SERVICE_KEY}" python3 -c '
import json,os,urllib.request
email,base,anon,svc=os.environ["EMAIL"],os.environ["KURL"],os.environ["ANON"],os.environ["SVC"]
def page(n):
  req=urllib.request.Request(f"{base}/auth/v1/admin/users?page={n}&per_page=200",headers={"apikey":anon,"Authorization":f"Bearer {svc}"})
  with urllib.request.urlopen(req,timeout=10) as r: return json.load(r).get("users",[])
f=""
for n in range(1,26):
  try: us=page(n)
  except Exception: break
  if not us: break
  m=next((u.get("id","") for u in us if u.get("email")==email),"")
  if m: f=m; break
print(f)' 2>/dev/null)"
  fi
  [[ -n "${sub}" ]] || fail "could not create/find GoTrue user ${email} (${code})"
  SUBS["${email}"]="${sub}"
  psql_rt -c "INSERT INTO public.profiles (id, owner_id, username, first_name, last_name, country)
    VALUES ('${sub}','user:${sub}','${username}','${first}','${last}','${country}')
    ON CONFLICT (id) DO UPDATE SET username=EXCLUDED.username, first_name=EXCLUDED.first_name,
      last_name=EXCLUDED.last_name, country=EXCLUDED.country;" >/dev/null
  cyan "user ${email} → ${sub:0:8}… (${username})"
done

# ── 6) historical games (trigger derives player_stats + ratings) ─────────────
SEASON_ID="$(psql_rt -c "SELECT id FROM public.seasons WHERE active LIMIT 1;")"
for spec in "${DEMO_USERS[@]}"; do
  IFS='|' read -r email _ _ _ _ <<<"${spec}"
  sub="${SUBS[${email}]}"
  # 6 seeded games per player with varied score/lines/won — only seed once.
  have="$(psql_rt -c "SELECT count(*) FROM public.games WHERE player_id='${sub}';")"
  [[ "${have}" -gt 0 ]] && continue
  psql_rt >/dev/null <<SQL
INSERT INTO public.games (owner_id, player_id, mode, score, lines, level, duration_s, won, ended_at)
SELECT 'user:${sub}', '${sub}', 'solo',
       (200 + (random()*4800))::int, (1 + (random()*40))::int, (1 + (random()*9))::int,
       (60 + (random()*540))::int, (random() < 0.4),
       now() - (random()*30 || ' days')::interval
FROM generate_series(1,6);
SQL
done
cyan "historical games seeded (player_stats + ratings derived by trigger)"

# ── 7) initial standings snapshot (Phase 4 scheduler keeps it fresh) ─────────
psql_rt >/dev/null <<SQL
INSERT INTO public.standings (season_id, player_id, owner_id, league_tier, rank, global_rank, rating, points)
SELECT '${SEASON_ID}', r.player_id, r.owner_id, r.league_tier,
       rank() OVER (PARTITION BY r.league_tier ORDER BY r.rating DESC),
       rank() OVER (ORDER BY r.rating DESC),
       r.rating, GREATEST(0, 1000 - rank() OVER (ORDER BY r.rating DESC))
FROM public.ratings r
ON CONFLICT (season_id, player_id) DO UPDATE SET
  league_tier=EXCLUDED.league_tier, rank=EXCLUDED.rank, global_rank=EXCLUDED.global_rank,
  rating=EXCLUDED.rating, points=EXCLUDED.points, updated_at=now();
SQL
cyan "standings snapshot computed"

# ── 8) realtime token + frontend config + state ──────────────────────────────
RT_TOKEN=""
[[ -n "${RT_JWT_SECRET}" ]] && RT_TOKEN="$(mint_jwt "${RT_JWT_SECRET}" red-tetris-app)"

mkdir -p "${PUBLIC_DIR}"
cyan "writing ${PUBLIC_DIR}/baas-config.js"
cat >"${PUBLIC_DIR}/baas-config.js" <<EOF
// generated by scripts/seed/red-tetris-tenant.sh — $(date -Iseconds) — DO NOT COMMIT
window.__BAAS__ = {
  url: "${KONG_URL}",
  anonKey: "${ANON_KEY}",
  apiKey: "${API_KEY}",
  tenantId: "${TENANT_SLUG}",
  pgDbId: "${PG_DB_ID}",
  mongoDbId: "${MONGO_DB_ID}",
  redisDbId: "${REDIS_DB_ID}",
  realtimeToken: "${RT_TOKEN}",
  storageBucket: "avatars"
};
EOF

cat >"${STATE_ENV}" <<EOF
# generated by scripts/seed/red-tetris-tenant.sh — $(date -Iseconds)
RT_TENANT_SLUG=${TENANT_SLUG}
RT_API_KEY=${API_KEY}
RT_PG_DB_ID=${PG_DB_ID}
RT_MONGO_DB_ID=${MONGO_DB_ID}
RT_REDIS_DB_ID=${REDIS_DB_ID}
RT_KONG_URL=${KONG_URL}
RT_ANON_APIKEY=${ANON_KEY}
RT_SERVICE_APIKEY=${SERVICE_KEY}
RT_REALTIME_TOKEN=${RT_TOKEN}
EOF
chmod 600 "${STATE_ENV}"
printf '\033[0;32m[red-tetris] DONE — tenant=%s pg=%s mongo=%s redis=%s\n' \
  "${TENANT_SLUG}" "${PG_DB_ID}" "${MONGO_DB_ID:-<off>}" "${REDIS_DB_ID:-<off>}"
printf '[red-tetris] demo logins: alice@tetris.local … heidi@tetris.local  /  %s\033[0m\n' "${DEMO_PASS}"
