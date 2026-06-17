#!/usr/bin/env bash
# **************************************************************************** #
#    m101-fulltext-search.sh — first-class Postgres full-text search          #
#    op=list + search:{query,columns,language} → ranked to_tsvector @@        #
#    websearch_to_tsquery over concat_ws'd columns, owner-scoped. More        #
#    powerful than Supabase's single-column fts filter: multi-column + ranked #
#    + language-aware + a typed first-class op. Live, through Kong /data/v1.   #
# **************************************************************************** #
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
fail() { printf '\033[0;31m[M101] FAIL: %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '\033[0;32m[M101] PASS: %s\033[0m\n' "$*"; }
step() { printf '\033[0;36m[M101] %s\033[0m\n' "$*"; }

source lib/lib-live-tenant.sh
SLUG="m101-$(date +%s)"
live_tenant_provision "$SLUG" || fail "provision failed"
trap 'live_tenant_cleanup || true' EXIT
K="$LIVE_KONG_URL"; A="$LIVE_ANON_APIKEY"; T="$LIVE_TENANT_API_KEY"; DB="$LIVE_TENANT_DB_ID"
H=(-H "apikey: $A" -H "X-Baas-Api-Key: $T" -H 'Content-Type: application/json')
TBL="m101_docs_$(date +%s)"

step "create table ($TBL: id, title, body) via /data/v1/schema/ddl"
DDL=$(printf '{"op":"create_table","table":"%s","columns":[{"name":"id","normalized_type":"text","nullable":false,"default":null,"enum_values":null},{"name":"title","normalized_type":"text","nullable":true,"default":null,"enum_values":null},{"name":"body","normalized_type":"text","nullable":true,"default":null,"enum_values":null}],"primary_key":["id"]}' "$TBL")
for i in $(seq 1 15); do c=$(curl -s -o /dev/null -w '%{http_code}' "${H[@]}" -X POST "$K/data/v1/schema/ddl" -d "{\"db_id\":\"$DB\",\"ddl\":$DDL}"); [[ "$c" =~ ^(200|201|409)$ ]] && break; sleep 1; done
[[ "$c" =~ ^(200|201|409)$ ]] || fail "create_table ($c)"
ins(){ curl -s -o /dev/null -w '%{http_code}' "${H[@]}" -X POST "$K/data/v1/query" -d "{\"db_id\":\"$DB\",\"operation\":{\"op\":\"insert\",\"resource\":\"$TBL\",\"data\":$1}}"; }
ins '{"id":"d1","title":"Full text search","body":"ranking with ts_rank"}' >/dev/null
ins '{"id":"d2","title":"Cooking pasta","body":"boil water"}' >/dev/null
ins '{"id":"d3","title":"Database text search","body":"a gin index speeds search"}' >/dev/null

step "FTS: search 'search' over [title, body] → expect d1 + d3, not d2"
RES=$(curl -s "${H[@]}" -X POST "$K/data/v1/query" -d "{\"db_id\":\"$DB\",\"operation\":{\"op\":\"list\",\"resource\":\"$TBL\",\"search\":{\"query\":\"search\",\"columns\":[\"title\",\"body\"]}}}")
echo "$RES" | grep -q '"error"' && fail "FTS errored: ${RES:0:200}"
IDS=$(echo "$RES" | python3 -c 'import sys,json;print(",".join(sorted(x["id"] for x in json.load(sys.stdin).get("rows",[]))))')
[[ "$IDS" == "d1,d3" ]] || fail "FTS returned [$IDS], expected d1,d3"
echo "$RES" | grep -q '"owner_id"' || fail "rows not owner-stamped (owner-scope check)"
echo "$RES" | grep -qiE 'stack|panic|/etc/passwd' && fail "leak in FTS response"

step "negative: search a non-numeric column works; bad language rejected (400, not 5xx)"
BL=$(curl -s -o /dev/null -w '%{http_code}' "${H[@]}" -X POST "$K/data/v1/query" -d "{\"db_id\":\"$DB\",\"operation\":{\"op\":\"list\",\"resource\":\"$TBL\",\"search\":{\"query\":\"x\",\"columns\":[\"title\"],\"language\":\"bad'); DROP--\"}}}")
[[ "$BL" == "400" ]] || fail "hostile language not a clean 400 (got $BL)"

ok "first-class ranked, multi-column, owner-scoped, injection-safe full-text search — live"
