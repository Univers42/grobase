#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m36-cutover-parity.sh                              :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/11 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/11 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Gate for milestone M36: D6 PRODUCTION CUTOVER PARITY.
# m31 proves /data/v1 == /query/v1 on the DIRECT Rust port. This proves the same
# rows through the **Kong production gateway** for BOTH routes against the APP's
# REAL live mount (warm, enterprise tier) — the exact path the app flips to when
# it switches its base path /query/v1 → /data/v1. Read-only (touches no data);
# the live "m18" evidence that the bypass is cutover-ready. query-router stays
# the fallback (no deletion). Skips cleanly if the live-demo seed is absent.
set -uo pipefail

fail() { printf '\033[0;31m[M36] FAIL: %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '\033[0;32m[M36] %s\033[0m\n' "$*"; }
step() { printf '\033[0;36m[M36] %s\033[0m\n' "$*"; }
skip() { printf '\033[0;33m[M36] SKIP: %s\033[0m\n' "$*"; exit 0; }

APP_ENV="${APP_ENV:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)/apps/osionos/app/.env}"
[[ -f "${APP_ENV}" ]] || skip "no app .env (${APP_ENV}) — run make seed-live-demo first"

APPK="$(sed -n 's/^VITE_BAAS_API_KEY=//p' "${APP_ENV}" | head -1)"
[[ "${APPK}" == mbk_* ]] || skip "no VITE_BAAS_API_KEY in app .env"
# First postgresql mount from VITE_BAAS_LIVE_MOUNTS (the cutover target engine).
DB="$(python3 -c '
import sys,json,re
m=re.search(r"VITE_BAAS_LIVE_MOUNTS=(.*)", open(sys.argv[1]).read())
if not m: sys.exit(0)
for x in json.loads(m.group(1).strip()):
    if x.get("engine")=="postgresql": print(x["dbId"]); break
' "${APP_ENV}")"
[[ -n "${DB}" ]] || skip "no postgresql mount in VITE_BAAS_LIVE_MOUNTS"

KONG_PORT="$(docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://')"
[[ -n "${KONG_PORT}" ]] || fail "kong not up"
KONG="http://127.0.0.1:${KONG_PORT}"
ANON="$(docker inspect mini-baas-kong --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^KONG_PUBLIC_API_KEY=//p' | head -1)"
[[ -n "${ANON}" ]] || fail "no KONG_PUBLIC_API_KEY on kong"

# A resource present in the seeded demo (the commerce dataset's customers table).
TBL="${M36_TABLE:-customers}"
rows() { python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin).get("rows"),sort_keys=True))' 2>/dev/null; }
dp() { curl -s -X POST "${KONG}/data/v1/query" -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${APPK}" -H 'Content-Type: application/json' -d "$1"; }
qr() { curl -s -X POST "${KONG}/query/v1/${DB}/tables/${TBL}" -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${APPK}" -H 'Content-Type: application/json' -d "$1"; }

step "cutover target: Kong ${KONG}  mount ${DB:0:8}…/${TBL} (app's real enterprise mount)"

step "1/3 list parity (limit 25, sorted)"
DP=$(dp "{\"db_id\":\"${DB}\",\"operation\":{\"op\":\"list\",\"resource\":\"${TBL}\",\"limit\":25,\"sort\":{\"id\":\"asc\"}}}" | rows)
QR=$(qr '{"op":"list","limit":25,"sort":{"id":"asc"}}' | rows)
[[ -n "${DP}" && "${DP}" != "null" ]] || fail "Kong /data/v1 list returned no rows"
[[ "${DP}" == "${QR}" ]] || fail "list divergence (data vs query) on the cutover route"
ok "25 rows byte-identical across Kong /data/v1 and Kong /query/v1"

step "2/3 get parity (id=1)"
DP=$(dp "{\"db_id\":\"${DB}\",\"operation\":{\"op\":\"get\",\"resource\":\"${TBL}\",\"filter\":{\"id\":1}}}" | rows)
QR=$(qr '{"op":"get","filter":{"id":1}}' | rows)
[[ "${DP}" == "${QR}" && -n "${DP}" && "${DP}" != "null" ]] || fail "get divergence on the cutover route"
ok "get row identical"

step "3/3 aggregate parity (count) — enterprise tier serves it on both routes"
DP=$(dp "{\"db_id\":\"${DB}\",\"operation\":{\"op\":\"aggregate\",\"resource\":\"${TBL}\",\"aggregate\":{\"aggregates\":[{\"func\":\"count\",\"alias\":\"n\"}]}}}" | rows)
QR=$(qr '{"op":"aggregate","aggregate":{"aggregates":[{"func":"count","alias":"n"}]}}' | rows)
[[ "${DP}" == "${QR}" && -n "${DP}" && "${DP}" != "null" ]] || fail "aggregate divergence on the cutover route (data=${DP} query=${QR})"
ok "aggregate (count) identical"

printf '\033[0;32m[M36] ALL GATES GREEN — the Kong /data/v1 cutover route is row-identical to /query/v1 on the app'\''s live mount (list/get/aggregate); the bypass is production-ready, the app can flip its base path safely\033[0m\n'
