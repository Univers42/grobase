#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m50-rotate-revoke.sh                               :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M50 — revoked key dies on the NEXT request, not after a cache TTL (B3).
#
# The data plane caches verified identities (verify_cache, TTL ~30s). Before
# B3, revoking a key at tenant-control left that cache untouched: the revoked
# key kept authenticating on the data plane until the entry aged out. B3 wires
# RevokeKey → POST /v1/admin/evict-verify (and rotate() now clears the same
# cache). This gate proves the live behavior:
#
#   1. mint tenant + key, run one query through Kong (warms verify_cache);
#   2. revoke the key at tenant-control;
#   3. IMMEDIATELY query again — must be 401/403 on the very next request.
#      No sleep: a pass here is impossible if the eviction hook is missing
#      (the cache would serve the old identity for up to its TTL).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M50] $*"; }
pass()  { green "[M50] PASS: $*"; }
fail()  { red "[M50] FAIL: $*"; exit 1; }

# shellcheck source=scripts/lib/lib-live-tenant.sh
source "${SCRIPT_DIR}/../lib/lib-live-tenant.sh"

docker inspect mini-baas-data-plane-router-rust >/dev/null 2>&1 \
  || { printf '\033[1;33m[M50] SKIP: data plane not up\033[0m\n'; exit 0; }

SLUG="m50revoke$(date +%s)"
step "provisioning probe tenant '${SLUG}' + key + scratch mount"
live_tenant_provision "${SLUG}" || fail "tenant provisioning failed"
trap live_tenant_cleanup EXIT
KONG="${LIVE_KONG_URL}"; DB="${LIVE_TENANT_DB_ID}"; KEY="${LIVE_TENANT_API_KEY}"

q() { # one /data/v1 query with the probe key → echoes the HTTP code
  curl -s -o /tmp/m50.json -w '%{http_code}' -X POST "${KONG}/data/v1/query" \
    -H "apikey: ${LIVE_ANON_APIKEY}" -H "X-Baas-Api-Key: ${KEY}" \
    -H 'Content-Type: application/json' \
    -d "{\"db_id\":\"${DB}\",\"operation\":{\"op\":\"list\",\"resource\":\"m50_probe\",\"limit\":1}}"
}

# ── 1) warm the data plane's verify_cache with a real authenticated request ──
step "warming verify_cache (one authenticated query)"
CODE="$(q)"
# 200 (table missing may still 4xx on some engines, but AUTH must have passed:
# anything but 401/403 proves the key authenticated and is now cached).
[[ "${CODE}" != "401" && "${CODE}" != "403" ]] \
  || fail "warm-up query rejected (${CODE}) — key never authenticated: $(head -c 200 /tmp/m50.json)"
pass "key authenticated (HTTP ${CODE}) — identity now cached on the data plane"

# ── 2) revoke the key at tenant-control ──────────────────────────────────────
step "revoking key ${LIVE_TENANT_KEY_ID}"
# svc_auth signs PER REQUEST (method+path+body) under SERVICE_TOKEN_MODE=hmac —
# it must be re-invoked for THIS call, not reused from provisioning.
svc_auth DELETE "/v1/tenants/${SLUG}/keys/${LIVE_TENANT_KEY_ID}" ""
CODE=$(curl -s -o /tmp/m50-revoke.json -w '%{http_code}' -X DELETE \
  "${LIVE_TENANT_CONTROL_URL}/v1/tenants/${SLUG}/keys/${LIVE_TENANT_KEY_ID}" \
  "${SVC_AUTH[@]}")
[[ "${CODE}" == "200" ]] || fail "revoke returned ${CODE}: $(head -c 200 /tmp/m50-revoke.json)"
pass "key revoked at tenant-control"

# ── 3) the very next request must die — no sleep, no retry ───────────────────
step "immediate re-query (must be rejected on the FIRST post-revoke request)"
CODE="$(q)"
[[ "${CODE}" == "401" || "${CODE}" == "403" ]] \
  || fail "revoked key still authenticated (HTTP ${CODE}) — verify_cache not evicted: $(head -c 200 /tmp/m50.json)"
pass "revoked key rejected immediately (HTTP ${CODE})"

green "[M50] ALL GATES GREEN — credential events evict the verify cache; a revoked key dies on its next request"
