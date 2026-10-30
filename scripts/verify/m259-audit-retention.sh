#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m259-audit-retention.sh                            :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/30 14:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/10/30 14:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Gate (grobase#83, ADR 0022): audit_log retention and GDPR erasure, migration 095.
#
# STATIC  Kong routes no public path to the gdpr admin process route (C9).
# LIVE    a throwaway postgres (own network, random password, removed after):
#         roles as db-bootstrap.psql makes them, 013 + 016 + 090, then 095 twice
#         over a planted old overload; 095 on a database without audit_log does
#         nothing. As service_role (so RLS matching nothing shows as a 0):
#         erase_actor anonymises (C4) and purge refuses bad input and deletes
#         oldest first (C5); no audit_log_% function is executable by PUBLIC,
#         anon or authenticated (C7/C8).
# --self-test plants the four C8 mutants in a copy of 095 (no 30-day floor, no
#         p_batch NULL guard, no REVOKE from PUBLIC, no query-string strip) and
#         requires this gate to fail on each with the matching message.
#
# Needs docker and the postgres image; no stack, no VM.
# M259_MIGRATION=<file> applies another 095; M259_PG_IMAGE another image.
# Caveat: the Kong check reads kong.yml paths with a regex, so a route declared
# in another file, or in a shape other than `- ~/…` or `paths: [/a, /b]`, is not
# seen; the self-test greps this gate's own messages, so renaming one makes a
# mutant "survive" (noisy, safe).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIG="${ROOT}/scripts/migrations/postgresql"
M095="${M259_MIGRATION:-${MIG}/095_audit_log_retention.sql}"
KONG="${ROOT}/infra/docker/services/kong/conf/kong.yml"
PG_IMAGE="${M259_PG_IMAGE:-mirror.gcr.io/library/postgres:16-alpine}"
PG="m259-pg-$$"
NET="m259-net-$$"
WORK="$(mktemp -d)"
ACTOR_A="00000000-0000-4000-8000-00000000000a"
ACTOR_B="00000000-0000-4000-8000-00000000000b"

ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
step() { printf '\033[1m[M259] %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M259] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}
cleanup() {
  docker rm -fv "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

# Plants one bug in a copy of 095 and requires the gate to fail on it.
self_test() {
  local name from to expect planted out
  while IFS='~' read -r name from to expect; do
    planted="${WORK}/095-${name}.sql"
    sed "s#${from}#${to}#" "${M095}" >"${planted}"
    cmp -s "${M095}" "${planted}" && fail "self-test ${name}: the edit changed nothing"
    out="$(M259_MIGRATION="${planted}" bash "$0" 2>&1 </dev/null)" &&
      fail "self-test ${name}: gate PASSED with the bug planted"
    grep -q "${expect}" <<<"${out}" || fail "self-test ${name}: failed, not on '${expect}': $(tail -2 <<<"${out}")"
    ok "mutant ${name}: gate fails on '${expect}'"
  done <<'MUT'
no-floor~p_older_than < interval '30 days'~false~30-day floor
no-batch-null-guard~IF p_batch IS NULL THEN~IF false THEN~p_batch NULL
no-revoke-public~FROM PUBLIC, anon, authenticated~FROM anon, authenticated~PUBLIC can execute
no-query-strip~split_part(resource, '?', 1)~resource~query string
MUT
  printf '\033[1;32mm259 self-test PASS\033[0m — 4/4 mutants caught\n'
}

# Kong paths: every `- ~/regex` (anchored at the start) and every prefix in a
# `paths: [...]` list, one per line, regexes prefixed with "~".
kong_paths() {
  grep -oE '^\s+- ~/.*$' "${KONG}" | sed -E 's/^\s+- //'
  grep -oE 'paths: *\[[^]]*\]' "${KONG}" | sed -E 's/paths: *\[//; s/\]//' | tr ',' '\n' | tr -d ' '
}

kong_routes() {
  local p matched path
  for path in /gdpr/v1/deletion-requests/mine /gdpr/v1/deletion-requests/admin/1/process \
    /deletion-requests/admin/1/process; do
    matched=""
    while IFS= read -r p; do
      [ -n "${p}" ] || continue
      if [ "${p#\~}" != "${p}" ]; then
        grep -qP "^${p#\~}" <<<"${path}" && matched="${p}"
      else
        case "${path}" in "${p}" | "${p}"/*) matched="${p}" ;; esac
      fi
    done < <(kong_paths)
    printf '%s %s\n' "${path}" "${matched:-none}"
  done
}

static_kong() {
  step "static: Kong routes no public path to the gdpr admin process route (C9)"
  local out
  out="$(kong_routes)"
  grep -q '^/gdpr/v1/deletion-requests/mine ~/gdpr/v1/' <<<"${out}" ||
    fail "the gdpr-routes regex was not read (sanity: /mine must match it): ${out}"
  grep -q '^/gdpr/v1/deletion-requests/admin/1/process none$' <<<"${out}" ||
    fail "a Kong route matches the gdpr admin process path: ${out}"
  grep -q '^/deletion-requests/admin/1/process none$' <<<"${out}" ||
    fail "a Kong route matches the bare admin process path: ${out}"
  ok "/mine routed by gdpr-routes; /admin/{id}/process reaches no route"
}

psql_in() { docker exec -i -e PGOPTIONS='-c client_min_messages=warning' "${PG}" psql -U postgres -v ON_ERROR_STOP=1 -qtAX "$@"; }
sql() { psql_in -d "${DB:-postgres}" -c "$1"; }
as_role() { psql_in -d postgres -c "SET ROLE $1; $2" 2>&1 || true; }
apply() { sed '/^#/d' "$1" | psql_in -d "${2:-postgres}" -f - >/dev/null || fail "applying ${1##*/} failed"; }

start_pg() {
  docker network create --internal "${NET}" >/dev/null
  docker run -d --name "${PG}" --network "${NET}" \
    -e POSTGRES_PASSWORD="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" "${PG_IMAGE}" >/dev/null
  local i
  for i in $(seq 1 60); do
    docker exec "${PG}" pg_isready -U postgres -q 2>/dev/null && sql 'SELECT 1' >/dev/null 2>&1 && return 0
    sleep 1
  done
  fail "postgres did not become ready"
}

# Roles and grants as scripts/db/db-bootstrap.psql:32-43 makes them, then the
# schema_migrations table of 001 (013 records itself in it).
bootstrap_roles() {
  sql "CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN;
       CREATE ROLE service_role NOLOGIN BYPASSRLS;
       GRANT USAGE ON SCHEMA public TO service_role;
       ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO service_role;
       CREATE TABLE public.schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL,
         applied_at TIMESTAMPTZ DEFAULT now());" >/dev/null
}

apply_migrations() {
  step "live: 013 + 016 + 090, then 095 twice over a planted old overload"
  bootstrap_roles
  local f
  for f in 013_audit_log 016_unify_rls 090_control_tables_rest_readonly; do apply "${MIG}/${f}.sql"; done
  sql "GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role" >/dev/null
  apply "${M095}"
  sql "CREATE FUNCTION public.audit_log_erase_actor(p_actor uuid, p_dry boolean) RETURNS bigint
       LANGUAGE sql AS 'SELECT 0::bigint'" >/dev/null
  apply "${M095}"
  [ "$(sql "SELECT count(*) FROM public.schema_migrations WHERE version = 95")" = 1 ] || fail "095 does not record itself"
  [ -n "$(sql "SELECT to_regclass('public.audit_log_created_idx')")" ] || fail "audit_log_created_idx is missing"
  ok "095 applied twice, recorded once, created_at index present"
}

empty_database() {
  step "live: 095 on a database without audit_log does nothing"
  sql "CREATE DATABASE m259_empty" >/dev/null
  apply "${M095}" m259_empty
  [ "$(DB=m259_empty sql "SELECT count(*) FROM pg_proc WHERE proname LIKE 'audit\_log\_%'")" = 0 ] ||
    fail "095 created functions in a database without audit_log"
  [ -z "$(DB=m259_empty sql "SELECT to_regclass('public.schema_migrations')")" ] || fail "095 created schema_migrations"
  ok "no function, no table, exit 0"
}

privileges() {
  step "live: no audit_log_% function is executable by PUBLIC, anon or authenticated (C7)"
  local procs="FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'audit\_log\_%'"
  [ "$(sql "SELECT count(*) ${procs}")" = 3 ] || fail "expected 2 functions + the planted overload"
  [ "$(sql "SELECT count(*) ${procs} AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a
        WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))")" = 0 ] || fail "PUBLIC can execute an audit_log_% function"
  [ "$(sql "SELECT count(*) ${procs} AND (has_function_privilege('anon', p.oid, 'EXECUTE')
        OR has_function_privilege('authenticated', p.oid, 'EXECUTE'))")" = 0 ] ||
    fail "anon or authenticated can execute an audit_log_% function"
  [ "$(sql "SELECT has_function_privilege('service_role', 'public.audit_log_erase_actor(uuid)', 'EXECUTE')
        AND has_function_privilege('service_role', 'public.audit_log_purge(interval, integer)', 'EXECUTE')")" = t ] ||
    fail "service_role cannot execute the 095 functions"
  local role
  for role in anon authenticated; do
    grep -q 'permission denied' <<<"$(as_role "${role}" "SELECT public.audit_log_purge('400 days')")" ||
      fail "${role} called audit_log_purge"
    grep -q 'permission denied' <<<"$(as_role "${role}" "SELECT public.audit_log_erase_actor('${ACTOR_A}')")" ||
      fail "${role} called audit_log_erase_actor"
  done
  ok "PUBLIC/anon/authenticated: no EXECUTE on 3 functions (overload included); calls get 42501"
}

seed() {
  local a="${ACTOR_A}" b="${ACTOR_B}" au
  au="$(tr 'a-f' 'A-F' <<<"${a}")"
  sql "INSERT INTO public.audit_log (request_id, actor_id, actor_role, action, resource, payload, ip, user_agent, created_at)
       VALUES (gen_random_uuid(), '${a}', 'authenticated', 'POST', '/rest/v1/users?select=*', '{\"n\":1}', '10.0.0.1', 'ua-a', now() - interval '500 days'),
              (gen_random_uuid(), '${b}', 'authenticated', 'POST', '/rest/v1/posts', '{\"n\":2}', '10.0.0.2', 'ua-b', now() - interval '450 days'),
              (gen_random_uuid(), '${a}', 'authenticated', 'PATCH', '/rest/v1/users/${a}?email=eq.a@example.test', '{\"name\":\"A\"}', '10.0.0.1', 'ua-a', now() - interval '400 days'),
              (gen_random_uuid(), '${b}', 'service_role', 'DELETE', '/rest/v1/users/${au}?select=id', '{\"n\":4}', '10.0.0.2', 'ua-b', now() - interval '10 days'),
              (gen_random_uuid(), NULL, 'anon', 'POST', '/rest/v1/notes', NULL, '10.0.0.3', 'ua-k', now() - interval '10 days')" >/dev/null
  sql "CREATE TABLE m259_before AS SELECT * FROM public.audit_log" >/dev/null
}

erase() {
  step "live: audit_log_erase_actor as service_role (C4)"
  seed
  [ "$(as_role service_role "SELECT public.audit_log_erase_actor('${ACTOR_A}')")" = 3 ] ||
    fail "erase_actor(A) did not report 3 rows (2 own + 1 naming A); RLS may be matching nothing"
  [ "$(sql "SELECT count(*) FROM public.audit_log WHERE id IN (1, 3) AND actor_id IS NULL AND ip IS NULL
        AND user_agent IS NULL AND payload IS NULL")" = 2 ] || fail "A's actor_id/ip/user_agent/payload are not NULL"
  [ "$(sql "SELECT count(*) FROM public.audit_log WHERE id IN (1, 3) AND resource LIKE '%?%'")" = 0 ] ||
    fail "A's resource keeps its query string"
  [ "$(sql "SELECT count(*) FROM public.audit_log WHERE resource ILIKE '%${ACTOR_A}%'")" = 0 ] ||
    fail "A's UUID text survives in a resource"
  [ "$(sql "SELECT resource || ' ' || actor_id || ' ' || payload::text FROM public.audit_log WHERE id = 4")" = \
    "/rest/v1/users/<erased>?select=id ${ACTOR_B} {\"n\": 4}" ] || fail "B's row naming A was not rewritten in place"
  [ "$(sql "SELECT count(*) FROM (SELECT * FROM public.audit_log WHERE id IN (2, 5)
        EXCEPT SELECT * FROM m259_before) changed")" = 0 ] || fail "erase_actor(A) touched rows that neither are A's nor name A"
  [ "$(sql "SELECT count(*) FROM public.audit_log l JOIN m259_before o USING (id)
        WHERE (l.request_id, l.action, l.created_at) = (o.request_id, o.action, o.created_at)")" = 5 ] ||
    fail "request_id, action or created_at changed"
  [ "$(as_role service_role "SELECT public.audit_log_erase_actor('${ACTOR_A}')")" = 0 ] || fail "a second erase is not 0"
  grep -q ERROR <<<"$(as_role service_role "SELECT public.audit_log_erase_actor(NULL)")" || fail "erase_actor(NULL) did not raise"
  ok "own rows NULLed + query stripped + UUID replaced, B's row rewritten, trail kept, second call 0"
}

purge_refuses() {
  local args="$1" why="$2"
  grep -q ERROR <<<"$(as_role service_role "SELECT public.audit_log_purge(${args})")" ||
    fail "audit_log_purge(${args}) did not raise (${why})"
}

purge() {
  step "live: audit_log_purge as service_role (C5)"
  purge_refuses "NULL::interval, 10" "NULL interval"
  purge_refuses "'29 days', 10" "under the 30-day floor"
  purge_refuses "'-400 days', 10" "negative interval, under the 30-day floor"
  purge_refuses "'365 days', NULL::int" "p_batch NULL means LIMIT ALL"
  purge_refuses "'365 days', 0" "p_batch 0 never ends the caller's loop"
  purge_refuses "'365 days', 50001" "p_batch over 50000"
  [ "$(as_role service_role "SELECT public.audit_log_purge('30 days', 1)")" = 1 ] || fail "purge('30 days', 1) is not 1"
  [ "$(sql "SELECT string_agg(id::text, ',' ORDER BY id) FROM public.audit_log")" = 2,3,4,5 ] ||
    fail "the batch of 1 did not delete the oldest id"
  [ "$(as_role service_role "SELECT public.audit_log_purge('365 days')")" = 2 ] || fail "purge('365 days') is not 2"
  [ "$(as_role service_role "SELECT public.audit_log_purge('365 days', 50000)")" = 0 ] || fail "a second purge is not 0"
  [ "$(sql "SELECT string_agg(id::text, ',' ORDER BY id) FROM public.audit_log")" = 4,5 ] ||
    fail "purge deleted a row younger than 365 days"
  ok "NULL/<30 days/negative/batch NULL,0,50001 raise; oldest id first; 10-day rows kept"
}

[ "${1:-}" = "--self-test" ] && {
  self_test
  exit 0
}
static_kong
start_pg
apply_migrations
empty_database
privileges
erase
purge
printf '\033[32mm259 passed\033[0m\n'
