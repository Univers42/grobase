#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m203-migrations-recorded.sh — every PostgreSQL migration records itself in  #
#  public.schema_migrations, so `make migrate-status` shows what ran.          #
#                                                                              #
#  The runners (pg-migrate, make migrate) re-apply every file on every boot;   #
#  each file is idempotent and inserts its own version. 038, 087, 088 and 089  #
#  did not, so an operator could not see from migrate-status whether a        #
#  deployment had the two security migrations (088 schema_registry, 089        #
#  default privileges).                                                        #
#                                                                              #
#    (1) static: migration numbers are unique (the three historical 035_*      #
#        files are the one allowed group) and every file inserts its own       #
#        version into public.schema_migrations                                 #
#    (2) live, when mini-baas-postgres runs: every version on disk is in       #
#        public.schema_migrations; without the container it prints SKIP        #
#                                                                              #
#  Ponytail: (1) is a text match — a file that names its version only inside   #
#  a comment passes; (2) is what catches that.                                 #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DIR="${M203_DIR:-${ROOT}/scripts/migrations/postgresql}"
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M203] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M203] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

# versions prints the integer version of every migration file, one per line.
versions() {
  local f
  for f in "${DIR}"/[0-9][0-9][0-9]_*.sql; do
    f="${f##*/}"
    printf '%d\n' "$((10#${f%%_*}))"
  done
}

# records reports whether migration file $1 inserts version $2 into
# public.schema_migrations outside a comment.
records() {
  sed 's/--.*//' "$1" | tr '\n' ' ' |
    grep -Eq "schema_migrations[^;]*(\(|[[:space:]]|,)$2[[:space:]]*(,|\))"
}

# static_unique fails on a duplicated migration number other than 035.
static_unique() {
  local dup
  dup="$(versions | sort -n | uniq -d | grep -vx 35 | tr '\n' ' ')"
  [ -z "${dup}" ] || fail "duplicated migration number(s): ${dup}— pick the next free one"
  ok "migration numbers are unique (035 is the one historical group)"
}

# static_records fails on a file that never inserts its own version.
static_records() {
  local f v missing=""
  for f in "${DIR}"/[0-9][0-9][0-9]_*.sql; do
    v="$((10#$(basename "${f}" | cut -c1-3)))"
    [ "${v}" = 35 ] && [ "${f##*/}" = 035_pg_graphql.sql ] && continue
    records "${f}" "${v}" || missing="${missing} ${f##*/}"
  done
  [ -z "${missing}" ] || fail "never insert their version into public.schema_migrations:${missing}"
  ok "$(versions | wc -l) files, each records its own version (035_pg_graphql shares 35 with two siblings)"
}

# live_recorded compares the versions on disk with the running database.
live_recorded() {
  local got want gap
  docker inspect -f '{{.State.Running}}' mini-baas-postgres 2>/dev/null | grep -q true ||
    {
      printf '  SKIP live half: mini-baas-postgres is not running\n'
      return 0
    }
  got="$(docker exec mini-baas-postgres psql -U postgres -tAc 'SELECT version FROM public.schema_migrations' | sort -n)" ||
    fail "could not read public.schema_migrations"
  want="$(versions | sort -nu)"
  gap="$(comm -23 <(printf '%s\n' "${want}") <(printf '%s\n' "${got}") | tr '\n' ' ')"
  [ -z "${gap}" ] || fail "on disk but not in schema_migrations: ${gap}(run make migrate, then re-check)"
  ok "live: every version on disk is recorded in public.schema_migrations"
}

step "static — numbering and self-recording"
static_unique
static_records
step "live — the running database agrees"
live_recorded
printf '\033[0;32m[M203] OK — every migration is visible in make migrate-status\033[0m\n'
