#!/usr/bin/env bash
# **************************************************************************** #
#    multitenant.sh — drive load across a seeded tenant fleet (program B2)     #
# **************************************************************************** #
#
# Reads artifacts/scale/tenants-<SCALE>.jsonl (from `make scale-seed`), builds
# a {key, db_id} tenant list, ensures the shared bench_items table exists (the
# seeded mounts share one DSN under shared_rls, so one create serves all —
# each tenant's list is owner-scoped, returning 200 + its own rows), then runs
# k6/multitenant.js spreading RATE across all tenants. Output:
# artifacts/bench/multitenant-<SCALE>.json (p50/p95/p99 + 5xx + 429 counts).
#
# Env: SCALE (required), RATE (default 200), DURATION (default 60s),
#      DIST (uniform|zipf, default zipf — the realistic hot-tenant shape).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-bench.sh"

cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }

SCALE="${SCALE:-200}"
RATE="${RATE:-200}"
DURATION="${DURATION:-60s}"
DIST="${DIST:-zipf}"
TABLE="bench_items"
JSONL="${BENCH_ROOT}/artifacts/scale/tenants-${SCALE}.jsonl"
[[ -f "${JSONL}" ]] || { red "no tenant file ${JSONL} (run make scale-seed SCALE=${SCALE})"; exit 1; }

KONG_PORT="$(bench_port mini-baas-kong 8000/tcp)"
[[ -n "${KONG_PORT}" ]] || { red "kong not up"; exit 1; }
KONG="http://127.0.0.1:${KONG_PORT}"
ANON="$(bench_container_env mini-baas-kong KONG_PUBLIC_API_KEY)"

# Tenant list (only ones with a usable key + at least one mount).
TLIST="${BENCH_OUT_DIR}/mt-tenants-${SCALE}.json"
jq -c -s '[.[] | select(.key != null and (.db_ids|length>0)) | {key:.key, db_id:.db_ids[0]}]' "${JSONL}" > "${TLIST}"
N="$(jq 'length' "${TLIST}")"
(( N > 0 )) || { red "no usable tenants in ${JSONL}"; exit 1; }
cyan "[multitenant] ${N} tenants × ${RATE} rps × ${DURATION} (dist=${DIST})"

# Ensure the shared bench_items table exists (one tenant creates it; shared_rls
# + shared DSN → all tenants can query it, owner-scoped).
FIRST_KEY="$(jq -r '.[0].key' "${TLIST}")"
FIRST_DB="$(jq -r '.[0].db_id' "${TLIST}")"
ddl(){ curl -s -w ' HTTP%{http_code}' -X POST "${KONG}/data/v1/schema/ddl" \
	-H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${FIRST_KEY}" -H 'Content-Type: application/json' \
	-d "{\"db_id\":\"${FIRST_DB}\",\"ddl\":$1}"; }
OUT="$(ddl '{"op":"create_table","table":"'"${TABLE}"'","columns":[
  {"name":"id","normalized_type":"text","nullable":false},
  {"name":"name","normalized_type":"text","nullable":true},
  {"name":"grp","normalized_type":"text","nullable":true},
  {"name":"val","normalized_type":"integer","nullable":true}],"primary_key":["id"]}')"
echo "${OUT}" | grep -qE 'HTTP20[01]|HTTP409' || { red "shared table create failed: ${OUT}"; exit 1; }
green "[multitenant] shared ${TABLE} ready"

bench_k6 "multitenant.js" "multitenant-${SCALE}.json" \
	-e BASE="${KONG}" -e ANON="${ANON}" -e TENANTS_FILE="/out/$(basename "${TLIST}")" \
	-e TABLE="${TABLE}" -e RATE="${RATE}" -e DURATION="${DURATION}" -e DIST="${DIST}"

FINAL="${BENCH_OUT_DIR}/multitenant-${SCALE}.json"
green "[multitenant] artifact: ${FINAL#${BENCH_ROOT}/}"
jq -r '"  p50=\(.http.med)ms p95=\(.http.p95)ms p99=\(.http.p99)ms err=\(.err_pct)% 5xx=\(.server_errors) 429s=\(.rate_limited)"' "${FINAL}" 2>/dev/null || true
