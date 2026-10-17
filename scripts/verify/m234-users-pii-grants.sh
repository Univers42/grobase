#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m234-users-pii-grants.sh — anon and authenticated cannot read password_hash,#
#  and anon cannot read email, on the live database                            #
#                                                                              #
#  b2b incident 2026-10-17 (groot ADR 0014): anon read every user's email and  #
#  both roles held SELECT on users.password_hash, and 001_initial_schema.sql   #
#  re-opened it on every `make migrate`. 092 closes it; this gate reads the    #
#  catalog of the running database:                                            #
#    (1) static: no migration numbered above 092 grants on public.users        #
#    (2) catalog: the only (email|password_hash) SELECT grant held by          #
#        anon/authenticated/PUBLIC on users or movieverse_profiles is          #
#        users|authenticated|email                                             #
#    (3) behaviour: SET ROLE anon; SELECT email FROM public.users -> 42501     #
#    (4) mutation: inside a rolled-back transaction, re-grant the way 001 does #
#        and prove the catalog query from (2) sees it                          #
#                                                                              #
#  Caveat: (1) is a text match on GRANT/users lines; a grant built inside a    #
#  DO block by format() is invisible to it, (2)-(3) are what catch that.       #
#  Needs mini-baas-postgres running; there is no SKIP, a gate that cannot read #
#  the catalog proves nothing.                                                 #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DIR="${M234_DIR:-${ROOT}/scripts/migrations/postgresql}"
PG="${M234_CONTAINER:-mini-baas-postgres}"
FIX_VERSION=92
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M234] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M234] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

psql_in() { docker exec -i "${PG}" psql -U postgres -d postgres -Atq -v ON_ERROR_STOP=1 "$@"; }

CATALOG_SQL="SELECT table_name || '|' || grantee || '|' || column_name FROM information_schema.column_privileges
  WHERE table_schema='public' AND table_name IN ('users','movieverse_profiles')
    AND grantee IN ('anon','authenticated','PUBLIC') AND privilege_type='SELECT'
    AND column_name IN ('email','password_hash') ORDER BY table_name, grantee, column_name;"
EXPECTED="users|authenticated|email"

# static_nothing_after_fix fails on a migration numbered above the fix that grants on public.users.
static_nothing_after_fix() {
  local f v late=""
  for f in "${DIR}"/[0-9][0-9][0-9]_*.sql; do
    v="$((10#$(basename "${f}" | cut -c1-3)))"
    [ "${v}" -gt "${FIX_VERSION}" ] || continue
    sed 's/--.*//' "${f}" | grep -Eiq 'GRANT[^;]*ON[[:space:]]+(TABLE[[:space:]]+)?(public\.)?users([[:space:]]|;|$)' &&
      late="${late} ${f##*/}"
  done
  [ -z "${late}" ] || fail "sorts after 092 and grants on public.users, re-opening the leak on every migrate:${late}"
  ok "no migration above 092 grants on public.users"
}

# catalog_matches fails unless the query $1 returns exactly the expected rows $2.
catalog_matches() {
  local got
  got="$(printf '%s\n' "$1" | psql_in)" || fail "catalog query failed"
  [ "${got}" = "$2" ] || fail "expected '$2', got: $(printf '%s' "${got}" | tr '\n' ' ')"
}

# anon_email_is_denied fails unless anon's SELECT email raises SQLSTATE 42501.
anon_email_is_denied() {
  local out
  out="$(printf '%s\n' '\set VERBOSITY verbose' 'SET ROLE anon;' 'SELECT email FROM public.users;' |
    docker exec -i "${PG}" psql -U postgres -d postgres -Atq 2>&1)"
  printf '%s' "${out}" | grep -q '42501' || fail "anon SELECT email did not fail with 42501: ${out}"
  ok "anon SELECT email FROM public.users -> 42501"
}

# mutation_is_detected re-grants as 001 does inside a transaction that is rolled back,
# then checks the catalog query returns something other than the expected rows.
mutation_is_detected() {
  local seen
  seen="$(printf '%s\n' 'BEGIN;' 'GRANT SELECT ON public.users TO anon, authenticated;' "${CATALOG_SQL}" 'ROLLBACK;' |
    psql_in | grep -v '^BEGIN$' | grep -v '^ROLLBACK$')" || fail "mutation leg could not run"
  [ "${seen}" != "${EXPECTED}" ] || fail "mutation leg: a table-level re-grant went unseen by the catalog query"
  printf '%s' "${seen}" | grep -q '^users|anon|email$' || fail "mutation leg: anon email not reported: ${seen}"
  catalog_matches "${CATALOG_SQL}" "${EXPECTED}"
  ok "mutation: a table-level re-grant is seen ($(printf "%s\n" "${seen}" | grep -c .) leaks reported) and rolled back"
}

step "static — nothing after the fix re-grants users"
static_nothing_after_fix
step "live — ${PG}"
docker inspect -f '{{.State.Running}}' "${PG}" 2>/dev/null | grep -qx true || fail "${PG} is not running (make up, make migrate)"
catalog_matches "${CATALOG_SQL}" "${EXPECTED}"
ok "catalog: only ${EXPECTED} is readable by a public role (movieverse_profiles: none)"
anon_email_is_denied
mutation_is_detected
printf '\033[0;32m[M234] OK — password_hash and anon email are closed\033[0m\n'
