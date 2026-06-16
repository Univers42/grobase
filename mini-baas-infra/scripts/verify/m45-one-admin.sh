#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m45-one-admin.sh                                   :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/12 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/12 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M45 — Phase F gate: the embedded admin dashboard + admin API.
#   1. one image ≤ 12 MB with the UI embedded; /_/ serves HTML (no-store,
#      nosniff), /_ redirects;
#   2. the dashboard page drives only public contracts (sanity greps);
#   3. admin API: users list/delete (cascades refresh tokens), files list;
#      every admin endpoint 401s without a key and 403s for a non-admin key;
#   4. SKU identity: the NANO image serves NO dashboard (404 on /_/) and no
#      admin user endpoints;
#   5. idle RSS ≤ 15 MiB with the UI embedded.

set -euo pipefail
cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
step(){ cyan "[M45] $*"; }
fail(){ red "[M45] FAIL — $*"; cleanup; exit 1; }
ok(){ green "  ✓ $*"; }

ONE_IMAGE="${ONE_IMAGE:-binocle-one}"
NANO_IMAGE="${NANO_IMAGE:-binocle-nano}"
ONE_NAME="m45-one-$$"
NANO_NAME="m45-nano-$$"
PORT="${ONE_PORT:-18947}"
NANO_PORT="${NANO_GATE_PORT:-18948}"
KEY="m45-admin-$(date +%s)-deterministic"
BASE="http://127.0.0.1:${PORT}"

cleanup(){ docker rm -fv "${ONE_NAME}" "${NANO_NAME}" >/dev/null 2>&1 || true; }
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

step "1/5 one image budget + dashboard served"
IMG_MB=$(( $(docker image inspect --format '{{.Size}}' "${ONE_IMAGE}") / 1024 / 1024 ))
(( IMG_MB <= 12 )) || fail "image ${IMG_MB} MB > 12 MB budget"
docker run -d --name "${ONE_NAME}" -p "${PORT}:8090" -e NANO_ADMIN_KEY="${KEY}" "${ONE_IMAGE}" >/dev/null
for i in $(seq 1 20); do
  curl -sf "${BASE}/v1/health" >/dev/null 2>&1 && break
  [[ $i -eq 20 ]] && fail "binocle-one never came up"
  sleep 0.5
done
HDRS=$(curl -s -D- -o /dev/null "${BASE}/_/")
grep -qi "200" <<<"$(head -1 <<<"$HDRS")" || fail "/_/ not served: $(head -1 <<<"$HDRS")"
grep -qi "content-type: text/html" <<<"$HDRS" || fail "wrong content type"
grep -qi "cache-control: no-store" <<<"$HDRS" || fail "dashboard must be no-store"
grep -qi "x-content-type-options: nosniff" <<<"$HDRS" || fail "nosniff missing"
RED=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "${BASE}/_")
grep -q "/_/" <<<"$RED" || fail "/_ must redirect to /_/: $RED"
ok "image ${IMG_MB} MB ≤ 12; /_/ HTML + no-store + nosniff; /_ redirects"

step "2/5 page drives public contracts only"
PAGE=$(curl -s "${BASE}/_/")
for needle in "/data/v1/schema" "/data/v1/schema/ddl" "/nano/v1/keys" "/nano/v1/raw" "/one/v1/admin/users" "/nano/v1/realtime"; do
  grep -q "${needle}" <<<"$PAGE" || fail "page missing ${needle}"
done
grep -q "binocle" <<<"$PAGE" || fail "branding missing"
ok "collections/grid/keys/users/realtime wiring present"

step "3/5 admin API: users + files, scope-gated"
R=$(req POST /one/v1/auth/register "" '{"email":"mona@local.dev","password":"mona-pass-1234"}')
[[ "$(status_of "$R")" == "201" ]] || fail "register: $R"
MUID=$(jget "d['user']['id']" "$R"); REF=$(jget "d['refresh']" "$R")
R=$(req GET /one/v1/admin/users "X-Baas-Api-Key: ${KEY}")
grep -q "mona@local.dev" <<<"$R" || fail "users list: $R"
R=$(req GET /one/v1/admin/users "")
[[ "$(status_of "$R")" == "401" ]] || fail "users list without key must 401: $R"
RW=$(req POST /nano/v1/keys "X-Baas-Api-Key: ${KEY}" '{"name":"rw-only","scopes":["read","write"]}')
RW_KEY=$(jget "d['key']" "$RW")
R=$(req GET /one/v1/admin/users "X-Baas-Api-Key: ${RW_KEY}")
[[ "$(status_of "$R")" == "403" ]] || fail "non-admin key must 403: $R"
R=$(req GET /one/v1/admin/files "X-Baas-Api-Key: ${KEY}")
[[ "$(status_of "$R")" == "200" ]] || fail "files list: $R"
R=$(req DELETE "/one/v1/admin/users/${MUID}" "X-Baas-Api-Key: ${KEY}")
[[ "$(status_of "$R")" == "204" ]] || fail "delete user: $R"
R=$(req POST /one/v1/auth/refresh "" "{\"refresh\":\"${REF}\"}")
[[ "$(status_of "$R")" == "401" ]] || fail "deleted user's refresh must die: $R"
R=$(req POST /one/v1/auth/login "" '{"email":"mona@local.dev","password":"mona-pass-1234"}')
[[ "$(status_of "$R")" == "401" ]] || fail "deleted user must not log in: $R"
ok "users list/delete (cascade) + files; 401 anonymous, 403 non-admin"

step "4/5 nano stays headless (SKU identity)"
docker run -d --name "${NANO_NAME}" -p "${NANO_PORT}:8090" -e NANO_ADMIN_KEY="${KEY}" "${NANO_IMAGE}" >/dev/null
for i in $(seq 1 20); do
  curl -sf "http://127.0.0.1:${NANO_PORT}/v1/health" >/dev/null 2>&1 && break
  [[ $i -eq 20 ]] && fail "nano never came up"
  sleep 0.5
done
S=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${NANO_PORT}/_/")
[[ "$S" == "404" ]] || fail "nano must NOT serve the dashboard (got $S)"
S=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Baas-Api-Key: ${KEY}" "http://127.0.0.1:${NANO_PORT}/one/v1/admin/users")
[[ "$S" == "404" ]] || fail "nano must not expose admin user endpoints (got $S)"
ok "nano serves no dashboard and no /one admin surface"

step "5/5 idle RSS ≤ 15 MiB"
sleep 2
MEM_TOKEN=$(docker stats --no-stream --format '{{.MemUsage}}' "${ONE_NAME}" | awk '{print $1}')
MEM_MIB=$(awk -v v="${MEM_TOKEN}" 'BEGIN{u=v; sub(/[0-9.]+/,"",u); n=v; sub(/[A-Za-z]+/,"",n); n=n+0;
  if(u=="GiB") printf "%.1f", n*1024; else if(u=="KiB") printf "%.3f", n/1024; else printf "%.1f", n}')
awk -v m="${MEM_MIB}" 'BEGIN{exit !(m<=15)}' || fail "idle RSS ${MEM_MIB} MiB > 15 MiB"
ok "idle RSS ${MEM_MIB} MiB ≤ 15 MiB"

green "[M45] ALL GATES GREEN — binocle-one ships its dashboard at /_/ (${IMG_MB} MB total, ${MEM_MIB} MiB idle); nano stays headless"
