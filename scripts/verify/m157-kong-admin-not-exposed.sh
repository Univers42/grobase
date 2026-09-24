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

# (2) the proxy still works (we didn't break the gateway). /rest/v1/ is PostgREST's
# root, present on every stack — not a table some vendor app has to seed first.
code=$(curl -s -o /dev/null -w '%{http_code}' "$GW/rest/v1/" -H "apikey: $ANON")
[ "$code" = "200" ] || fail "proxy not serving on $GW (HTTP $code)"
ok "proxy still serves on $GW (HTTP 200)"

# (3) durable: the merged compose config does not publish the admin port. A render
# that fails is a FAIL — it used to be swallowed, and an empty render 'passed'.
command -v jq >/dev/null || fail "jq is required"
render="$(cd "$ROOT" && docker compose config --format json 2>&1)" ||
  fail "compose config does not render — the port check cannot run: $(printf '%s' "$render" | head -c 300)"
pub="$(printf '%s' "$render" | jq -r '[.services.kong.ports[]? | select((.target | tostring) == "8001") | "\(.host_ip // "0.0.0.0"):\(.published)"] | join(" ")')"
[ -z "$pub" ] || fail "compose config still publishes the admin port: $pub"
ok "compose config does not publish the Kong admin port"

printf '\n\033[1;32mm157 PASS — Kong Admin API is internal-only; the key/secret dump is not host-reachable\033[0m\n'
