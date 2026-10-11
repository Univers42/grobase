#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m225-pg-counts.sh — pg-counts.sh proves a pg_dumpall restore has identical #
#  row counts, table by table                                                  #
#                                                                              #
#  Arms: DUMP · GZIP · EQUAL · DIFFER · MISSING · USAGE · MUTANT              #
#                                                                              #
#  Static only: docker is a stub that answers from fixture files; no daemon,  #
#  no database, no network.                                                   #
#                                                                              #
# **************************************************************************** #
set -uo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CLI="${ROOT}/scripts/ops/pg-counts.sh"

_B=$'\033[0;36m' _G=$'\033[0;32m' _R=$'\033[0;31m' _Y=$'\033[0;33m' _0=$'\033[0m'
rc=0
rc_cli=0
step() { printf '%s[M225] %s%s\n' "${_B}" "$1" "${_0}"; }
ok() { printf '%s  ✓ %s%s\n' "${_G}" "$1" "${_0}"; }
fail() {
  printf '%s[M225] FAIL — %s%s\n' "${_R}" "$1" "${_0}"
  rc=1
}

[ -f "${CLI}" ] || {
  fail "missing scripts/ops/pg-counts.sh"
  exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin" "${WORK}/fixtures"

# Fixture dump: exercises all parsing rules
# - rows before any \connect (db postgres)
# - \connect agency
# - \connect -reuse-previous=on "dbname='red-tetris'"
# - quoted table public."Users"
# - empty table
# - row containing a tab and a backslash
cat >"${WORK}/fixtures/dump.sql" <<'EOF'
-- pg_dumpall plain text dump
CREATE TABLE public.t1 (id int);
COPY public.t1 (id) FROM stdin;
1
2
3
\.
\connect agency
CREATE TABLE public.t2 (id int);
COPY public.t2 (id) FROM stdin;
10
20
\.
CREATE TABLE public."Users" (name text);
COPY public."Users" (name) FROM stdin;
alice
bob
\.
\connect -reuse-previous=on "dbname='red-tetris'"
CREATE TABLE public.empty_tbl (id int);
COPY public.empty_tbl (id) FROM stdin;
\.
CREATE TABLE public.weird (data text);
COPY public.weird (data) FROM stdin;
a	b
c\d
\.
EOF

# Expected TSV output (LC_ALL=C sorted)
cat >"${WORK}/fixtures/expected.tsv" <<'EOF'
agency	public."Users"	2
agency	public.t2	2
postgres	public.t1	3
red-tetris	public.empty_tbl	0
red-tetris	public.weird	2
EOF

# Gzipped version
gzip -c "${WORK}/fixtures/dump.sql" >"${WORK}/fixtures/dump.sql.gz"

# Stub docker that returns counts from a fixture file
# Records the SQL it received to verify one docker exec per database
cat >"${WORK}/bin/docker" <<'STUB_EOF'
#!/bin/sh
printf 'docker %s\n' "$*" >>"$STUB_LOG"
if [ "$1" = "exec" ] && [ "$2" = "-i" ]; then
  sql=$(cat)
  printf '%s\n' "$sql" >>"$STUB_SQL_LOG"
  for db; do :; done
  fixture="${STUB_FIXTURE_DIR}/${db}.tsv"
  if [ -f "$fixture" ]; then
    cat "$fixture"
    exit 0
  else
    exit 1
  fi
fi
exit 0
STUB_EOF
chmod +x "${WORK}/bin/docker"
cat >"${WORK}/bin/awk" <<'AWK_EOF'
#!/bin/sh
if command -v mawk >/dev/null 2>&1; then exec mawk "$@"; fi
exec gawk --posix "$@"
AWK_EOF
chmod +x "${WORK}/bin/awk"

# run_cli ARGS... — stdout/stderr in files, rc in rc_cli
run_cli() {
  rc_cli=0
  env PATH="${WORK}/bin:${PATH}" \
    PG_CONTAINER="stub-postgres" \
    POSTGRES_USER="postgres" \
    POSTGRES_PASSWORD="postgres" \
    STUB_LOG="${WORK}/docker.log" \
    STUB_SQL_LOG="${WORK}/sql.log" \
    STUB_FIXTURE_DIR="${WORK}/fixtures/live" \
    bash "${CLI}" "$@" >"${WORK}/out" 2>"${WORK}/err" || rc_cli=$?
}

dump_arm() {
  step "DUMP — fixture dump prints exactly expected TSV"
  run_cli dump "${WORK}/fixtures/dump.sql"
  if [ "${rc_cli}" -eq 0 ] && diff -u "${WORK}/fixtures/expected.tsv" "${WORK}/out" >/dev/null; then
    ok "stdout matches expected TSV exactly"
  else
    fail "rc ${rc_cli}; diff: $(diff -u "${WORK}/fixtures/expected.tsv" "${WORK}/out" 2>&1 | head -20 | tr '\n' ';')"
  fi
}

gzip_arm() {
  step "GZIP — gzipped fixture gives same TSV"
  run_cli dump "${WORK}/fixtures/dump.sql.gz"
  if [ "${rc_cli}" -eq 0 ] && diff -u "${WORK}/fixtures/expected.tsv" "${WORK}/out" >/dev/null; then
    ok "gzipped dump produces identical TSV"
  else
    fail "rc ${rc_cli}; diff: $(diff -u "${WORK}/fixtures/expected.tsv" "${WORK}/out" 2>&1 | head -20 | tr '\n' ';')"
  fi
}

equal_arm() {
  step "EQUAL — stub returns same counts, check exits 0, stdout empty"
  rm -f "${WORK}/fixtures/live"/*.tsv 2>/dev/null
  mkdir -p "${WORK}/fixtures/live"
  cat >"${WORK}/fixtures/live/postgres.tsv" <<'EOF'
public.t1	3
EOF
  cat >"${WORK}/fixtures/live/agency.tsv" <<'EOF'
public.t2	2
public."Users"	2
EOF
  cat >"${WORK}/fixtures/live/red-tetris.tsv" <<'EOF'
public.empty_tbl	0
public.weird	2
EOF

  run_cli check "${WORK}/fixtures/dump.sql"
  if [ "${rc_cli}" -eq 0 ] && [ ! -s "${WORK}/out" ] && grep -q '0 differ' "${WORK}/err"; then
    ok "rc 0, stdout empty, stderr reports 0 differ"
  else
    fail "rc ${rc_cli}; stdout [$(cat "${WORK}/out")]; stderr [$(cat "${WORK}/err")]"
  fi

  local exec_count
  exec_count=$(grep -c '^docker exec' "${WORK}/docker.log" 2>/dev/null || echo 0)
  if [ "${exec_count}" -eq 3 ]; then
    ok "exactly 3 docker exec calls (one per database)"
  else
    fail "docker exec called ${exec_count} times, expected 3; log: $(tr '\n' ';' <"${WORK}/docker.log")"
  fi
}

differ_arm() {
  step "DIFFER — stub returns one count lower, check exits 3, names table"
  rm -f "${WORK}/fixtures/live"/*.tsv 2>/dev/null
  mkdir -p "${WORK}/fixtures/live"
  cat >"${WORK}/fixtures/live/postgres.tsv" <<'EOF'
public.t1	2
EOF
  cat >"${WORK}/fixtures/live/agency.tsv" <<'EOF'
public.t2	2
public."Users"	2
EOF
  cat >"${WORK}/fixtures/live/red-tetris.tsv" <<'EOF'
public.empty_tbl	0
public.weird	2
EOF

  run_cli check "${WORK}/fixtures/dump.sql"
  if [ "${rc_cli}" -eq 3 ] && grep -q 'public.t1' "${WORK}/out" && grep -q 'dump=3' "${WORK}/out" && grep -q 'live=2' "${WORK}/out"; then
    ok "rc 3, stdout names public.t1 with dump=3 live=2"
  else
    fail "rc ${rc_cli}; stdout [$(cat "${WORK}/out")]; stderr [$(cat "${WORK}/err")]"
  fi
}

missing_arm() {
  step "MISSING — stub fails for one db, all its tables reported live=missing"
  rm -f "${WORK}/fixtures/live"/*.tsv 2>/dev/null
  mkdir -p "${WORK}/fixtures/live"
  cat >"${WORK}/fixtures/live/postgres.tsv" <<'EOF'
public.t1	3
EOF
  cat >"${WORK}/fixtures/live/agency.tsv" <<'EOF'
public.t2	2
public."Users"	2
EOF

  run_cli check "${WORK}/fixtures/dump.sql"
  if [ "${rc_cli}" -eq 3 ]; then
    if grep -q 'red-tetris	public.empty_tbl	dump=0	live=missing' "${WORK}/out" &&
      grep -q 'red-tetris	public.weird	dump=2	live=missing' "${WORK}/out"; then
      ok "rc 3, both red-tetris tables live=missing"
    else
      fail "stdout missing expected lines: $(cat "${WORK}/out")"
    fi
  else
    fail "rc ${rc_cli}; stdout [$(cat "${WORK}/out")]; stderr [$(cat "${WORK}/err")]"
  fi
}

usage_arm() {
  step "USAGE — no verb / unknown verb / unreadable FILE -> exit 2"
  run_cli
  [ "${rc_cli}" -eq 2 ] && ok "no verb -> rc 2" || fail "no verb -> rc ${rc_cli}"

  run_cli unknown
  [ "${rc_cli}" -eq 2 ] && ok "unknown verb -> rc 2" || fail "unknown verb -> rc ${rc_cli}"

  run_cli dump "${WORK}/nope.sql"
  [ "${rc_cli}" -eq 2 ] && ok "unreadable FILE -> rc 2" || fail "unreadable FILE -> rc ${rc_cli}"

  run_cli --help
  [ "${rc_cli}" -eq 0 ] && ok "--help -> rc 0" || fail "--help -> rc ${rc_cli}"
}

# mutant_arm — a copy whose awk skips the -reuse-previous=on strip (that line turned into an awk
# comment) must mis-name red-tetris, or the DUMP arm could not catch that bug.
mutant_arm() {
  step "MUTANT — copy with broken -reuse-previous handling must make DUMP fail"
  local mutant="${WORK}/pg-counts.mutant.sh"

  sed '/sub.*reuse-previous/s/^      /      # MUTANT: /' "${CLI}" >"${mutant}"
  chmod +x "${mutant}"

  env PATH="${WORK}/bin:${PATH}" \
    PG_CONTAINER="stub-postgres" \
    POSTGRES_USER="postgres" \
    POSTGRES_PASSWORD="postgres" \
    bash "${mutant}" dump "${WORK}/fixtures/dump.sql" >"${WORK}/mutant_out" 2>"${WORK}/mutant_err" || rc_cli=$?

  if ! diff -u "${WORK}/fixtures/expected.tsv" "${WORK}/mutant_out" >/dev/null; then
    ok "mutant output differs from expected (parsing broken)"
  else
    fail "mutant unexpectedly produced correct output — the arm cannot catch the bug"
  fi
}

dump_arm
gzip_arm
equal_arm
differ_arm
missing_arm
usage_arm
mutant_arm

if [ "${rc}" -eq 0 ]; then
  printf '%s[M225] PASS — pg-counts.sh verifies pg_dumpall restore row counts exactly%s\n' "${_G}" "${_0}"
else
  printf '%s[M225] FAIL%s\n' "${_R}" "${_0}"
fi
exit "${rc}"
