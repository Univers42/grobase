#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m200-public-tables-rls.sh — the public API key cannot reach a table that    #
#  has no row-level security.                                                  #
#                                                                              #
#  001_initial_schema and db-bootstrap grant anon + authenticated SELECT,      #
#  INSERT, UPDATE, DELETE on EVERY table in `public` (and on future ones by    #
#  default privilege), leaving RLS to scope rows. public.schema_registry — the #
#  cross-tenant table catalog — had no RLS, so the anon key read, inserted and #
#  deleted it through PostgREST.                                               #
#                                                                              #
#    (1) invariant: every table in `public` on which anon or authenticated     #
#        holds a privilege has RLS enabled (catches the next such table too)   #
#    (2) live: anon GET/POST /rest/v1/schema_registry through Kong is refused  #
#    (3) live (C-7): PostgREST's sessions are all `authenticator`, which is    #
#        neither superuser nor BYPASSRLS — so RLS applies to every REST call   #
#  Needs the stack up (postgres + postgrest + kong) and .env.                  #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M200] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M200] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}
psql_q() { docker exec -i mini-baas-postgres psql -U postgres -d postgres -Atq -v ON_ERROR_STOP=1 -c "$1"; }

step "0/3 preconditions — postgres + kong up, anon key in .env"
[ -f "${ROOT}/.env" ] || fail ".env missing (make env)"
docker inspect -f '{{.State.Running}}' mini-baas-postgres 2>/dev/null | grep -qx true || fail "mini-baas-postgres is not running (make up)"
KP="$(docker port mini-baas-kong 8000/tcp 2>/dev/null | head -n1 | sed 's/.*://')"
[ -n "${KP}" ] || fail "mini-baas-kong publishes no :8000 (make up)"
AK="$(grep -m1 '^KONG_PUBLIC_API_KEY=' "${ROOT}/.env" | cut -d= -f2-)"
[ -n "${AK}" ] || fail "KONG_PUBLIC_API_KEY missing from .env"
ok "stack up (kong :${KP})"

step "1/3 invariant — anon/authenticated privileges only on RLS-enabled tables"
exposed="$(psql_q "SELECT string_agg(n.nspname || '.' || c.relname, ' ' ORDER BY 1)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p') AND n.nspname = 'public' AND NOT c.relrowsecurity
    AND EXISTS (SELECT 1 FROM unnest(ARRAY['anon', 'authenticated']) r,
                unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
                WHERE has_table_privilege(r, c.oid, p))")" || fail "invariant query failed"
[ -z "${exposed}" ] || fail "reachable by anon/authenticated WITHOUT row-level security: ${exposed}"
ok "no public table grants anon/authenticated access without RLS"

step "2/3 live — the anon key through Kong cannot read or write schema_registry"
base="http://localhost:${KP}/rest/v1/schema_registry"
get="$(curl -s -o /dev/null -w '%{http_code}' "${base}?limit=1" -H "apikey: ${AK}")"
post="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${base}" -H "apikey: ${AK}" -H 'Content-Type: application/json' \
  -d '{"database_id":"00000000-0000-0000-0000-000000000200","name":"m200-probe","engine":"postgresql","columns":[],"created_by":"00000000-0000-0000-0000-000000000200"}')"
psql_q "DELETE FROM public.schema_registry WHERE name = 'm200-probe'" >/dev/null 2>&1 || true
case "${get}" in 2*) fail "anon GET schema_registry answered ${get} — the cross-tenant table catalog is readable" ;; esac
case "${post}" in 2*) fail "anon POST schema_registry answered ${post} — the catalog is writable with the public key" ;; esac
ok "anon GET → ${get}, POST → ${post} (refused)"

step "3/3 live — PostgREST logs in as a role RLS applies to (C-7)"
role="$(psql_q "SELECT rolsuper || ',' || rolbypassrls FROM pg_roles WHERE rolname = 'authenticator'")"
[ "${role}" = "false,false" ] || fail "authenticator is superuser/bypassrls (${role:-missing}) — RLS would not apply to REST calls"
users="$(psql_q "SELECT string_agg(DISTINCT usename, ',') FROM pg_stat_activity WHERE application_name ILIKE '%postgrest%'")"
[ -n "${users}" ] || fail "no PostgREST session in pg_stat_activity — cannot tell which role it uses (is postgrest up?)"
[ "${users}" = authenticator ] || fail "PostgREST is connected as '${users}', not only authenticator"
ok "PostgREST sessions: ${users} (not superuser, not bypassrls)"
printf '\033[0;32m[M200] PASS — no RLS-less public table is reachable with the public API key; PostgREST runs as authenticator\033[0m\n'
