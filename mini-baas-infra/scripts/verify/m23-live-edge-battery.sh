#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m23-live-edge-battery.sh                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/10 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/10 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M23 — live-database edge battery. Pins the WIRE CONTRACT the osionos live
# UI (notion-database-sys store/live) is built against, by probing the REAL
# gateway path (Kong key-auth → query-router → Rust data plane → engines)
# with the app's own key on the seeded demo mounts. Every case here is either
# a bug found live (and fixed) or a guarantee the frontend write/conflict
# pipeline depends on:
#
#   filter grammar    sql ($ilike/$null/$between/top-$not) vs mongo native
#                     ($regex/$exists/$nin); mongo rejects sql-only ops 400
#   mass-write guard  update/delete with an empty filter → 400 on ALL engines
#                     (mongo executed it before the fix: rowCount 39)
#   single-row writes a by-pk update touches exactly one document (the mongo
#                     `_id`-stripping mass-update fix)
#   error envelopes   caller-data faults are 4xx, never 5xx: bad enum / bad
#                     date / numeric overflow / validator rejection / dup _id
#                     → 409; FK + NOT NULL → 409; DDL on missing column →
#                     400, duplicate column → 409 (5xx made the outbox retry
#                     doomed writes forever)
#   lifecycle         insert (echo pk) → unicode/emoji roundtrip → update
#                     (rowCount 1, neighbor untouched) → delete → gone,
#                     per engine
#
# Requires: the mini-baas stack up + `make seed-live-demo` run (mount ids are
# read from the osionos app .env). Probe rows are created and deleted by the
# battery itself; seeded rows are only ever touched with INVALID values
# (rejected — nothing changes).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${BAAS_DIR}/../../.." && pwd)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M23] $*"; }
pass()  { green "[M23] PASS: $*"; }
fail()  { red "[M23] FAIL: $*"; exit 1; }

# shellcheck source=scripts/verify/lib-live-tenant.sh
source "${SCRIPT_DIR}/lib-live-tenant.sh"

APP_ENV_FILE="${APP_ENV_FILE:-${REPO_ROOT}/apps/osionos/app/.env}"
KONG_PORT="$(_lt_host_port mini-baas-kong 8000/tcp)"
[[ -n "${KONG_PORT}" ]] || fail "mini-baas kong is not up"
KONG="http://127.0.0.1:${KONG_PORT}"
ANON="$(_lt_env mini-baas-kong KONG_PUBLIC_API_KEY)"
APP_KEY="${BAAS_API_KEY:-$(sed -n 's/^VITE_BAAS_API_KEY=//p' "${APP_ENV_FILE}" | head -1)}"
[[ "${APP_KEY}" == mbk_* ]] || fail "no app key (run make seed-live-demo first)"
MOUNTS_JSON="$(sed -n 's/^VITE_BAAS_LIVE_MOUNTS=//p' "${APP_ENV_FILE}" | head -1)"
[[ -n "${MOUNTS_JSON}" ]] || fail "VITE_BAAS_LIVE_MOUNTS missing (run make seed-live-demo first)"
mount_id() { python3 -c "import json,sys; print(next(m['dbId'] for m in json.loads(sys.argv[1]) if m['name']==sys.argv[2]))" "${MOUNTS_JSON}" "$1"; }
PG="$(mount_id pg-commerce)"; MY="$(mount_id mysql-ops)"; MG="$(mount_id mongo-activity)"

# gw <expected-status> <url-path> <json-body|-> → body in /tmp/m23.json.
# Retries on Kong 429 (rate limiting under back-to-back gate runs) and on the
# transient auth_verify_unavailable hiccup — every battery op is idempotent
# (same filters; writes carry idempotencyKeys), so replays are safe.
gw() {
  local expected="$1" path="$2" body="${3:--}" code attempt
  for attempt in 1 2 3 4; do
    if [[ "${body}" == "-" ]]; then
      code=$(curl -s -o /tmp/m23.json -w '%{http_code}' "${KONG}${path}" \
        -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${APP_KEY}")
    else
      code=$(curl -s -o /tmp/m23.json -w '%{http_code}' -X POST "${KONG}${path}" \
        -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${APP_KEY}" \
        -H 'Content-Type: application/json' -d "${body}")
    fi
    if [[ "${code}" == "429" ]] || grep -q 'auth_verify_unavailable' /tmp/m23.json 2>/dev/null; then
      [[ "${attempt}" -lt 4 ]] && { sleep $((attempt * 3)); continue; }
    fi
    break
  done
  [[ "${code}" == "${expected}" || ( "${expected}" == "2xx" && "${code}" =~ ^2 ) ]] \
    || fail "${path} expected ${expected}, got ${code}: $(head -c 200 /tmp/m23.json) ← ${body}"
}
has() { grep -q "$1" /tmp/m23.json || fail "response missing $1: $(head -c 200 /tmp/m23.json)"; }
# NOT-matched is the GOOD case — `grep && fail` would exit 1 under set -e.
lacks() { ! grep -q "$1" /tmp/m23.json || fail "response unexpectedly contains $1"; }

# ── 1) filter grammar forks by engine ────────────────────────────────────────
step "filter grammar: sql dialect on postgresql + mysql"
gw 2xx "/query/v1/${PG}/tables/orders" '{"op":"list","limit":2,"filter":{"status":{"$eq":"delivered"}}}'
has '"rows":\[{'
gw 2xx "/query/v1/${PG}/tables/orders" '{"op":"list","limit":2,"filter":{"notes":{"$null":false}}}'
gw 2xx "/query/v1/${PG}/tables/customers" '{"op":"list","limit":2,"filter":{"name":{"$ilike":"%ada%"}}}'
gw 2xx "/query/v1/${PG}/tables/orders" '{"op":"list","limit":2,"filter":{"total":{"$between":[100,200]}}}'
gw 2xx "/query/v1/${PG}/tables/orders" '{"op":"list","limit":2,"filter":{"$not":{"status":{"$in":["cancelled"]}}}}'
gw 2xx "/query/v1/${MY}/tables/tasks" '{"op":"list","limit":2,"filter":{"status":{"$eq":"done"}}}'
has '"rows":\[{'
gw 2xx "/query/v1/${MY}/tables/tasks" '{"op":"list","limit":2,"filter":{"done_at":{"$null":true}}}'
pass "sql grammar (\$eq/\$null/\$ilike/\$between/top-\$not) on pg + mysql"

step "filter grammar: mongo native dialect"
gw 2xx "/query/v1/${MG}/tables/events" '{"op":"list","limit":2,"filter":{"summary":{"$regex":"page","$options":"i"}}}'
has '"id":"evt-'
gw 2xx "/query/v1/${MG}/tables/events" '{"op":"list","limit":2,"filter":{"order_ref":{"$exists":true}}}'
gw 2xx "/query/v1/${MG}/tables/events" '{"op":"list","limit":2,"filter":{"kind":{"$nin":["login","search"]}}}'
gw 400 "/query/v1/${MG}/tables/events" '{"op":"list","limit":2,"filter":{"summary":{"$ilike":"%x%"}}}'
gw 400 "/query/v1/${MG}/tables/events" '{"op":"list","limit":2,"filter":{"summary":{"$null":true}}}'
gw 400 "/query/v1/${MG}/tables/events" '{"op":"list","limit":2,"filter":{"$not":{"kind":{"$in":["login"]}}}}'
gw 400 "/query/v1/${MG}/tables/events" '{"op":"list","limit":1,"filter":{"$where":"true"}}'
pass "mongo dialect (\$regex/\$exists/\$nin ok; \$ilike/\$null/top-\$not/\$where → 400)"

# ── 2) mass-write guard parity ───────────────────────────────────────────────
step "empty-filter update/delete is refused on every engine"
gw 400 "/query/v1/${PG}/tables/orders" '{"op":"update","filter":{},"data":{"discount_pct":99}}'
gw 400 "/query/v1/${MY}/tables/tasks" '{"op":"update","filter":{},"data":{"priority":"low"}}'
gw 400 "/query/v1/${MG}/tables/notes" '{"op":"update","filter":{},"data":{"pinned":false}}'
gw 400 "/query/v1/${MG}/tables/notes" '{"op":"delete","filter":{}}'
gw 400 "/query/v1/${MG}/tables/notes" '{"op":"update","filter":{"owner_id":"x"},"data":{"pinned":false}}'
pass "full-table/collection writes are 400 on pg + mysql + mongo"

# ── 3) caller-data faults are 4xx, never 5xx ─────────────────────────────────
step "validation/conflict envelopes (the 502→409 fix)"
gw 409 "/query/v1/${PG}/tables/orders" '{"op":"update","filter":{"id":2},"data":{"status":"bogus"}}'
gw 409 "/query/v1/${PG}/tables/orders" '{"op":"update","filter":{"id":2},"data":{"placed_at":"not a date"}}'
gw 409 "/query/v1/${PG}/tables/orders" '{"op":"update","filter":{"id":2},"data":{"total":99999999999999}}'
gw 409 "/query/v1/${PG}/tables/order_items" '{"op":"update","filter":{"id":1},"data":{"product_id":999999}}'
gw 409 "/query/v1/${PG}/tables/customers" '{"op":"update","filter":{"id":1},"data":{"name":null}}'
gw 409 "/query/v1/${MY}/tables/tasks" '{"op":"update","filter":{"id":1},"data":{"status":"bogus"}}'
gw 409 "/query/v1/${MG}/tables/events" '{"op":"update","filter":{"_id":"evt-000002"},"data":{"kind":"bogus"}}'
pass "bad enum / bad date / overflow / FK / NOT-NULL / validator → 409"

step "DDL envelopes for schema-shape mistakes"
gw 400 "/query/v1/${PG}/schema/ddl" '{"op":"drop_column","table":"orders","column_name":"never_existed","confirm":true}'
gw 409 "/query/v1/${PG}/schema/ddl" '{"op":"add_column","table":"orders","column":{"name":"status","normalized_type":"text","nullable":true}}'
gw 400 "/query/v1/${MY}/schema/ddl" '{"op":"drop_column","table":"tasks","column_name":"never_existed","confirm":true}'
pass "drop-missing → 400, add-duplicate → 409 (no more retry-forever 502s)"

# ── 4) per-engine write lifecycle on battery-owned probe rows ────────────────
UNI='ünïcødé 🚀 — "double" '"'"'single'"'"' 100%_done\\path'
step "postgresql lifecycle: insert echo → unicode roundtrip → single-row update → delete"
gw 2xx "/query/v1/${PG}/tables/orders" \
  '{"op":"insert","data":{"customer_id":1,"status":"pending","ship_method":"standard","placed_at":"2026-06-10T00:00:00Z","total":12.34,"discount_pct":0},"idempotencyKey":"m23-pg-probe"}'
has '"rows":\[{'
PG_PROBE_ID=$(python3 -c "import json; print(json.load(open('/tmp/m23.json'))['rows'][0]['id'])")
[[ -n "${PG_PROBE_ID}" ]] || fail "pg insert echoed no id"
gw 2xx "/query/v1/${PG}/tables/orders" \
  "$(python3 -c "import json,sys; print(json.dumps({'op':'update','filter':{'id':int(sys.argv[1])},'data':{'notes':sys.argv[2]}}))" "${PG_PROBE_ID}" "${UNI}")"
has '"rowCount":1'
gw 2xx "/query/v1/${PG}/tables/orders" "{\"op\":\"get\",\"filter\":{\"id\":${PG_PROBE_ID}}}"
grep -q '🚀' /tmp/m23.json || fail "pg unicode roundtrip lost the emoji"
gw 2xx "/query/v1/${PG}/tables/orders" "{\"op\":\"delete\",\"filter\":{\"id\":${PG_PROBE_ID}}}"
gw 2xx "/query/v1/${PG}/tables/orders" "{\"op\":\"get\",\"filter\":{\"id\":${PG_PROBE_ID}}}"
has '"rows":\[\]'
pass "pg probe row: inserted id=${PG_PROBE_ID}, roundtripped, deleted"

step "mysql lifecycle: insert echo → update → delete"
gw 2xx "/query/v1/${MY}/tables/time_entries" \
  '{"op":"insert","data":{"task_id":1,"person":"M23 Battery","hours":1.25,"entry_date":"2026-06-10","billable":1},"idempotencyKey":"m23-my-probe"}'
MY_PROBE_ID=$(python3 -c "import json; r=json.load(open('/tmp/m23.json'))['rows'][0]; print(r.get('id') or r.get('insertId') or '')")
[[ -n "${MY_PROBE_ID}" ]] || fail "mysql insert echoed no id: $(head -c 200 /tmp/m23.json)"
gw 2xx "/query/v1/${MY}/tables/time_entries" "{\"op\":\"update\",\"filter\":{\"id\":${MY_PROBE_ID}},\"data\":{\"note\":\"battery ok\"}}"
has '"rowCount":1'
gw 2xx "/query/v1/${MY}/tables/time_entries" "{\"op\":\"delete\",\"filter\":{\"id\":${MY_PROBE_ID}}}"
pass "mysql probe row: inserted id=${MY_PROBE_ID}, updated, deleted"

step "mongo lifecycle: insert echo → single-row isolation → delete"
gw 2xx "/query/v1/${MG}/tables/notes" \
  '{"op":"insert","data":{"title":"M23 probe","body":"created by the battery","tags":["battery"],"pinned":false},"idempotencyKey":"m23-mg-probe"}'
MG_PROBE_ID=$(python3 -c "import json; print(json.load(open('/tmp/m23.json'))['rows'][0]['id'])")
[[ -n "${MG_PROBE_ID}" ]] || fail "mongo insert echoed no id"
STAMP="m23-$(date +%s)"
gw 2xx "/query/v1/${MG}/tables/notes" "{\"op\":\"update\",\"filter\":{\"_id\":\"${MG_PROBE_ID}\"},\"data\":{\"body\":\"${STAMP}\"}}"
has '"rowCount":1'
gw 2xx "/query/v1/${MG}/tables/notes" '{"op":"get","filter":{"_id":"note-0002"}}'
lacks "${STAMP}"
gw 2xx "/query/v1/${MG}/tables/notes" "{\"op\":\"delete\",\"filter\":{\"_id\":\"${MG_PROBE_ID}\"}}"
has '"rowCount":1'
pass "mongo probe doc: ObjectId-echo update isolated to one row, deleted"

# ── 5) aggregates + pagination ───────────────────────────────────────────────
step "aggregates (pg) + pagination + capability honesty"
gw 2xx "/query/v1/${PG}/tables/orders" \
  '{"op":"aggregate","aggregate":{"groupBy":["status"],"aggregates":[{"func":"count","alias":"n"},{"func":"sum","field":"total","alias":"revenue"}]}}'
has '"status":"delivered"'
gw 2xx "/query/v1/${PG}/tables/orders" '{"op":"list","limit":500,"offset":24999}'
gw 400 "/query/v1/${PG}/tables/orders" '{"op":"list","limit":501}'
gw 2xx "/query/v1/${PG}/tables/orders" '{"op":"list","limit":1,"sort":{"total":"desc"}}'
pass "GROUP BY aggregate + limit cap (500) + offset + sort"

# ── 6) latency budgets (server slice of the live-view budgets) ───────────────
step "latency budgets through the full gateway path"
bench() { # $1 path, $2 body|-, → ms
  local t
  if [[ "$2" == "-" ]]; then
    t=$(curl -s -o /dev/null -w '%{time_total}' "${KONG}$1" \
      -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${APP_KEY}")
  else
    t=$(curl -s -o /dev/null -w '%{time_total}' -X POST "${KONG}$1" \
      -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${APP_KEY}" \
      -H 'Content-Type: application/json' -d "$2")
  fi
  python3 -c "print(int(float('${t}') * 1000))"
}
curl -s -o /dev/null "${KONG}/query/v1/${PG}/schema" -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${APP_KEY}" # warm the cache
SCHEMA_MS=$(bench "/query/v1/${PG}/schema" -)
LIST_MS=$(bench "/query/v1/${PG}/tables/orders" '{"op":"list","limit":500}')
AGG_MS=$(bench "/query/v1/${PG}/tables/orders" '{"op":"aggregate","aggregate":{"groupBy":["status"],"aggregates":[{"func":"count","alias":"n"},{"func":"sum","field":"total","alias":"r"}]}}')
GET_MS=$(bench "/query/v1/${MG}/tables/notes" '{"op":"get","filter":{"_id":"note-0001"}}')
echo "[M23] bench: schema(cached)=${SCHEMA_MS}ms list500=${LIST_MS}ms aggregate25k=${AGG_MS}ms mongoGet=${GET_MS}ms"
[[ "${SCHEMA_MS}" -lt 100 ]] || fail "cached /schema took ${SCHEMA_MS}ms (budget 100ms through Kong)"
[[ "${LIST_MS}" -lt 1000 ]] || fail "list limit=500 took ${LIST_MS}ms (budget 1000ms)"
[[ "${AGG_MS}" -lt 1500 ]] || fail "GROUP BY aggregate over 25k rows took ${AGG_MS}ms (budget 1500ms)"
[[ "${GET_MS}" -lt 300 ]] || fail "mongo by-pk get took ${GET_MS}ms (budget 300ms)"
pass "budgets: cached schema <100ms, 500-row list <1s, 25k aggregate <1.5s, by-pk get <300ms"

green "[M23] OK — live edge battery: filter dialects, guards, envelopes, lifecycles all pinned"
