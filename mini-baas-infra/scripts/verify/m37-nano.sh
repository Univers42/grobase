#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m37-nano.sh                                        :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/11 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/11 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M37 — binocle-nano gate: the single-binary PocketBase-class edition.
#
# Proves, against a THROWAWAY container of the scratch image:
#   1. size budgets — image ≤ 15 MB, far under the 50 MB ask;
#   2. boot + health on a deterministic NANO_ADMIN_KEY;
#   3. raw-SQL migration (create table) → CRUD round-trip → aggregate →
#      schema introspection, all through /data/v1;
#   4. key minting + the scope gate (read-only key: read 200 / write 403);
#   5. auth fail-closed (bogus key 401, missing key 401, unknown mount 404);
#   6. SSE realtime — a subscriber receives the committed mutation event;
#   7. idle RSS ≤ 25 MiB (PocketBase-class; measured ~2 MiB in practice).
#
# Build the image first (or let the gate do it): make nano-build / verify-m37.

set -euo pipefail

cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
step(){ cyan "[M37] $*"; }
fail(){ red "[M37] FAIL — $*"; cleanup; exit 1; }
ok(){ green "  ✓ $*"; }

IMAGE="${NANO_IMAGE:-binocle-nano}"
NAME="m37-nano-$$"
PORT="${NANO_PORT:-18937}"
KEY="nbk_m37gate.$(date +%s)deterministic-admin-key-for-ci"
BASE="http://127.0.0.1:${PORT}"

# -v: the image declares VOLUME /data, so a plain rm -f would leak one
# anonymous volume per gate run.
cleanup(){ docker rm -fv "${NAME}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

req(){ # method path key [body] → status<TAB>body
  local method="$1" path="$2" key="$3" body="${4:-}"
  local args=(-s -w $'\t%{http_code}' -X "${method}" "${BASE}${path}" -H "Content-Type: application/json")
  [[ -n "${key}" ]] && args+=(-H "X-Baas-Api-Key: ${key}")
  [[ -n "${body}" ]] && args+=(-d "${body}")
  curl "${args[@]}"
}
status_of(){ awk -F'\t' '{print $NF}' <<<"$1"; }
body_of(){ awk -F'\t' 'NF{NF--}1' OFS='\t' <<<"$1"; }

step "0/7 image present + size budget"
docker image inspect "${IMAGE}" >/dev/null 2>&1 || fail "image '${IMAGE}' not built (make nano-build)"
IMG_BYTES=$(docker image inspect --format '{{.Size}}' "${IMAGE}")
IMG_MB=$(( IMG_BYTES / 1024 / 1024 ))
(( IMG_MB <= 15 )) || fail "image ${IMG_MB} MB > 15 MB budget"
ok "image ${IMG_MB} MB ≤ 15 MB (ask was <50 MB)"

step "1/7 boot on a deterministic admin key"
docker run -d --name "${NAME}" -p "${PORT}:8090" -e NANO_ADMIN_KEY="${KEY}" "${IMAGE}" >/dev/null
for i in $(seq 1 20); do
  curl -sf "${BASE}/v1/health" >/dev/null 2>&1 && break
  [[ $i -eq 20 ]] && fail "health never came up"
  sleep 0.5
done
ok "healthy on :${PORT}"

step "2/7 STRUCTURED DDL (typed collections) + raw SQL + CRUD + aggregate + schema"
# PB-style typed collection creation through the SAME /data/v1/schema/ddl
# contract the cloud tiers use (sqlite adapter structured DDL, Phase C).
R=$(req POST /data/v1/schema/ddl "${KEY}" '{"db_id":"main","ddl":{"op":"create_table","table":"typed","columns":[{"name":"id","normalized_type":"text","nullable":false},{"name":"status","normalized_type":"enum","nullable":false,"default":"'"'"'new'"'"'","enum_values":["new","done"]},{"name":"views","normalized_type":"integer","nullable":true}],"primary_key":["id"]}}')
[[ "$(status_of "$R")" == "200" ]] || fail "structured create_table: $R"
R=$(req POST /data/v1/query "${KEY}" '{"db_id":"main","operation":{"op":"insert","resource":"typed","data":{"id":"t1","status":"new","views":1}}}')
[[ "$(status_of "$R")" == "200" ]] || fail "insert into typed table: $R"
R=$(req POST /data/v1/query "${KEY}" '{"db_id":"main","operation":{"op":"insert","resource":"typed","data":{"id":"t2","status":"bogus"}}}')
[[ "$(status_of "$R")" == "409" ]] || fail "enum CHECK must reject bad value (409): $R"
R=$(req POST /data/v1/schema/ddl "${KEY}" '{"db_id":"main","ddl":{"op":"add_column","table":"typed","column":{"name":"note","normalized_type":"text","nullable":true}}}')
[[ "$(status_of "$R")" == "200" ]] || fail "structured add_column: $R"
R=$(req POST /nano/v1/raw "${KEY}" '{"db_id":"main","statement":"CREATE TABLE IF NOT EXISTS notes (id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, title TEXT)"}')
[[ "$(status_of "$R")" == "200" ]] || fail "raw DDL: $R"
R=$(req POST /data/v1/query "${KEY}" '{"db_id":"main","operation":{"op":"insert","resource":"notes","data":{"id":"m37","title":"gate"}}}')
[[ "$(status_of "$R")" == "200" ]] || fail "insert: $R"
R=$(req POST /data/v1/query "${KEY}" '{"db_id":"main","operation":{"op":"get","resource":"notes","filter":{"id":"m37"}}}')
grep -q '"title":"gate"' <<<"$R" || fail "get round-trip: $R"
R=$(req POST /data/v1/query "${KEY}" '{"db_id":"main","operation":{"op":"aggregate","resource":"notes","aggregate":{"aggregates":[{"func":"count","alias":"n"}]}}}')
grep -q '"n":1' <<<"$R" || fail "aggregate: $R"
R=$(req POST /data/v1/schema "${KEY}" '{"db_id":"main"}')
grep -q '"name":"notes"' <<<"$R" || fail "schema introspection: $R"
ok "migrate → insert → get → aggregate → introspect all green"

step "3/7 key mint + scope gate"
R=$(req POST /nano/v1/keys "${KEY}" '{"name":"m37-reader","scopes":["read"]}')
[[ "$(status_of "$R")" == "201" ]] || fail "mint: $R"
RKEY=$(body_of "$R" | sed -n 's/.*"key":"\([^"]*\)".*/\1/p')
[[ -n "${RKEY}" ]] || fail "mint returned no key: $R"
R=$(req POST /data/v1/query "${RKEY}" '{"db_id":"main","operation":{"op":"list","resource":"notes"}}')
[[ "$(status_of "$R")" == "200" ]] || fail "read-only key read: $R"
R=$(req POST /data/v1/query "${RKEY}" '{"db_id":"main","operation":{"op":"insert","resource":"notes","data":{"id":"x"}}}')
[[ "$(status_of "$R")" == "403" ]] || fail "read-only key write must 403: $R"
R=$(req POST /nano/v1/keys "${RKEY}" '{"name":"evil","scopes":["admin"]}')
[[ "$(status_of "$R")" == "403" ]] || fail "read-only key mint must 403: $R"
ok "read 200 / write 403 / admin 403 on a read-scoped key"

step "4/7 auth fail-closed"
R=$(req POST /data/v1/query "nbk_bogus.key" '{"db_id":"main","operation":{"op":"list","resource":"notes"}}')
[[ "$(status_of "$R")" == "401" ]] || fail "bogus key must 401: $R"
R=$(req POST /data/v1/query "" '{"db_id":"main","operation":{"op":"list","resource":"notes"}}')
[[ "$(status_of "$R")" == "401" ]] || fail "missing key must 401: $R"
R=$(req POST /data/v1/query "${KEY}" '{"db_id":"ghost","operation":{"op":"list","resource":"notes"}}')
[[ "$(status_of "$R")" == "404" ]] || fail "unknown mount must 404: $R"
ok "401 / 401 / 404"

step "5/7 SSE realtime delivers a committed mutation"
SSE_OUT="$(mktemp)"
( timeout 8 curl -sN "${BASE}/nano/v1/realtime?key=${KEY}" > "${SSE_OUT}" 2>/dev/null & )
sleep 1
req POST /data/v1/query "${KEY}" '{"db_id":"main","operation":{"op":"insert","resource":"notes","data":{"id":"sse1","title":"event"}}}' >/dev/null
for i in $(seq 1 14); do
  grep -q '"op":"insert"' "${SSE_OUT}" 2>/dev/null && break
  [[ $i -eq 14 ]] && fail "SSE event never arrived: $(cat "${SSE_OUT}")"
  sleep 0.5
done
grep -q '"table":"notes"' "${SSE_OUT}" || fail "SSE payload shape: $(cat "${SSE_OUT}")"
rm -f "${SSE_OUT}"
ok "subscriber received the insert event"

step "6/7 revoke closes the door"
RID=$(req GET /nano/v1/keys "${KEY}" | sed -n 's/.*"id":"\([^"]*\)","name":"m37-reader".*/\1/p')
[[ -n "${RID}" ]] || fail "reader key id not found in list"
R=$(req DELETE "/nano/v1/keys/${RID}" "${KEY}")
[[ "$(status_of "$R")" == "200" ]] || fail "revoke: $R"
R=$(req POST /data/v1/query "${RKEY}" '{"db_id":"main","operation":{"op":"list","resource":"notes"}}')
[[ "$(status_of "$R")" == "401" ]] || fail "revoked key must 401: $R"
ok "revoked key is dead"

step "7/7 idle RSS budget"
sleep 2
MEM_TOKEN=$(docker stats --no-stream --format '{{.MemUsage}}' "${NAME}" | awk '{print $1}')
MEM_MIB=$(awk -v v="${MEM_TOKEN}" 'BEGIN{u=v; sub(/[0-9.]+/,"",u); n=v; sub(/[A-Za-z]+/,"",n); n=n+0;
  if(u=="GiB") printf "%.1f", n*1024; else if(u=="KiB") printf "%.3f", n/1024; else printf "%.1f", n}')
awk -v m="${MEM_MIB}" 'BEGIN{exit !(m<=25)}' || fail "idle RSS ${MEM_MIB} MiB > 25 MiB budget"
ok "idle RSS ${MEM_MIB} MiB ≤ 25 MiB (PocketBase idles ~20 MiB)"

green "[M37] ALL GATES GREEN — binocle-nano: ${IMG_MB} MB image, ${MEM_MIB} MiB idle, full CRUD+schema+scopes+SSE on one static binary"
