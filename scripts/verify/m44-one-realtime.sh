#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m44-one-realtime.sh                                :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/12 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/12 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M44 — Phase E gate: realtime topic filtering + owner-filtered delivery +
# `fields` response projection.
#   1. `fields` projection on /data/v1 list: only requested columns return
#      (JWT and key paths); absent fields = full rows (wire unchanged);
#   2. SSE ?topics=: a subscriber on table A receives A-mutations and does
#      NOT receive B-mutations; db:<id> tokens match too;
#   3. owner filtering: user JWT subscribers only see their OWN mutations;
#      a machine key subscriber sees everything;
#   4. events carry the owner stamp.

set -euo pipefail
cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
step(){ cyan "[M44] $*"; }
fail(){ red "[M44] FAIL — $*"; cleanup; exit 1; }
ok(){ green "  ✓ $*"; }

IMAGE="${ONE_IMAGE:-binocle-one}"
NAME="m44-one-$$"
PORT="${ONE_PORT:-18946}"
KEY="m44-admin-$(date +%s)-deterministic"
BASE="http://127.0.0.1:${PORT}"
TMP="$(mktemp -d)"

cleanup(){ docker rm -fv "${NAME}" >/dev/null 2>&1 || true; rm -rf "${TMP}"; }
trap cleanup EXIT

req(){ # method path auth body → body<TAB>status
  local method="$1" path="$2" auth="$3" body="${4:-}"
  local args=(-s -w $'\t%{http_code}' -X "${method}" "${BASE}${path}" -H "Content-Type: application/json")
  [[ -n "${auth}" ]] && args+=(-H "${auth}")
  [[ -n "${body}" ]] && args+=(-d "${body}")
  curl "${args[@]}"
}
status_of(){ awk -F'\t' '{print $NF}' <<<"$1"; }
jget(){ python3 -c "import sys,json;d=json.loads(sys.stdin.read().rsplit('\t',1)[0]);print($1)" <<<"$2"; }

step "0/4 boot + two users + tables"
docker image inspect "${IMAGE}" >/dev/null 2>&1 || fail "image '${IMAGE}' not built (make one-build)"
docker run -d --name "${NAME}" -p "${PORT}:8090" -e NANO_ADMIN_KEY="${KEY}" "${IMAGE}" >/dev/null
for i in $(seq 1 20); do
  curl -sf "${BASE}/v1/health" >/dev/null 2>&1 && break
  [[ $i -eq 20 ]] && fail "binocle-one never came up"
  sleep 0.5
done
R=$(req POST /one/v1/auth/register "" '{"email":"kate@local.dev","password":"kate-pass-1234"}')
TOK_K=$(jget "d['token']" "$R"); UID_K=$(jget "d['user']['id']" "$R")
R=$(req POST /one/v1/auth/register "" '{"email":"liam@local.dev","password":"liam-pass-1234"}')
TOK_L=$(jget "d['token']" "$R")
req POST /nano/v1/raw "X-Baas-Api-Key: ${KEY}" '{"db_id":"main","statement":"CREATE TABLE IF NOT EXISTS alpha (id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, title TEXT, secret TEXT)"}' >/dev/null
req POST /nano/v1/raw "X-Baas-Api-Key: ${KEY}" '{"db_id":"main","statement":"CREATE TABLE IF NOT EXISTS beta (id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, title TEXT)"}' >/dev/null
ok "server up; kate + liam; tables alpha/beta"

step "1/4 fields projection on /data/v1"
req POST /data/v1/query "Authorization: Bearer ${TOK_K}" '{"db_id":"main","operation":{"op":"insert","resource":"alpha","data":{"id":"a1","title":"hello","secret":"s3cr3t"}}}' >/dev/null
R=$(req POST /data/v1/query "Authorization: Bearer ${TOK_K}" '{"db_id":"main","operation":{"op":"list","resource":"alpha","fields":["id","title"]}}')
[[ "$(status_of "$R")" == "200" ]] || fail "projected list: $R"
grep -q '"title":"hello"' <<<"$R" || fail "projected column missing: $R"
grep -q '"secret"' <<<"$R" && fail "non-projected column leaked: $R"
grep -q '"owner_id"' <<<"$R" && fail "owner_id leaked through projection: $R"
R=$(req POST /data/v1/query "Authorization: Bearer ${TOK_K}" '{"db_id":"main","operation":{"op":"list","resource":"alpha"}}')
grep -q '"secret":"s3cr3t"' <<<"$R" || fail "absent fields must return full rows: $R"
ok "fields:[id,title] narrows rows; absent fields = full rows"

step "2/4 SSE ?topics= filters tables and dbs"
( timeout 10 curl -sN "${BASE}/nano/v1/realtime?key=${KEY}&topics=alpha" > "${TMP}/sub_alpha" 2>/dev/null & )
( timeout 10 curl -sN "${BASE}/nano/v1/realtime?key=${KEY}&topics=db:main" > "${TMP}/sub_db" 2>/dev/null & )
sleep 1
req POST /data/v1/query "Authorization: Bearer ${TOK_K}" '{"db_id":"main","operation":{"op":"insert","resource":"beta","data":{"id":"b1","title":"beta row"}}}' >/dev/null
req POST /data/v1/query "Authorization: Bearer ${TOK_K}" '{"db_id":"main","operation":{"op":"insert","resource":"alpha","data":{"id":"a2","title":"alpha row"}}}' >/dev/null
for i in $(seq 1 14); do
  grep -q '"table":"alpha"' "${TMP}/sub_alpha" 2>/dev/null && break
  [[ $i -eq 14 ]] && fail "alpha subscriber never got the alpha event"
  sleep 0.5
done
grep -q '"table":"beta"' "${TMP}/sub_alpha" && fail "topics=alpha received a beta event"
grep -q '"table":"beta"' "${TMP}/sub_db" || fail "db:main subscriber missed the beta event"
grep -q '"table":"alpha"' "${TMP}/sub_db" || fail "db:main subscriber missed the alpha event"
ok "table topic excludes other tables; db topic sees both"

step "3/4 owner filtering for user subscribers"
( timeout 10 curl -sN "${BASE}/nano/v1/realtime?token=${TOK_K}" > "${TMP}/sub_kate" 2>/dev/null & )
( timeout 10 curl -sN "${BASE}/nano/v1/realtime?key=${KEY}" > "${TMP}/sub_admin" 2>/dev/null & )
sleep 1
req POST /data/v1/query "Authorization: Bearer ${TOK_L}" '{"db_id":"main","operation":{"op":"insert","resource":"alpha","data":{"id":"a3","title":"liam private"}}}' >/dev/null
req POST /data/v1/query "Authorization: Bearer ${TOK_K}" '{"db_id":"main","operation":{"op":"insert","resource":"alpha","data":{"id":"a4","title":"kate own"}}}' >/dev/null
for i in $(seq 1 14); do
  grep -q '"pk":"a4"' "${TMP}/sub_kate" 2>/dev/null && break
  [[ $i -eq 14 ]] && fail "kate never received her own event"
  sleep 0.5
done
grep -q '"pk":"a3"' "${TMP}/sub_kate" && fail "kate received LIAM'S event (owner filter broken)"
for i in $(seq 1 14); do
  grep -q '"pk":"a3"' "${TMP}/sub_admin" 2>/dev/null && grep -q '"pk":"a4"' "${TMP}/sub_admin" 2>/dev/null && break
  [[ $i -eq 14 ]] && fail "admin key subscriber missed events"
  sleep 0.5
done
ok "JWT subscriber sees only own mutations; key subscriber sees the bus"

step "4/4 events carry the owner stamp"
grep -q "\"owner\":\"user:${UID_K}\"" "${TMP}/sub_admin" || fail "owner stamp missing in events"
ok "owner stamped on the wire"

green "[M44] ALL GATES GREEN — topics + owner-filtered SSE and fields projection live on binocle-one"
