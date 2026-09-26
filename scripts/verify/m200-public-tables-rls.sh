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
#    (4) live (N-3): a NEW table with no grants — what the DDL API creates on a  #
#        mount that points at this database — is not readable with the anon    #
#        key; the default privilege that made it readable is gone               #
#    (5) invariant (N-36): tables whose write policy keys on                  #
#        current_tenant_id() — a GoTrue user's own uuid — (pinned floor +      #
#        pg_depend rule), vault42_* and org_usage_rollup give anon and         #
#        authenticated no privilege; every other writable relation is on the   #
#        REST-writable allowlist; no TRUNCATE; no owner-rights view reachable  #
#    (6) live (N-36): a user signed up through Kong cannot forge a tenant via  #
#        /rest/v1 or /graphql/v1, touch or read one its RLS identity matches,  #
#        PATCH sso_connections, or read another org's usage rollup             #
#    (7) live (N-36): scripts/security/detect-forged-tenants.sql finds nothing #
#  Needs the stack up (postgres + postgrest + kong + gotrue) and .env.         #
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

step "0/7 preconditions — postgres + kong up, anon key in .env"
[ -f "${ROOT}/.env" ] || fail ".env missing (make env)"
docker inspect -f '{{.State.Running}}' mini-baas-postgres 2>/dev/null | grep -qx true || fail "mini-baas-postgres is not running (make up)"
KP="$(docker port mini-baas-kong 8000/tcp 2>/dev/null | head -n1 | sed 's/.*://')"
[ -n "${KP}" ] || fail "mini-baas-kong publishes no :8000 (make up)"
AK="$(grep -m1 '^KONG_PUBLIC_API_KEY=' "${ROOT}/.env" | cut -d= -f2-)"
[ -n "${AK}" ] || fail "KONG_PUBLIC_API_KEY missing from .env"
ok "stack up (kong :${KP})"

step "1/7 invariant — anon/authenticated privileges only on RLS-enabled tables"
exposed="$(psql_q "SELECT string_agg(n.nspname || '.' || c.relname, ' ' ORDER BY 1)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p') AND n.nspname = 'public' AND NOT c.relrowsecurity
    AND EXISTS (SELECT 1 FROM unnest(ARRAY['anon', 'authenticated']) r,
                unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
                WHERE has_table_privilege(r, c.oid, p))")" || fail "invariant query failed"
[ -z "${exposed}" ] || fail "reachable by anon/authenticated WITHOUT row-level security: ${exposed}"
ok "no public table grants anon/authenticated access without RLS"

step "2/7 live — the anon key through Kong cannot read or write schema_registry"
base="http://localhost:${KP}/rest/v1/schema_registry"
get="$(curl -s -o /dev/null -w '%{http_code}' "${base}?limit=1" -H "apikey: ${AK}")"
post="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${base}" -H "apikey: ${AK}" -H 'Content-Type: application/json' \
  -d '{"database_id":"00000000-0000-0000-0000-000000000200","name":"m200-probe","engine":"postgresql","columns":[],"created_by":"00000000-0000-0000-0000-000000000200"}')"
psql_q "DELETE FROM public.schema_registry WHERE name = 'm200-probe'" >/dev/null 2>&1 || true
case "${get}" in 2*) fail "anon GET schema_registry answered ${get} — the cross-tenant table catalog is readable" ;; esac
case "${post}" in 2*) fail "anon POST schema_registry answered ${post} — the catalog is writable with the public key" ;; esac
ok "anon GET → ${get}, POST → ${post} (refused)"

step "3/7 live — PostgREST logs in as a role RLS applies to (C-7)"
role="$(psql_q "SELECT rolsuper || ',' || rolbypassrls FROM pg_roles WHERE rolname = 'authenticator'")"
[ "${role}" = "false,false" ] || fail "authenticator is superuser/bypassrls (${role:-missing}) — RLS would not apply to REST calls"
users="$(psql_q "SELECT string_agg(DISTINCT usename, ',') FROM pg_stat_activity WHERE application_name ILIKE '%postgrest%'")"
[ -n "${users}" ] || fail "no PostgREST session in pg_stat_activity — cannot tell which role it uses (is postgrest up?)"
[ "${users}" = authenticator ] || fail "PostgREST is connected as '${users}', not only authenticator"
ok "PostgREST sessions: ${users} (not superuser, not bypassrls)"

step "4/7 live — a new table nothing granted is not reachable with the anon key (N-3)"
psql_q "DROP TABLE IF EXISTS public.m200_probe; CREATE TABLE public.m200_probe (id int PRIMARY KEY, secret text); INSERT INTO public.m200_probe VALUES (1, 'm200-secret')" >/dev/null || fail "could not create the probe table"
psql_q "NOTIFY pgrst, 'reload schema'" >/dev/null
sleep 2
probe="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${KP}/rest/v1/m200_probe?select=secret" -H "apikey: ${AK}")"
psql_q "DROP TABLE IF EXISTS public.m200_probe" >/dev/null
case "${probe}" in 2*) fail "anon GET on a fresh, never-granted table answered ${probe} — the default privilege still hands new tables to the public key" ;; esac
ok "fresh ungranted table: anon GET → ${probe} (refused)"

step "5/7 invariant — control tables hold no anon/authenticated privilege; REST-writable tables are allowlisted (N-36)"
# Policies whose write side calls current_tenant_id() — a GoTrue user's own uuid — found
# through pg_depend (as migration 090 does), plus inheritance children.
KEYED_SQL="WITH RECURSIVE keyed AS (
    SELECT DISTINCT pol.polrelid AS rel FROM pg_policy pol
      JOIN pg_depend d ON d.classid = 'pg_policy'::regclass AND d.objid = pol.oid AND d.refclassid = 'pg_proc'::regclass
      JOIN pg_proc f ON f.oid = d.refobjid AND f.proname = 'current_tenant_id'
      JOIN pg_namespace fn ON fn.oid = f.pronamespace AND fn.nspname IN ('auth', 'public')
     WHERE pol.polcmd IN ('*', 'a', 'w', 'd')
    UNION SELECT i.inhrelid FROM pg_inherits i JOIN keyed k ON i.inhparent = k.rel)
  SELECT c.relname FROM keyed k JOIN pg_class c ON c.oid = k.rel AND c.relnamespace = 'public'::regnamespace"
# Today's tenant-keyed tables, pinned: a policy rewritten to a spelling the rule cannot see
# drops a table out of the rule — and out of this floor, which fails.
FLOOR="apps billing_reported erasure_receipts fdw_external_resources function_deliveries function_schedules
  function_secrets function_triggers principal_events projects push_subscriptions scim_tokens scim_users
  sso_connections tenant_api_keys tenant_audit_log tenant_backups tenant_billing tenant_branches tenant_budgets
  tenant_databases tenant_entitlements tenant_exports tenant_ip_allowlist tenant_safety tenant_telemetry_targets
  tenant_usage tenants webauthn_credentials webhook_deliveries webhook_subscriptions"
# The tables a browser may write through /rest/v1 (RLS keyed on the caller's own uid or an
# app role): 001/007/008/010 app tables, 002 mock_orders, 066 MovieVerse. A new entry here
# is a decision that end users write that table directly.
ALLOW="friendships likes list_items media_lists mock_orders moderation_actions movieverse_profiles reports
  resource_policies reviews roles storage_buckets storage_objects supported_languages translations
  user_media_status user_presence user_profiles user_roles"
sql_list() { printf "'%s'," $1 | sed 's/,$//'; }
PUB="(SELECT unnest(ARRAY['anon', 'authenticated']))"
ANY_PRIV="EXISTS (SELECT 1 FROM ${PUB} r(role) WHERE
    has_any_column_privilege(r.role, c.oid, 'SELECT') OR has_any_column_privilege(r.role, c.oid, 'INSERT')
    OR has_any_column_privilege(r.role, c.oid, 'UPDATE') OR has_any_column_privilege(r.role, c.oid, 'REFERENCES')
    OR has_table_privilege(r.role, c.oid, 'DELETE') OR has_table_privilege(r.role, c.oid, 'TRUNCATE')
    OR has_table_privilege(r.role, c.oid, 'TRIGGER'))"
WRITE_PRIV="EXISTS (SELECT 1 FROM ${PUB} r(role) WHERE
    has_any_column_privilege(r.role, c.oid, 'INSERT') OR has_any_column_privilege(r.role, c.oid, 'UPDATE')
    OR has_table_privilege(r.role, c.oid, 'DELETE') OR has_table_privilege(r.role, c.oid, 'TRUNCATE'))"
EXPOSED="c.relnamespace IN ('public'::regnamespace, 'graphql_public'::regnamespace) AND c.relkind IN ('r', 'p', 'v', 'm', 'f')"
keyed="$(psql_q "SELECT string_agg(relname, ' ' ORDER BY relname) FROM (${KEYED_SQL}) s")" || fail "tenant-keyed policy query failed"
for t in ${FLOOR}; do
  case " ${keyed} " in *" ${t} "*) ;; *) fail "${t} left the tenant-keyed set (policy no longer calls current_tenant_id()?) — re-check its REST exposure, then update FLOOR" ;; esac
done
held="$(psql_q "SELECT string_agg(c.relname, ' ' ORDER BY c.relname) FROM pg_class c
  WHERE c.relnamespace = 'public'::regnamespace AND ${ANY_PRIV} AND (c.relname IN (SELECT relname FROM (${KEYED_SQL}) s)
    OR c.relname IN ($(sql_list "${FLOOR} vault42_secrets vault42_audit vault42_grants org_usage_rollup")))")" ||
  fail "control-table privilege query failed"
[ -z "${held}" ] || fail "anon/authenticated hold a privilege on control tables (writable or readable over /rest/v1 and /graphql/v1): ${held}"
writable="$(psql_q "SELECT string_agg(c.relname, ' ' ORDER BY c.relname) FROM pg_class c
  WHERE ${EXPOSED} AND ${WRITE_PRIV} AND c.relname NOT IN ($(sql_list "${ALLOW}"))
    AND (c.relkind NOT IN ('r', 'p') OR NOT c.relrowsecurity
         OR EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = c.oid AND p.polcmd IN ('*', 'a', 'w', 'd')))")" ||
  fail "writable-relation query failed"
[ -z "${writable}" ] || fail "writable by anon/authenticated and not on the REST-writable allowlist: ${writable}"
ddl="$(psql_q "SELECT string_agg(c.relname, ' ' ORDER BY c.relname) FROM pg_class c WHERE ${EXPOSED}
  AND EXISTS (SELECT 1 FROM ${PUB} r(role), unnest(ARRAY['TRUNCATE', 'REFERENCES', 'TRIGGER']) p
              WHERE has_table_privilege(r.role, c.oid, p))")" || fail "TRUNCATE/REFERENCES/TRIGGER query failed"
[ -z "${ddl}" ] || fail "anon/authenticated hold TRUNCATE/REFERENCES/TRIGGER (RLS never governs TRUNCATE): ${ddl}"
views="$(psql_q "SELECT string_agg(c.relname, ' ' ORDER BY c.relname) FROM pg_class c WHERE ${EXPOSED}
  AND c.relkind IN ('v', 'm') AND ${ANY_PRIV} AND NOT coalesce('security_invoker=true' = ANY (c.reloptions), false)")" ||
  fail "view query failed"
[ -z "${views}" ] || fail "views reachable by anon/authenticated that run as their owner (bypassing RLS): ${views}"
ok "$(wc -w <<<"${keyed}") tenant-keyed tables + vault42/org rollup: no privilege; every other writable relation allowlisted; no TRUNCATE; no owner-rights view"

step "6/7 live — a signed-up user reaches no control table through /rest/v1 or /graphql/v1 (N-36)"
email="m200-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')@example.test"
signup="$(curl -s "http://localhost:${KP}/auth/v1/signup" -H "apikey: ${AK}" -H 'Content-Type: application/json' \
  -d "{\"email\":\"${email}\",\"password\":\"$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')\"}")"
tok="$(jq -r '.access_token // empty' <<<"${signup}")"
uid="$(jq -r '.user.id // empty' <<<"${signup}")"
[ -n "${tok}" ] && [ -n "${uid}" ] || fail "GoTrue sign-up returned no session ($(jq -c '{code, msg, error_code}' <<<"${signup}" 2>/dev/null))"
BODY="$(mktemp)"
cleanup_user() {
  psql_q "DELETE FROM public.sso_connections WHERE tenant_id = '${uid}'; DELETE FROM public.tenant_usage WHERE idempotency_key = 'm200-${uid}';
    DELETE FROM public.tenants WHERE id::text = '${uid}' OR owner_user_id = '${uid}' OR slug = 'm200-org-${uid}';
    DELETE FROM public.orgs WHERE slug = 'm200-org-${uid}'; DELETE FROM auth.users WHERE id = '${uid}'" >/dev/null 2>&1 || true
  rm -f "${BODY}"
}
trap cleanup_user EXIT
rest() { curl -s -o "${BODY}" -w '%{http_code}' "$@" -H "apikey: ${AK}" -H "Authorization: Bearer ${tok}" -H 'Content-Type: application/json'; }
refused() { case "$1" in 401 | 403) grep -q '42501' "${BODY}" ;; *) return 1 ;; esac }
forge="$(rest -X POST "http://localhost:${KP}/rest/v1/tenants" \
  -d "{\"id\":\"${uid}\",\"slug\":\"${uid}\",\"name\":\"m200-forged\",\"plan\":\"enterprise\",\"owner_user_id\":\"${uid}\"}")"
[ "$(psql_q "SELECT count(*) FROM public.tenants WHERE id::text = '${uid}'")" = 0 ] ||
  fail "a signed-up user forged tenant ${uid} (plan enterprise) through /rest/v1/tenants (HTTP ${forge})"
refused "${forge}" || fail "POST /rest/v1/tenants answered ${forge} without a privilege refusal (42501): $(head -c 200 "${BODY}")"
gql="$(rest -X POST "http://localhost:${KP}/graphql/v1" -d "{\"query\":\"mutation { insertIntotenantsCollection(objects: [{id: \\\"${uid}\\\", slug: \\\"${uid}\\\", name: \\\"m200-gql\\\", plan: \\\"enterprise\\\"}]) { affectedCount } }\"}")"
[ "$(psql_q "SELECT count(*) FROM public.tenants WHERE id::text = '${uid}'")" = 0 ] ||
  fail "a signed-up user forged tenant ${uid} through /graphql/v1 (HTTP ${gql}: $(head -c 200 "${BODY}"))"
psql_q "INSERT INTO public.tenants (id, slug, name, owner_user_id) VALUES ('${uid}', '${uid}', 'm200-seeded', '${uid}');
  INSERT INTO public.sso_connections (tenant_id, issuer, client_id, authorize_url, token_url, redirect_uri)
    VALUES ('${uid}', 'https://m200.example.test', 'm200', 'https://m200.example.test/a', 'https://m200.example.test/t', 'https://m200.example.test/r')" >/dev/null ||
  fail "could not seed rows the user's RLS identity matches"
patch="$(rest -X PATCH "http://localhost:${KP}/rest/v1/tenants?id=eq.${uid}" -d '{"plan":"enterprise"}')"
refused "${patch}" || fail "PATCH tenants answered ${patch} without a privilege refusal"
sso="$(rest -X PATCH "http://localhost:${KP}/rest/v1/sso_connections?tenant_id=eq.${uid}" -d '{"issuer":"https://evil.example.test"}')"
refused "${sso}" || fail "PATCH sso_connections answered ${sso} without a privilege refusal"
del="$(rest -X DELETE "http://localhost:${KP}/rest/v1/tenants?id=eq.${uid}")"
refused "${del}" || fail "DELETE tenants answered ${del} without a privilege refusal"
state="$(psql_q "SELECT t.plan || ',' || s.issuer FROM public.tenants t JOIN public.sso_connections s ON s.tenant_id = t.id::text WHERE t.id::text = '${uid}'")"
case "${state}" in enterprise,* | *evil* | '') fail "the user changed or deleted control rows RLS matches (now '${state}')" ;; esac
read="$(rest "http://localhost:${KP}/rest/v1/tenants?select=slug&id=eq.${uid}")"
refused "${read}" || fail "GET tenants answered ${read} — tenant rows stay readable over REST: $(head -c 200 "${BODY}")"
psql_q "INSERT INTO public.orgs (name, slug) VALUES ('m200', 'm200-org-${uid}');
  INSERT INTO public.tenants (slug, name, org_id) SELECT 'm200-org-${uid}', 'm200', id FROM public.orgs WHERE slug = 'm200-org-${uid}';
  INSERT INTO public.tenant_usage (tenant_id, metric, window_start, qty, idempotency_key) VALUES ('m200-org-${uid}', 'm200', now(), 7, 'm200-${uid}')" >/dev/null ||
  fail "could not seed another org's usage"
rollup="$(rest "http://localhost:${KP}/rest/v1/org_usage_rollup?select=qty&metric=eq.m200")"
refused "${rollup}" || fail "GET org_usage_rollup answered ${rollup} — another org's usage is readable: $(head -c 200 "${BODY}")"
ok "user token: POST/PATCH/DELETE/GET tenants → ${forge}/${patch}/${del}/${read}, PATCH sso_connections → ${sso}, org_usage_rollup → ${rollup} (all 42501); GraphQL insert → no row"

cleanup_user
trap - EXIT

step "7/7 live — no tenant or control row forged before 090 remains (scripts/security/detect-forged-tenants.sql)"
forged="$(docker exec -i mini-baas-postgres psql -U postgres -d postgres -q <"${ROOT}/scripts/security/detect-forged-tenants.sql" 2>&1)" ||
  fail "the forgery detector failed: ${forged}"
grep -q 'forged rows: 0$' <<<"${forged}" || fail "forged rows found — $(tr '\n' ' ' <<<"${forged}")"
ok "forged rows: 0"
printf '\033[0;32m[M200] PASS — no RLS-less public table is reachable with the public API key; PostgREST runs as authenticator; new tables are not reachable by default; control tables are unreachable over REST and GraphQL and hold no forged rows\033[0m\n'
