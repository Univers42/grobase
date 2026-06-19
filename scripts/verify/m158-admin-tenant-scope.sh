#!/usr/bin/env bash
# ============================================================
# m158 — /admin/v1/databases cannot be enumerated with the anon key
#
# Before: the public anon key (baked into every frontend) plus a forged
# `X-Baas-Tenant-Id` header listed ANY tenant's DB mounts via Kong's
# adapter-registry route (it accepted the anon consumer and trusted the
# client-supplied tenant). Fix: an ACL plugin on the `admin-adapters` route
# restricts it to the `baas-admin` group, which only the service_role key is in
# (infra/docker/services/kong/conf/kong.yml). The anon key → 403; the service
# key (used by every scripts/seed/*-tenant.sh) still works.
#
# This gate asserts the asymmetry: anon → 403, service → 200.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ANON="$(grep -E '^ANON_KEY=' "$ROOT/.env" | cut -d= -f2)"
KPORT="$(docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://' || echo 8000)"
GW="http://localhost:${KPORT:-8000}"
SVC="$(docker exec mini-baas-kong sh -c 'echo $KONG_SERVICE_API_KEY' 2>/dev/null || true)"
[ -n "$SVC" ] || { [ -f "$ROOT/.savanna-tenant.env" ] && . "$ROOT/.savanna-tenant.env" && SVC="$SAVANNA_SERVICE_APIKEY"; }
FORGE="00000000-0000-4000-8000-000000000002"   # an existing platform tenant uuid
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

printf '\n\033[1mm158 — adapter-registry admin route is service-role only\033[0m  (%s)\n' "$GW"
[ -n "$SVC" ] || fail "could not resolve the service key (KONG_SERVICE_API_KEY)"

# (1) anon key + forged tenant header → must be 403 (ACL denied), NOT a mount list
C_ANON=$(curl -s -o /tmp/m158-anon.json -w '%{http_code}' "$GW/admin/v1/databases" \
  -H "apikey: $ANON" -H "X-Baas-Tenant-Id: $FORGE")
[ "$C_ANON" = "403" ] || fail "anon+forged X-Baas-Tenant-Id should be 403 (ACL), got $C_ANON — enumeration still open"
# defensive: even if some status, the body must NOT be a JSON array of mounts
if python3 -c "import sys,json;d=json.load(open('/tmp/m158-anon.json'));sys.exit(0 if isinstance(d,list) and d else 1)" 2>/dev/null; then
  fail "anon listed $(python3 -c 'import json;print(len(json.load(open("/tmp/m158-anon.json"))))') mounts — enumeration NOT closed"
fi
ok "anon key + forged X-Baas-Tenant-Id → 403, no mount list (ACL closed the enumeration)"

# (2) the service key still lists (provisioning / seed scripts must keep working)
C_SVC=$(curl -s -o /tmp/m158-svc.json -w '%{http_code}' "$GW/admin/v1/databases" \
  -H "apikey: $SVC" -H "X-Tenant-Id: savanna")
[ "$C_SVC" = "200" ] || fail "service key should still list mounts (200), got $C_SVC — provisioning would break"
ok "service_role key → 200 (seed/provisioning unaffected)"

printf '\n\033[1;32mm158 PASS — only the service_role key reaches the adapter-registry admin surface\033[0m\n'
