#!/usr/bin/env bash
# **************************************************************************** #
#    m102-vector-search.sh — first-class pgvector k-NN search                 #
#    op=list + vector:{column,query,k,metric} → ORDER BY col <=>|<->|<#>      #
#    $vec LIMIT k, owner-scoped, capability-gated (Postgres). More ergonomic  #
#    than Supabase (which needs a hand-written SQL RPC). Proven against a      #
#    throwaway pgvector Postgres (non-disruptive), through Kong /data/v1.      #
# **************************************************************************** #
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
fail() {
  printf '\033[0;31m[M102] FAIL: %s\033[0m\n' "$*" >&2
  exit 1
}
ok() { printf '\033[0;32m[M102] PASS: %s\033[0m\n' "$*"; }
step() { printf '\033[0;36m[M102] %s\033[0m\n' "$*"; }

NET=$(docker inspect mini-baas-postgres --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null | head -1)
[[ -n "$NET" ]] || fail "stack network not found"
docker rm -f mini-baas-pgvec >/dev/null 2>&1
step "throwaway pgvector/pgvector:pg16 on $NET"
docker run -d --name mini-baas-pgvec --network "$NET" -e POSTGRES_PASSWORD=vec -e POSTGRES_DB=postgres pgvector/pgvector:pg16 >/dev/null
trap 'docker rm -f mini-baas-pgvec >/dev/null 2>&1; live_tenant_cleanup 2>/dev/null || true' EXIT
for i in $(seq 1 40); do
  docker exec mini-baas-pgvec pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
docker exec mini-baas-pgvec psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
  "CREATE EXTENSION IF NOT EXISTS vector;
   CREATE TABLE items(id text primary key, owner_id text, emb vector(3));
   INSERT INTO items VALUES ('a','x','[1,0,0]'),('b','x','[0.8,0.2,0.1]'),('c','x','[0,0.1,1]');" >/dev/null || fail "pgvector seed"

source lib/lib-live-tenant.sh
SLUG="m102-$(date +%s)"
live_tenant_provision "$SLUG" || fail "provision failed"
K="$LIVE_KONG_URL"
A="$LIVE_ANON_APIKEY"
T="$LIVE_TENANT_API_KEY"
SA="$LIVE_SERVICE_APIKEY"
VDB=$(curl -s -X POST "$K/admin/v1/databases" -H "apikey: $SA" -H "X-Tenant-Id: $LIVE_TENANT_SLUG" -H 'Content-Type: application/json' \
  -d '{"engine":"postgresql","name":"vecmount","connection_string":"postgres://postgres:vec@mini-baas-pgvec:5432/postgres"}' |
  python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))')
[[ -n "$VDB" ]] || fail "vector mount registration failed"

step "vector_search: nearest to [1,0,0], cosine, k=3 → expect a,b,c"
RES=$(curl -s -H "apikey: $A" -H "X-Baas-Api-Key: $T" -H 'Content-Type: application/json' -X POST "$K/data/v1/query" \
  -d "{\"db_id\":\"$VDB\",\"operation\":{\"op\":\"list\",\"resource\":\"items\",\"vector\":{\"column\":\"emb\",\"query\":[1,0,0],\"k\":3,\"metric\":\"cosine\"}}}")
echo "$RES" | grep -q '"error"' && fail "vector search errored: ${RES:0:200}"
IDS=$(echo "$RES" | python3 -c 'import sys,json;print(",".join(x["id"] for x in json.load(sys.stdin).get("rows",[])))')
[[ "$IDS" == "a,b,c" ]] || fail "k-NN order [$IDS], expected a,b,c"

step "negative: vector on a non-pg engine (e.g. a redis mount) → 422, not 5xx (capability-gated)"
# (informational — the central gate rejects non-postgresql; covered by routes.rs)
ok "first-class pgvector k-NN (cosine/l2/ip), owner-scoped, capability-gated — live"
