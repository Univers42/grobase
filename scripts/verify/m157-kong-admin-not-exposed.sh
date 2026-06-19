#!/usr/bin/env bash
# ============================================================
# m157 — Kong Admin API is not reachable from the host
#
# In db-less mode the Kong Admin API (:8001) serves the declarative config,
# including `GET /key-auths` → the cleartext anon + service_role keys and
# `GET /jwts` → the JWT secret. Publishing it to a host port (it was on
# 127.0.0.1:8003) lets any host-local process (or a host-bound SSRF) dump every
# key. Fix: the Admin API is no longer published to the host
# (orchestrators/compose/base/gateway.yml) — it stays on the internal network
# for Prometheus only. The proxy (:8000) is unaffected.
#
# This gate asserts: (1) the live Kong container does NOT host-publish 8001,
# (2) the proxy still serves, (3) the compose config no longer publishes it.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ANON="$(grep -E '^ANON_KEY=' "$ROOT/.env" | cut -d= -f2)"
KPORT="$(docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://' || echo 8000)"
GW="http://localhost:${KPORT:-8000}"
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

printf '\n\033[1mm157 — Kong Admin API not host-exposed\033[0m\n'

# (1) live container: admin port 8001 must NOT be published to the host
ADMIN_PUB="$(docker port mini-baas-kong 8001/tcp 2>/dev/null || true)"
[ -z "$ADMIN_PUB" ] || fail "Kong Admin API is published to the host ($ADMIN_PUB) — keys are dumpable via /key-auths"
ok "admin API :8001 is not published to the host"

# belt-and-suspenders: if some host port DID map, prove /key-auths is unreachable
if [ -n "$ADMIN_PUB" ]; then
  P="${ADMIN_PUB##*:}"
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://localhost:$P/key-auths" || echo 000)
  [ "$code" = "000" ] || fail "/key-auths reachable on :$P (HTTP $code)"
fi

# (2) the proxy still works (we didn't break the gateway)
code=$(curl -s -o /dev/null -w '%{http_code}' "$GW/rest/v1/animals?limit=1" -H "apikey: $ANON")
[ "$code" = "200" ] || fail "proxy not serving on $GW (HTTP $code)"
ok "proxy still serves on $GW (HTTP 200)"

# (3) durable: the merged compose config no longer publishes the admin port
if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
  pub=$(cd "$ROOT" && docker compose config 2>/dev/null \
        | awk '/container_name: mini-baas-kong/{f=1} f&&/published/{print} /^  [a-z]/{if(f&&!/kong/)f=0}' \
        | grep -E '"8001"|target: 8001' || true)
  [ -z "$pub" ] || fail "compose config still publishes the admin port: $pub"
  ok "compose config does not publish the Kong admin port"
fi

printf '\n\033[1;32mm157 PASS — Kong Admin API is internal-only; the key/secret dump is not host-reachable\033[0m\n'
