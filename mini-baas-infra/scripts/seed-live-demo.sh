#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    seed-live-demo.sh                                  :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/10 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/10 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Live-database demo seed (M22 / Phase 7): a realistic commerce+ops company
# spread across the three engines, owned by the osionos app's own API key so
# the notion-database-sys live mode can read AND edit every row.
#
#   pg-commerce    postgres `commerce` db — customers, products, employees,
#                  inventory, orders, order_items, edges (enums + FKs +
#                  updated_at triggers)
#   mysql-ops      mysql `ops` db — projects, tasks, tickets, time_entries
#                  (ENUM columns, FK constraints, tinyint(1) booleans)
#   mongo-activity mongo `activity` db — events, product_reviews, notes
#                  ($jsonSchema validators → exact introspection, enum kinds)
#
# Identity model (the part that makes edits work): the app authenticates with
# X-Baas-Api-Key only, so the data plane stamps owner_id = `api-key:<key uuid>`
# on writes and owner-scopes updates/deletes (MySQL/Mongo also scope reads).
# The seeder therefore (1) resolves the APP'S key → tenant + key uuid through
# tenant-control /v1/keys/verify, (2) registers the mounts under that tenant,
# and (3) stamps that exact principal on every bulk row. Control-plane steps
# go through the REAL gateway path; bulk data goes straight into the engines
# (the gateway insert op is single-row — 165k HTTP calls is not a seeder).
#
# Deterministic (PRNG seed 42, anchored clock) + idempotent (CREATE IF NOT
# EXISTS / ON CONFLICT DO NOTHING / INSERT IGNORE / insertMany ordered:false):
# run it twice, get identical counts. RESEED=1 drops the three demo databases
# first (destructive, demo data only).
#
# Usage:  make seed-live-demo            # from apps/baas/mini-baas-infra
#         RESEED=1 make seed-live-demo   # drop + reload from scratch
#         SEED_PAGES=0 ...               # skip the osionos workspace pages
# Env:    BAAS_API_KEY (defaults to VITE_BAAS_API_KEY from the app .env),
#         APP_ENV_FILE, SEED_SCALE, SKIP_ENV_WRITE=1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# v1 HMAC service auth (audit O1) — signs the tenant-control call under hmac mode.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/service-auth.sh"
BAAS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${BAAS_DIR}/../../.." && pwd)"
cd "${BAAS_DIR}"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[SEED] $*"; }
pass()  { green "[SEED] PASS: $*"; }
fail()  { red "[SEED] FAIL: $*"; exit 1; }

# Container-env / host-port / json helpers (shared with the verify gates).
# shellcheck source=scripts/verify/lib-live-tenant.sh
source "${SCRIPT_DIR}/verify/lib-live-tenant.sh"

APP_ENV_FILE="${APP_ENV_FILE:-${REPO_ROOT}/apps/osionos/app/.env}"
NODE_IMAGE="${BAAS_WS_NODE_IMAGE:-node:22-alpine}"
DC=(docker compose)

# ── 1) stack endpoints + the app's identity ─────────────────────────────────
step "resolving the running stack"
KONG_PORT="$(_lt_host_port mini-baas-kong 8000/tcp)"
TC_PORT="$(_lt_host_port mini-baas-tenant-control 3022/tcp)"
[[ -n "${KONG_PORT}" && -n "${TC_PORT}" ]] || fail "mini-baas stack not up (kong/tenant-control unmapped) — run: make up EDITION=full"
KONG_URL="http://127.0.0.1:${KONG_PORT}"
TC_URL="http://127.0.0.1:${TC_PORT}"
SERVICE_TOKEN="$(_lt_env mini-baas-tenant-control INTERNAL_SERVICE_TOKEN)"
ANON_KEY="$(_lt_env mini-baas-kong KONG_PUBLIC_API_KEY)"
SERVICE_KEY="$(_lt_env mini-baas-kong KONG_SERVICE_API_KEY)"
RT_JWT_SECRET="$(_lt_env mini-baas-realtime REALTIME_JWT_SECRET)"
[[ -n "${SERVICE_TOKEN}" && -n "${ANON_KEY}" && -n "${SERVICE_KEY}" ]] || fail "control-plane credentials not found on the running containers"

APP_KEY="${BAAS_API_KEY:-$(sed -n 's/^VITE_BAAS_API_KEY=//p' "${APP_ENV_FILE}" 2>/dev/null | head -1)}"
[[ "${APP_KEY}" == mbk_* ]] || fail "no tenant API key — set BAAS_API_KEY or VITE_BAAS_API_KEY in ${APP_ENV_FILE}"
vbody="{\"key\":\"${APP_KEY}\"}"
svc_auth POST /v1/keys/verify "${vbody}"
verify=$(curl -fsS -X POST "${TC_URL}/v1/keys/verify" \
  "${SVC_AUTH[@]}" -H 'Content-Type: application/json' \
  -d "${vbody}") || fail "tenant-control /v1/keys/verify unreachable"
echo "${verify}" | grep -q '"valid":true' || fail "the app key is not valid: ${verify}"
TENANT="$(echo "${verify}" | _lt_json_field tenant_id)"
KEY_ID="$(echo "${verify}" | _lt_json_field key_id)"
[[ -n "${TENANT}" && -n "${KEY_ID}" ]] || fail "verify response missing tenant_id/key_id: ${verify}"
OWNER="api-key:${KEY_ID}"
pass "app key → tenant '${TENANT}', owner principal '${OWNER}'"

# ── 2) engine credentials + demo databases ──────────────────────────────────
PG_USER="$(_lt_env mini-baas-postgres POSTGRES_USER)"; PG_USER="${PG_USER:-postgres}"
PG_PASS="$(_lt_env mini-baas-postgres POSTGRES_PASSWORD)"
MYSQL_USER="$(_lt_env mini-baas-mysql MYSQL_USER)"; MYSQL_USER="${MYSQL_USER:-mini_baas}"
MYSQL_PASS="$(_lt_env mini-baas-mysql MYSQL_PASSWORD)"
MYSQL_ROOT_PASS="$(_lt_env mini-baas-mysql MYSQL_ROOT_PASSWORD)"
MONGO_USER="$(_lt_env mini-baas-mongo MONGO_INITDB_ROOT_USERNAME)"; MONGO_USER="${MONGO_USER:-mongo}"
MONGO_PASS="$(_lt_env mini-baas-mongo MONGO_INITDB_ROOT_PASSWORD)"
[[ -n "${PG_PASS}" && -n "${MYSQL_PASS}" && -n "${MONGO_PASS}" ]] || fail "engine credentials not found on the running containers"
urlenc() { python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"; }

if [[ "${RESEED:-0}" == "1" ]]; then
  step "RESEED=1 — dropping the demo databases (commerce / ops / activity)"
  "${DC[@]}" exec -T postgres psql -U "${PG_USER}" -d postgres \
    -c "DROP DATABASE IF EXISTS commerce WITH (FORCE)" >/dev/null
  "${DC[@]}" exec -T -e MYSQL_PWD="${MYSQL_ROOT_PASS}" mysql \
    mysql -uroot -e "DROP DATABASE IF EXISTS ops" >/dev/null
  "${DC[@]}" exec -T mongo mongosh --quiet \
    "mongodb://${MONGO_USER}:$(urlenc "${MONGO_PASS}")@127.0.0.1:27017/activity?authSource=admin" \
    --eval 'db.dropDatabase()' >/dev/null
fi

step "ensuring the demo databases exist"
"${DC[@]}" exec -T postgres psql -U "${PG_USER}" -d postgres -tAc \
  "SELECT 1 FROM pg_database WHERE datname='commerce'" | grep -q 1 \
  || "${DC[@]}" exec -T postgres psql -U "${PG_USER}" -d postgres -c "CREATE DATABASE commerce" >/dev/null
"${DC[@]}" exec -T -e MYSQL_PWD="${MYSQL_ROOT_PASS}" mysql mysql -uroot -e \
  "CREATE DATABASE IF NOT EXISTS ops CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
   GRANT ALL PRIVILEGES ON ops.* TO '${MYSQL_USER}'@'%'; FLUSH PRIVILEGES;" >/dev/null
pass "commerce (pg) + ops (mysql) ready; activity (mongo) is implicit"

# ── 3) mounts through the real gateway (idempotent by tenant+name) ──────────
register_mount() { # $1 name, $2 engine, $3 dsn → echoes mount id
  local code
  code=$(curl -s -o /tmp/seed-mount.json -w '%{http_code}' -X POST \
    "${KONG_URL}/admin/v1/databases" \
    -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${TENANT}" \
    -H 'Content-Type: application/json' \
    -d "{\"engine\":\"$2\",\"name\":\"$1\",\"connection_string\":\"$3\"}")
  if [[ "${code}" == "201" ]]; then
    _lt_json_field id < /tmp/seed-mount.json
  elif [[ "${code}" == "409" ]]; then
    curl -fsS "${KONG_URL}/admin/v1/databases" \
      -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${TENANT}" \
      | python3 -c "import json, sys; rows = json.load(sys.stdin); print(next(r['id'] for r in rows if r.get('name') == '$1'))"
  else
    fail "mount $1 registration failed (${code}): $(cat /tmp/seed-mount.json)"
  fi
}
step "registering the three mounts under tenant '${TENANT}'"
PG_DB_ID="$(register_mount pg-commerce postgresql \
  "postgres://$(urlenc "${PG_USER}"):$(urlenc "${PG_PASS}")@postgres:5432/commerce")"
MY_DB_ID="$(register_mount mysql-ops mysql \
  "mysql://$(urlenc "${MYSQL_USER}"):$(urlenc "${MYSQL_PASS}")@mysql:3306/ops")"
MG_DB_ID="$(register_mount mongo-activity mongodb \
  "mongodb://$(urlenc "${MONGO_USER}"):$(urlenc "${MONGO_PASS}")@mongo:27017/activity?authSource=admin")"
[[ -n "${PG_DB_ID}" && -n "${MY_DB_ID}" && -n "${MG_DB_ID}" ]] || fail "mount registration returned empty ids"
pass "mounts: pg-commerce=${PG_DB_ID} mysql-ops=${MY_DB_ID} mongo-activity=${MG_DB_ID}"

# ── 4) generate the dataset (deterministic, in a pinned node container) ─────
step "generating the dataset (seed 42${SEED_SCALE:+, scale ${SEED_SCALE}})"
OUT_DIR="$(mktemp -d /tmp/seed-live-demo.XXXXXX)"
trap 'rm -rf "${OUT_DIR}"' EXIT
docker run --rm --network none \
  -v "${SCRIPT_DIR}/seed/live-demo-generate.mjs:/gen.mjs:ro" -v "${OUT_DIR}:/out" \
  -e SEED_OWNER="${OWNER}" -e SEED_TENANT="${TENANT}" -e SEED_SCALE="${SEED_SCALE:-1}" \
  "${NODE_IMAGE}" node /gen.mjs || fail "generator failed"
count_of() { python3 -c "import json; print(json.load(open('${OUT_DIR}/counts.json'))['$1']['$2'])"; }

# ── 5) load (idempotent: re-runs converge on identical counts) ──────────────
step "loading postgres commerce ($(count_of pg orders) orders / $(count_of pg order_items) items)"
"${DC[@]}" exec -T postgres psql -U "${PG_USER}" -d commerce -q \
  < "${OUT_DIR}/pg-commerce.sql" >/dev/null || fail "postgres load failed"
step "loading mysql ops ($(count_of mysql tasks) tasks / $(count_of mysql tickets) tickets)"
"${DC[@]}" exec -T -e MYSQL_PWD="${MYSQL_PASS}" mysql mysql -u"${MYSQL_USER}" ops \
  < "${OUT_DIR}/mysql-ops.sql" || fail "mysql load failed"
step "loading mongo activity ($(count_of mongo events) events / $(count_of mongo product_reviews) reviews)"
# Sibling container, NOT `exec` into mini-baas-mongo: mongosh is a Node app
# and parsing the multi-MB seed script inside mongod's 512MB cgroup OOM-kills
# the database container. Same image (version-matched mongosh), stack network.
STACK_NET="$(docker inspect mini-baas-kong \
  --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' | head -1)"
MONGO_IMAGE="$(docker inspect mini-baas-mongo --format '{{.Config.Image}}')"
docker run --rm --network "${STACK_NET}" \
  -v "${OUT_DIR}/mongo-activity.js:/seed.js:ro" "${MONGO_IMAGE}" \
  mongosh --quiet \
  "mongodb://${MONGO_USER}:$(urlenc "${MONGO_PASS}")@mongo:27017/activity?authSource=admin" \
  /seed.js || fail "mongo load failed"
pass "all three engines loaded"

step "verifying engine row counts against the generator manifest"
pg_count() { "${DC[@]}" exec -T postgres psql -U "${PG_USER}" -d commerce -tAc "SELECT count(*) FROM $1"; }
my_count() { "${DC[@]}" exec -T -e MYSQL_PWD="${MYSQL_PASS}" mysql mysql -u"${MYSQL_USER}" ops -N -e "SELECT count(*) FROM $1"; }
mg_count() { docker run --rm --network "${STACK_NET}" "${MONGO_IMAGE}" mongosh --quiet "mongodb://${MONGO_USER}:$(urlenc "${MONGO_PASS}")@mongo:27017/activity?authSource=admin" --eval "print(db.$1.countDocuments())"; }
for table in customers products employees inventory orders order_items edges; do
  actual="$(pg_count "${table}" | tr -d '[:space:]')"; expected="$(count_of pg "${table}")"
  [[ "${actual}" == "${expected}" ]] || fail "pg ${table}: ${actual} rows, expected ${expected}"
done
for table in projects tasks tickets time_entries; do
  actual="$(my_count "${table}" | tr -d '[:space:]')"; expected="$(count_of mysql "${table}")"
  [[ "${actual}" == "${expected}" ]] || fail "mysql ${table}: ${actual} rows, expected ${expected}"
done
for coll in events product_reviews notes; do
  actual="$(mg_count "${coll}" | tr -d '[:space:]')"; expected="$(count_of mongo "${coll}")"
  [[ "${actual}" == "${expected}" ]] || fail "mongo ${coll}: ${actual} docs, expected ${expected}"
done
pass "every table matches the manifest (idempotent re-runs converge here)"

# ── 6) realtime token + app env wiring ──────────────────────────────────────
step "minting the app realtime WS token (HS256, 30 days)"
RT_TOKEN="$(docker run --rm --network none -e RT_JWT_SECRET="${RT_JWT_SECRET}" "${NODE_IMAGE}" node -e '
const { createHmac } = require("node:crypto");
const b64u = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const head = b64u({ alg: "HS256", typ: "JWT" });
const body = b64u({ sub: "osionos-live-demo", exp: Math.floor(Date.now() / 1000) + 30 * 86400 });
const sig = createHmac("sha256", process.env.RT_JWT_SECRET).update(`${head}.${body}`).digest("base64url");
console.log(`${head}.${body}.${sig}`);')"
[[ -n "${RT_TOKEN}" ]] || fail "realtime token mint failed"

LIVE_MOUNTS_JSON="[{\"dbId\":\"${PG_DB_ID}\",\"name\":\"pg-commerce\",\"engine\":\"postgresql\"},{\"dbId\":\"${MY_DB_ID}\",\"name\":\"mysql-ops\",\"engine\":\"mysql\"},{\"dbId\":\"${MG_DB_ID}\",\"name\":\"mongo-activity\",\"engine\":\"mongodb\"}]"
if [[ "${SKIP_ENV_WRITE:-0}" != "1" ]]; then
  step "writing live-demo keys into ${APP_ENV_FILE}"
  python3 - "${APP_ENV_FILE}" <<PYEOF
import sys, pathlib, os
path = pathlib.Path(sys.argv[1])
mode = os.stat(path).st_mode & 0o777 if path.exists() else 0o600
lines = path.read_text().splitlines() if path.exists() else []
updates = {
    "VITE_BAAS_URL": "http://127.0.0.1:${KONG_PORT}",
    "VITE_BAAS_LIVE_MOUNTS": '${LIVE_MOUNTS_JSON}',
    "VITE_BAAS_REALTIME_TOKEN": "${RT_TOKEN}",
    # Enables the dynamic in-browser mount catalog (X-Baas-Tenant-Id header);
    # the LIVE_MOUNTS JSON above stays as the offline fallback.
    "VITE_BAAS_TENANT_ID": "${TENANT}",
}
seen = set()
out = []
for line in lines:
    key = line.split("=", 1)[0] if "=" in line else None
    if key in updates:
        out.append(f"{key}={updates[key]}")
        seen.add(key)
    else:
        out.append(line)
missing = [k for k in updates if k not in seen]
if missing:
    out.append("")
    out.append("# Live-database demo (generated by make seed-live-demo)")
    out.extend(f"{k}={updates[k]}" for k in missing)
path.write_text("\n".join(out) + "\n")
os.chmod(path, mode)
print(f"updated: {', '.join(updates)}")
PYEOF
fi

# ── 7) prove it through the REAL gateway path with the app's own key ────────
gw() { curl -s -o /tmp/seed-gw.json -w '%{http_code}' "$@" -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: ${APP_KEY}"; }
step "gateway: schema introspection on all three mounts"
code=$(gw "${KONG_URL}/query/v1/${PG_DB_ID}/schema")
[[ "${code}" == "200" ]] || fail "pg schema fetch ${code}: $(cat /tmp/seed-gw.json)"
for marker in '"name":"orders"' '"enum_values"' '"references"' '"name":"edges"'; do
  grep -q "${marker}" /tmp/seed-gw.json || fail "pg schema missing ${marker}"
done
code=$(gw "${KONG_URL}/query/v1/${MY_DB_ID}/schema")
[[ "${code}" == "200" ]] || fail "mysql schema fetch ${code}"
for marker in '"name":"tasks"' '"normalized_type":"enum"' '"normalized_type":"boolean"'; do
  grep -q "${marker}" /tmp/seed-gw.json || fail "mysql schema missing ${marker}"
done
code=$(gw "${KONG_URL}/query/v1/${MG_DB_ID}/schema")
[[ "${code}" == "200" ]] || fail "mongo schema fetch ${code}"
for marker in '"name":"events"' '"enum_values"' '"inferred":false'; do
  grep -q "${marker}" /tmp/seed-gw.json || fail "mongo schema missing ${marker}"
done
pass "schema descriptors carry enums, FKs and exact (declared) mongo contracts"

step "gateway: the app's key sees the rows (owner-scoped reads)"
code=$(gw -X POST "${KONG_URL}/query/v1/${PG_DB_ID}/tables/orders" \
  -H 'Content-Type: application/json' -d '{"op":"list","limit":3}')
[[ "${code}" == "200" || "${code}" == "201" ]] && grep -q '"rows":\[{' /tmp/seed-gw.json \
  || fail "pg list orders failed (${code}): $(head -c300 /tmp/seed-gw.json)"
code=$(gw -X POST "${KONG_URL}/query/v1/${MY_DB_ID}/tables/tasks" \
  -H 'Content-Type: application/json' -d '{"op":"list","limit":3}')
[[ "${code}" == "200" || "${code}" == "201" ]] && grep -q '"rows":\[{' /tmp/seed-gw.json \
  || fail "mysql list tasks failed (${code}): $(head -c300 /tmp/seed-gw.json)"
code=$(gw -X POST "${KONG_URL}/query/v1/${MG_DB_ID}/tables/events" \
  -H 'Content-Type: application/json' -d '{"op":"list","limit":3}')
[[ "${code}" == "200" || "${code}" == "201" ]] && grep -q '"id":"evt-' /tmp/seed-gw.json \
  || fail "mongo list events failed (${code}): $(head -c300 /tmp/seed-gw.json)"
pass "owner-scoped list returns rows on pg + mysql + mongo"

step "gateway: aggregate count matches the manifest"
code=$(gw -X POST "${KONG_URL}/query/v1/${PG_DB_ID}/tables/orders" \
  -H 'Content-Type: application/json' \
  -d '{"op":"aggregate","aggregate":{"aggregates":[{"func":"count","alias":"n"}]}}')
[[ "${code}" == "200" || "${code}" == "201" ]] || fail "aggregate failed (${code})"
expected_orders="$(count_of pg orders)"
grep -Eq "\"n\":\"?${expected_orders}\"?" /tmp/seed-gw.json \
  || fail "aggregate count mismatch (want ${expected_orders}): $(head -c300 /tmp/seed-gw.json)"
pass "COUNT(orders) through the gateway = ${expected_orders}"

step "gateway: single-row update stays single-row (the mongo _id fix)"
PROBE="probe-$(date +%s)"
code=$(gw -X POST "${KONG_URL}/query/v1/${MG_DB_ID}/tables/notes" \
  -H 'Content-Type: application/json' \
  -d "{\"op\":\"update\",\"filter\":{\"_id\":\"note-0001\"},\"data\":{\"body\":\"${PROBE}\"}}")
[[ "${code}" == "200" || "${code}" == "201" ]] || fail "mongo update failed (${code}): $(cat /tmp/seed-gw.json)"
grep -q '"rowCount":1' /tmp/seed-gw.json || fail "mongo update touched != 1 row: $(cat /tmp/seed-gw.json)"
code=$(gw -X POST "${KONG_URL}/query/v1/${MG_DB_ID}/tables/notes" \
  -H 'Content-Type: application/json' -d '{"op":"get","filter":{"_id":"note-0002"}}')
grep -q "${PROBE}" /tmp/seed-gw.json && fail "mongo update leaked into note-0002 (mass-update regression)"
code=$(gw -X POST "${KONG_URL}/query/v1/${MG_DB_ID}/tables/notes" \
  -H 'Content-Type: application/json' -d '{"op":"get","filter":{"_id":"note-0001"}}')
grep -q "${PROBE}" /tmp/seed-gw.json || fail "mongo update did not land on note-0001"
code=$(gw -X POST "${KONG_URL}/query/v1/${PG_DB_ID}/tables/orders" \
  -H 'Content-Type: application/json' \
  -d "{\"op\":\"update\",\"filter\":{\"id\":1},\"data\":{\"notes\":\"${PROBE}\"}}")
[[ "${code}" == "200" || "${code}" == "201" ]] && grep -q '"rowCount":1' /tmp/seed-gw.json \
  || fail "pg update order#1 failed (${code}): $(cat /tmp/seed-gw.json)"
pass "in-place edits land on exactly one row (pg + mongo), realtime publish fired"

# ── 8) osionos workspace pages (optional — needs the root stack postgres) ───
if [[ "${SEED_PAGES:-1}" == "1" ]]; then
  ROOT_DC=(docker compose -f "${REPO_ROOT}/docker-compose.yml")
  if [[ -n "$("${ROOT_DC[@]}" ps -q postgres 2>/dev/null)" ]]; then
    step "seeding the 'Live Databases' pages into dylan's osionos workspace"
    DYLAN="ff284cf3-ab7d-4756-ade3-369257e36b2a"
    WS="$("${ROOT_DC[@]}" exec -T postgres psql -U postgres -d postgres -tAc \
      "SELECT workspace_id FROM public.osionos_pages WHERE owner_id='${DYLAN}' GROUP BY 1 ORDER BY count(*) DESC LIMIT 1" \
      | tr -d '[:space:]')"
    WS="${WS:-0ea96910-277a-49d6-901c-524b147cc009}"
    python3 "${SCRIPT_DIR}/seed/live-demo-pages.py" \
      "${WS}" "${DYLAN}" "${PG_DB_ID}" "${MY_DB_ID}" "${MG_DB_ID}" \
      | "${ROOT_DC[@]}" exec -T postgres psql -U postgres -d postgres -q -v ON_ERROR_STOP=1 >/dev/null \
      || fail "workspace page seed failed"
    step "seeding the 'Analytics' dashboard pages (curated chart/dashboard views)"
    python3 "${SCRIPT_DIR}/seed/analytics-dashboards.py" \
      "${WS}" "${DYLAN}" "${PG_DB_ID}" "${MY_DB_ID}" "${MG_DB_ID}" \
      | "${ROOT_DC[@]}" exec -T postgres psql -U postgres -d postgres -q -v ON_ERROR_STOP=1 >/dev/null \
      || fail "analytics page seed failed"
    # Dylan must also SEE the shared agency wiki (26 pages, visibility=shared,
    # seeded by tools/seeds/seed_agency_wiki.py into the org workspace): grant
    # editor membership so the workspace shows up in his switcher.
    AGENCY_WS="b1a0c1e5-0000-4000-a000-000000000001"
    if "${ROOT_DC[@]}" exec -T postgres psql -U postgres -d postgres -tAc \
      "SELECT 1 FROM public.osionos_workspaces WHERE id='${AGENCY_WS}'" 2>/dev/null | grep -q 1; then
      "${ROOT_DC[@]}" exec -T postgres psql -U postgres -d postgres -q -c \
        "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions)
         VALUES ('${AGENCY_WS}','${DYLAN}','editor', ARRAY['read','write'])
         ON CONFLICT (workspace_id, user_id) DO NOTHING" \
        && pass "dylan is an editor of the agency org workspace (shared wiki visible)"
    fi
    if "${ROOT_DC[@]}" exec -T postgres psql -U postgres -d postgres -tAc \
      "SELECT 1 FROM auth.users WHERE email='dylan@gmail.com'" 2>/dev/null | grep -q 1; then
      pass "pages seeded in workspace ${WS}; dylan@gmail.com exists in gotrue"
    else
      red "[SEED] WARN: dylan@gmail.com not found in auth.users — sign the account up once via the website"
    fi
  else
    red "[SEED] WARN: root-stack postgres is not running — skipped the workspace pages (run 'make all' at the repo root, then re-run with SEED_PAGES=1)"
  fi
fi

green "[SEED] OK — live demo ready: pg-commerce=${PG_DB_ID} mysql-ops=${MY_DB_ID} mongo-activity=${MG_DB_ID} (owner ${OWNER})"
