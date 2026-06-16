#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m40-one.sh                                         :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/12 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/12 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M40 — binocle-one gate ("our PocketBase"): everything m37 proves for nano,
# plus the account layer, against a THROWAWAY container of the one image:
#   1. size budget — image ≤ 12 MB (PocketBase is 30.1 MB);
#   2. register → 201 with JWT + refresh; duplicate email → 409; weak pw → 400;
#   3. login → 200; wrong password → 401;
#   4. JWT CRUD on /data/v1: user A's rows are invisible to user B and to A's
#      stale identity after… (per-user owner-scoping on the SAME door);
#   5. the admin KEY still works alongside users; admin reads ACROSS users
#      via /nano/v1/raw (the escape hatch — CRUD stays owner-scoped);
#   6. refresh rotation: old refresh dies after use, new one works; logout
#      kills the refresh; JWT keeps working until exp (stateless by design);
#   7. SSE realtime accepts ?token= (user JWT) and delivers a mutation;
#   8. idle RSS ≤ 15 MiB.

set -euo pipefail
cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
step(){ cyan "[M40] $*"; }
fail(){ red "[M40] FAIL — $*"; cleanup; exit 1; }
ok(){ green "  ✓ $*"; }

IMAGE="${ONE_IMAGE:-binocle-one}"
NAME="m40-one-$$"
PORT="${ONE_PORT:-18938}"
KEY="m38-admin-$(date +%s)-deterministic"
BASE="http://127.0.0.1:${PORT}"

cleanup(){ docker rm -fv "${NAME}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

req(){ # method path auth-header-value body  → body<TAB>status (auth "" = none)
  local method="$1" path="$2" auth="$3" body="${4:-}"
  local args=(-s -w $'\t%{http_code}' -X "${method}" "${BASE}${path}" -H "Content-Type: application/json")
  [[ -n "${auth}" ]] && args+=(-H "${auth}")
  [[ -n "${body}" ]] && args+=(-d "${body}")
  curl "${args[@]}"
}
status_of(){ awk -F'\t' '{print $NF}' <<<"$1"; }
field(){ python3 -c "import sys,json;print(json.loads(sys.stdin.read().rsplit('\t',1)[0]).get('$1',''))" <<<"$2"; }

step "1/8 image present + ≤12 MB budget"
docker image inspect "${IMAGE}" >/dev/null 2>&1 || fail "image '${IMAGE}' not built (make one-build)"
IMG_MB=$(( $(docker image inspect --format '{{.Size}}' "${IMAGE}") / 1024 / 1024 ))
(( IMG_MB <= 12 )) || fail "image ${IMG_MB} MB > 12 MB budget"
ok "image ${IMG_MB} MB ≤ 12 MB (PocketBase: 30.1 MB)"

docker run -d --name "${NAME}" -p "${PORT}:8090" -e NANO_ADMIN_KEY="${KEY}" "${IMAGE}" >/dev/null
for i in $(seq 1 20); do
  curl -sf "${BASE}/v1/health" >/dev/null 2>&1 && break
  [[ $i -eq 20 ]] && fail "health never came up"
  sleep 0.5
done

step "2/8 register: 201 + JWT + refresh; 409 dup; 400 weak"
RA=$(req POST /one/v1/auth/register "" '{"email":"alice@local.dev","password":"alice-pass-123"}')
[[ "$(status_of "$RA")" == "201" ]] || fail "register alice: $RA"
TOK_A=$(field token "$RA"); REF_A=$(field refresh "$RA")
[[ -n "${TOK_A}" && -n "${REF_A}" ]] || fail "register returned no token/refresh: $RA"
R=$(req POST /one/v1/auth/register "" '{"email":"alice@local.dev","password":"alice-pass-123"}')
[[ "$(status_of "$R")" == "409" ]] || fail "duplicate email must 409: $R"
R=$(req POST /one/v1/auth/register "" '{"email":"weak@local.dev","password":"short"}')
[[ "$(status_of "$R")" == "400" ]] || fail "weak password must 400: $R"
RB=$(req POST /one/v1/auth/register "" '{"email":"bob@local.dev","password":"bob-pass-12345"}')
TOK_B=$(field token "$RB")
ok "alice + bob registered; 409/400 enforced"

step "3/8 login: 200 good / 401 bad"
R=$(req POST /one/v1/auth/login "" '{"email":"alice@local.dev","password":"alice-pass-123"}')
[[ "$(status_of "$R")" == "200" ]] || fail "login: $R"
R=$(req POST /one/v1/auth/login "" '{"email":"alice@local.dev","password":"wrong-password"}')
[[ "$(status_of "$R")" == "401" ]] || fail "bad password must 401: $R"
R=$(req GET /one/v1/auth/me "Authorization: Bearer ${TOK_A}")
grep -q "alice@local.dev" <<<"$R" || fail "/me: $R"
ok "login + /me green, bad password 401"

step "4/8 per-user data isolation on /data/v1"
req POST /nano/v1/raw "X-Baas-Api-Key: ${KEY}" '{"db_id":"main","statement":"CREATE TABLE IF NOT EXISTS todos (id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, title TEXT)"}' >/dev/null
R=$(req POST /data/v1/query "Authorization: Bearer ${TOK_A}" '{"db_id":"main","operation":{"op":"insert","resource":"todos","data":{"id":"a1","title":"alice secret"}}}')
[[ "$(status_of "$R")" == "200" ]] || fail "alice insert via JWT: $R"
R=$(req POST /data/v1/query "Authorization: Bearer ${TOK_A}" '{"db_id":"main","operation":{"op":"list","resource":"todos"}}')
grep -q "alice secret" <<<"$R" || fail "alice list misses her row: $R"
R=$(req POST /data/v1/query "Authorization: Bearer ${TOK_B}" '{"db_id":"main","operation":{"op":"list","resource":"todos"}}')
grep -q "alice secret" <<<"$R" && fail "BOB CAN SEE ALICE'S ROW (isolation broken): $R"
[[ "$(status_of "$R")" == "200" ]] || fail "bob list: $R"
ok "alice's rows invisible to bob (owner-scoped per user)"

step "5/8 admin key coexists; raw reads across users"
R=$(req POST /data/v1/query "X-Baas-Api-Key: ${KEY}" '{"db_id":"main","operation":{"op":"list","resource":"todos"}}')
grep -q "alice secret" <<<"$R" && fail "admin CRUD must also be owner-scoped (got alice's row)"
R=$(req POST /nano/v1/raw "X-Baas-Api-Key: ${KEY}" '{"db_id":"main","statement":"SELECT title, owner_id FROM todos","expect_rows":true}')
grep -q "alice secret" <<<"$R" || fail "admin raw cross-user read: $R"
grep -q '"owner_id":"user:' <<<"$R" || fail "rows not stamped user:<id>: $R"
ok "admin raw sees all; rows stamped user:<id>; CRUD stays scoped"

step "6/8 refresh rotation + logout"
R=$(req POST /one/v1/auth/refresh "" "{\"refresh\":\"${REF_A}\"}")
[[ "$(status_of "$R")" == "200" ]] || fail "refresh: $R"
REF_A2=$(field refresh "$R")
R=$(req POST /one/v1/auth/refresh "" "{\"refresh\":\"${REF_A}\"}")
[[ "$(status_of "$R")" == "401" ]] || fail "consumed refresh must 401: $R"
R=$(req POST /one/v1/auth/logout "" "{\"refresh\":\"${REF_A2}\"}")
[[ "$(status_of "$R")" == "204" ]] || fail "logout: $R"
R=$(req POST /one/v1/auth/refresh "" "{\"refresh\":\"${REF_A2}\"}")
[[ "$(status_of "$R")" == "401" ]] || fail "logged-out refresh must 401: $R"
ok "rotation single-use; logout revokes"

step "7/8 SSE accepts a user JWT (?token=)"
SSE_OUT="$(mktemp)"
( timeout 8 curl -sN "${BASE}/nano/v1/realtime?token=${TOK_A}" > "${SSE_OUT}" 2>/dev/null & )
sleep 1
req POST /data/v1/query "Authorization: Bearer ${TOK_A}" '{"db_id":"main","operation":{"op":"insert","resource":"todos","data":{"id":"a2","title":"sse"}}}' >/dev/null
for i in $(seq 1 14); do
  grep -q '"op":"insert"' "${SSE_OUT}" 2>/dev/null && break
  [[ $i -eq 14 ]] && fail "SSE event never arrived for a JWT subscriber"
  sleep 0.5
done
rm -f "${SSE_OUT}"
ok "JWT subscriber received the mutation"

step "8/8 idle RSS ≤ 15 MiB"
sleep 2
MEM_TOKEN=$(docker stats --no-stream --format '{{.MemUsage}}' "${NAME}" | awk '{print $1}')
MEM_MIB=$(awk -v v="${MEM_TOKEN}" 'BEGIN{u=v; sub(/[0-9.]+/,"",u); n=v; sub(/[A-Za-z]+/,"",n); n=n+0;
  if(u=="GiB") printf "%.1f", n*1024; else if(u=="KiB") printf "%.3f", n/1024; else printf "%.1f", n}')
awk -v m="${MEM_MIB}" 'BEGIN{exit !(m<=15)}' || fail "idle RSS ${MEM_MIB} MiB > 15 MiB budget"
ok "idle RSS ${MEM_MIB} MiB ≤ 15 MiB (PocketBase ~12 MiB with NO accounts beyond superuser)"

green "[M40] ALL GATES GREEN — binocle-one: ${IMG_MB} MB image, ${MEM_MIB} MiB idle, accounts + JWT + per-user isolation + SSE on one static binary"
