#!/usr/bin/env bash
# ============================================================
# m159 — Storage bucket admin is scoped (no cross-tenant disclosure)
#
# Before: GET /storage/v1/bucket returned EVERY tenant's bucket names to any
# authenticated caller (cross-tenant metadata disclosure), and any visitor could
# POST /storage/v1/bucket/:name (namespace-pollution DoS). Fix (flag-gated,
# STORAGE_BUCKET_SCOPE_ENABLED, default OFF = byte-parity): when ON, listing all
# buckets / creating a bucket needs a privileged role (service_role/admin) — an
# ordinary caller gets an EMPTY list (still 200) and a 403 on create.
#
# This gate runs the ON behavior: a visitor sees 0 buckets and cannot create;
# a service_role principal (JWT role=service_role + a sub) still can.
# Requires the storage profile up with STORAGE_BUCKET_SCOPE_ENABLED=1.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ANON="$(grep -E '^ANON_KEY=' "$ROOT/.env" | cut -d= -f2)"
JWT_SECRET="$(grep -E '^JWT_SECRET=' "$ROOT/.env" | cut -d= -f2)"
KPORT="$(docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://' || echo 8000)"
GW="http://localhost:${KPORT:-8000}"
PASS="${ZOO_PASSWORD:-zoo-admin-2024}"
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

printf '\n\033[1mm159 — storage bucket admin is scoped\033[0m  (%s)\n' "$GW"

# the flag must be ON for this gate (it asserts the hardened behavior)
FLAG="$(docker exec mini-baas-storage-router sh -c 'echo $STORAGE_BUCKET_SCOPE_ENABLED' 2>/dev/null || true)"
echo "$FLAG" | grep -qiE '^(1|true)$' \
  || fail "STORAGE_BUCKET_SCOPE_ENABLED is not ON for mini-baas-storage-router (got '$FLAG') — recreate it with the flag"
ok "STORAGE_BUCKET_SCOPE_ENABLED is ON"

bcount() { # bearer -> bucket count (or 'ERR:<body>')
  curl -s "$GW/storage/v1/bucket" -H "apikey: $ANON" -H "Authorization: Bearer $1" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print(len(d['buckets']) if isinstance(d,dict) and 'buckets' in d else 'ERR:'+json.dumps(d)[:120])"
}
mint_service_jwt() { # echoes a role=service_role JWT with a sub, signed HS256/JWT_SECRET
  JWT_SECRET="$JWT_SECRET" python3 - <<'PY'
import os,hmac,hashlib,base64,json
b=lambda x:base64.urlsafe_b64encode(x).rstrip(b'=').decode()
sec=os.environ['JWT_SECRET'].encode()
h=b(json.dumps({"alg":"HS256","typ":"JWT"},separators=(',',':')).encode())
p=b(json.dumps({"role":"service_role","iss":"supabase","sub":"m159-storage-admin","exp":2000000000},separators=(',',':')).encode())
print(f"{h}.{p}."+b(hmac.new(sec,f"{h}.{p}".encode(),hashlib.sha256).digest()))
PY
}

# ── non-privileged visitor: empty list + denied create ──
VIS=$(curl -s -X POST "$GW/auth/v1/token?grant_type=password" -H "apikey: $ANON" \
  -H 'Content-Type: application/json' -d "{\"email\":\"sec-alice@savanna-zoo.com\",\"password\":\"Visitor#2026\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
[ -n "$VIS" ] || fail "visitor login failed"
V_LIST=$(bcount "$VIS")
[ "$V_LIST" = "0" ] || fail "visitor should see 0 buckets (scoped), got $V_LIST — disclosure not closed"
ok "visitor GET /storage/v1/bucket → 0 buckets (no cross-tenant names)"
V_CREATE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$GW/storage/v1/bucket/m159-visitor-$(date +%s 2>/dev/null || echo x)" \
  -H "apikey: $ANON" -H "Authorization: Bearer $VIS")
[ "$V_CREATE" = "403" ] || fail "visitor bucket-create should be 403, got $V_CREATE"
ok "visitor POST /storage/v1/bucket/:name → 403 (no namespace pollution)"

# ── privileged service_role principal: full list + create ──
[ -n "$JWT_SECRET" ] || fail "JWT_SECRET not found in .env"
SADMIN="$(mint_service_jwt)"
S_LIST=$(bcount "$SADMIN")
case "$S_LIST" in ''|*ERR*|0) fail "service_role should list buckets, got '$S_LIST'";; esac
ok "service_role principal → lists $S_LIST buckets (admin still works)"
BK="m159-svc-$(date +%s 2>/dev/null || echo x)"
S_CREATE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$GW/storage/v1/bucket/$BK" -H "apikey: $ANON" -H "Authorization: Bearer $SADMIN")
[ "$S_CREATE" = "201" ] || [ "$S_CREATE" = "200" ] || fail "service_role bucket-create should succeed, got $S_CREATE"
ok "service_role POST /storage/v1/bucket/:name → $S_CREATE (provisioning works)"
docker exec mini-baas-minio sh -c "mc alias set lo http://localhost:9000 \${MINIO_ROOT_USER:-minioadmin} \${MINIO_ROOT_PASSWORD:-minioadmin} >/dev/null 2>&1; mc rb --force lo/$BK >/dev/null 2>&1" || true

printf '\n\033[1;32mm159 PASS — bucket list/create is privileged-only; ordinary callers cannot enumerate or pollute\033[0m\n'
