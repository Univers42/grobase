#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m31-bypass-shadow.sh                               :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/10 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/10 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Gate for milestone M31: BYPASS SHADOW PARITY (Phase 7e).
#
# Proves the Phase-7 direct front door (`/data/v1`, Rust-native auth) returns
# IDENTICAL rows to the legacy TS path (`/query/v1` → query-router) for the same
# read ops against the same live mounts — the shadow evidence that gates the
# cutover (7f). Both paths terminate in the same Rust run_query → same engine
# query, so divergence here means a bypass-path bug, not an engine difference.
#
# Uses the app's real two-key auth (Kong anon `apikey` + tenant `X-Baas-Api-Key`)
# so it exercises exactly what a cut-over client would send.
#
set -euo pipefail

cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
fail(){ red "[M31] FAIL: $*"; exit 1; }
step(){ cyan "[M31] ${*}"; }
pass(){ green "[M31] PASS: ${*}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# verify → scripts → mini-baas-infra → baas → apps → <repo root>
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
APP_ENV="${ROOT}/apps/osionos/app/.env"

KONG="http://127.0.0.1:8002"
RUST="http://127.0.0.1:${DATA_PLANE_RUST_PORT:-4011}"

KEY="$(grep -E '^VITE_BAAS_API_KEY=' "${APP_ENV}" 2>/dev/null | cut -d= -f2- || true)"
[[ -n "${KEY}" ]] || fail "no VITE_BAAS_API_KEY in ${APP_ENV} (run the live-demo seed)"
ANON="$(docker inspect mini-baas-kong --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^KONG_PUBLIC_API_KEY=' | cut -d= -f2- || true)"
[[ -n "${ANON}" ]] || fail "no KONG_PUBLIC_API_KEY on the kong container"

docker inspect mini-baas-data-plane-router-rust >/dev/null 2>&1 || fail "rust router not running"
curl -fsS -o /dev/null "${RUST}/v1/capabilities" || fail "rust router unreachable"

command -v jq >/dev/null 2>&1 && HAVE_JQ=1 || HAVE_JQ=0
canon() { # canonicalize the rows array for comparison (jq if present, else raw)
  if [[ "${HAVE_JQ}" == "1" ]]; then jq -cS '.rows' 2>/dev/null; else python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d.get('rows'),sort_keys=True))"; fi
}

# A live mount the seed always registers (pg-commerce / customers).
PGC="d5d96d24-49ba-49d9-8a04-153ea0c1c871"

compare_list() { # $1 dbId $2 table $3 limit
  local db="$1" table="$2" lim="$3"
  local legacy bypass
  legacy="$(curl -s -X POST "${KONG}/query/v1/${db}/tables/${table}" \
    -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${KEY}" -H 'Content-Type: application/json' \
    -d "{\"op\":\"list\",\"limit\":${lim},\"sort\":{\"id\":\"asc\"}}" | canon)"
  bypass="$(curl -s -X POST "${RUST}/data/v1/query" \
    -H "X-Baas-Api-Key: ${KEY}" -H 'Content-Type: application/json' \
    -d "{\"db_id\":\"${db}\",\"operation\":{\"op\":\"list\",\"resource\":\"${table}\",\"limit\":${lim},\"sort\":{\"id\":\"asc\"}}}" | canon)"
  [[ -n "${legacy}" && "${legacy}" != "null" ]] || fail "legacy /query/v1 returned no rows for ${table}"
  [[ "${legacy}" == "${bypass}" ]] || {
    red "  legacy: ${legacy:0:160}"; red "  bypass: ${bypass:0:160}"
    fail "row divergence between /query/v1 and /data/v1 for ${table}"
  }
}

compare_aggregate() { # $1 dbId $2 table
  local db="$1" table="$2" legacy bypass
  legacy="$(curl -s -X POST "${KONG}/query/v1/${db}/tables/${table}" \
    -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${KEY}" -H 'Content-Type: application/json' \
    -d '{"op":"aggregate","aggregate":{"aggregates":[{"func":"count","alias":"n"}]}}' | canon)"
  bypass="$(curl -s -X POST "${RUST}/data/v1/query" \
    -H "X-Baas-Api-Key: ${KEY}" -H 'Content-Type: application/json' \
    -d "{\"db_id\":\"${db}\",\"operation\":{\"op\":\"aggregate\",\"resource\":\"${table}\",\"aggregate\":{\"aggregates\":[{\"func\":\"count\",\"alias\":\"n\"}]}}}" | canon)"
  [[ "${legacy}" == "${bypass}" ]] || {
    red "  legacy: ${legacy}"; red "  bypass: ${bypass}"
    fail "aggregate divergence between /query/v1 and /data/v1 for ${table}"
  }
}

step "discovering the pg-commerce first table"
TABLE="$(curl -s "${KONG}/query/v1/${PGC}/schema" -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${KEY}" | { jq -r '.tables[0].name' 2>/dev/null || python3 -c "import sys,json;print(json.load(sys.stdin)['tables'][0]['name'])"; })"
[[ -n "${TABLE}" && "${TABLE}" != "null" ]] || fail "could not introspect a pg-commerce table"

step "list parity (legacy /query/v1 vs bypass /data/v1) on ${TABLE}"
compare_list "${PGC}" "${TABLE}" 5
pass "list rows identical across both front doors"

step "aggregate parity on ${TABLE}"
compare_aggregate "${PGC}" "${TABLE}"
pass "aggregate result identical across both front doors"

# A short soak: many list calls, all must stay identical.
step "shadow soak: 25 list calls through both paths"
for _ in $(seq 1 25); do compare_list "${PGC}" "${TABLE}" 3; done
pass "25/25 soak iterations parity-clean"

green "[M31] ALL GATES GREEN — /data/v1 bypass is row-for-row identical to /query/v1 (cutover-ready)"
