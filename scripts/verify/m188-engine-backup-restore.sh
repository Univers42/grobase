#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m188-engine-backup-restore.sh — MongoDB, CockroachDB and SQL Server must    #
#  survive a backup -> drop -> restore round trip, row for row, and a hostile  #
#  archive must be refused before it reaches the engine                        #
#                                                                              #
#  m47 proves PostgreSQL's. Nothing proved the other engines, and nothing     #
#  could have: the mongo image had no mongodump, CockroachDB and SQL Server    #
#  had no dump path at all. scripts/ops/engine-backup.sh now provides one;     #
#  an untested backup is a claim, so this gate is its proof.                   #
#                                                                              #
#  Per engine that is RUNNING, against a SCRATCH database it creates itself    #
#  (never tenant data), in m47's order:                                        #
#    1 seed     50 deterministic rows, checksum computed by the engine         #
#    2 dump     engine-backup.sh dump <engine> <file> --db <scratch>           #
#    3 drop     the scratch database (only the one this run created)           #
#    4 restore  engine-backup.sh restore ... (+ M188_RESTORE_ARGS)             #
#    5 assert   the same checksum, computed the same way                       #
#  An engine that is not running is SKIPPED and named; ZERO engines tested is  #
#  a failure, so the gate cannot pass vacuously on a stack without them.       #
#                                                                              #
#  Hostile archives, built here from EMPTY files (never a real backup, so      #
#  nothing in them can restore), per running engine:                          #
#    refused up front, the tool's docker calls logged by a shim on PATH: it    #
#    must exit non-zero with the expected reason and call nothing but          #
#    `docker ps` (nothing unpacked, no SQL sent) for                           #
#      a symlink member, an <id>/../ member        cockroach, mssql           #
#      msdb.bak and "MoDeL .bak"                   mssql                      #
#      --db "m188]'$(x)"                           every engine               #
#    quoted, never executed (mssql): a member named                            #
#      m188_nx<pid>]; CREATE DATABASE [<probe>]; --'; CREATE ...; --$(x)       #
#      restored with and without --dry-run must fail on its empty .bak and     #
#      leave DB_ID('<probe>') NULL and the scratch dir empty. MUTANT legs:     #
#      the same archive through a copy of the tool whose sql_lit (dry run) or  #
#      sql_ident (restore) no longer escapes MUST create <probe> -- else the   #
#      probe is blind and the gate fails. The probe is dropped by the trap.    #
#    tempdb in full-width letters (SQL Server folds it onto tempdb) must be    #
#      stopped by the RESTORE's own DB_ID <= 4 guard (needs a C.UTF-8 locale). #
#    cockroach: a database named  M188_<pid> "user"<TAB>x'y  backed up by      #
#      hand and restored WITHOUT --db must come back under exactly that name.  #
#                                                                              #
#  Mutant: M188_RESTORE_ARGS=--dry-run (manifest row engine-restore-dry)       #
#  validates the archive and applies nothing: the restore "succeeds", the      #
#  data is not there, and this gate must go red on the checksum.               #
#                                                                              #
#  Scratch databases and scratch dirs are removed by an EXIT trap.             #
# **************************************************************************** #
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TOOL="${ROOT}/scripts/ops/engine-backup.sh"
PREFIX="${ENGINE_BACKUP_PREFIX:-mini-baas}"
DB="m188_$$"
HID="eb188$$"
PROBE="m188probe_$$"
EVIL="m188_nx$$]; CREATE DATABASE [${PROBE}]; --'; CREATE DATABASE [${PROBE}]; --\$(x)"
BADDB="m188]'\$(x)"
WIDE="ｔｅｍｐｄｂ"
CRNAME="M188_$$ \"user\""$'\t'"x'y"
CRQ="\"${CRNAME//\"/\"\"}\""
MSSQL_DIR=/var/opt/mssql/engine-backup
CRDB_DIR=/cockroach/cockroach-data/extern/engine-backup
WORK="$(mktemp -d)"
read -r -a RESTORE_ARGS <<<"${M188_RESTORE_ARGS:-}"
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M188] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
skip() { printf '\033[0;33m  · %s\033[0m\n' "$*"; }
bad() { printf '\033[0;31m  ✗ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M188] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}
running() { docker ps --format '{{.Names}}' | grep -qx "${PREFIX}-$1"; }

# ── per-engine SQL/JS, each returning ONE line "<rows> <checksum>" ────────────
mongo_eval() {
  docker exec "${PREFIX}-mongo" sh -c 'mongosh --quiet -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --eval "$1"' _ "$1"
}
mongo_seed() { mongo_eval "const d=db.getSiblingDB('${DB}'); d.marker.insertMany(Array.from({length:50},(_,i)=>({i:i+1,v:'m188-'+((i+1)*7919%1000)})))" >/dev/null; }
mongo_sum() { mongo_eval "const d=db.getSiblingDB('${DB}'); const r=d.marker.find({},{_id:0}).sort({i:1}).toArray(); print(r.length+' '+require('crypto').createHash('md5').update(JSON.stringify(r)).digest('hex'))" 2>/dev/null | tail -n1; }
mongo_drop() { mongo_eval "db.getSiblingDB('${DB}').dropDatabase()" >/dev/null 2>&1 || true; }

crdb() { docker exec "${PREFIX}-cockroach" cockroach sql --insecure --format=tsv -e "$1"; }
cockroach_seed() { crdb "CREATE DATABASE ${DB}; CREATE TABLE ${DB}.marker (i INT PRIMARY KEY, v STRING); INSERT INTO ${DB}.marker SELECT g, 'm188-' || ((g*7919)%1000)::STRING FROM generate_series(1,50) g" >/dev/null; }
cockroach_sum() { crdb "SELECT count(*)::STRING || ' ' || md5(string_agg(i::STRING || ':' || v, ',' ORDER BY i)) FROM ${DB}.marker" 2>/dev/null | tail -n1; }
cockroach_drop() { crdb "DROP DATABASE IF EXISTS ${DB} CASCADE" >/dev/null 2>&1 || true; }

msql() { docker exec "${PREFIX}-mssql" sh -c '/opt/mssql-tools18/bin/sqlcmd -x -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -No -b -h -1 -W -Q "$1"' _ "$1"; }
mssql_seed() {
  msql "CREATE DATABASE [${DB}]" >/dev/null
  msql "SET NOCOUNT ON; USE [${DB}]; CREATE TABLE marker (i INT PRIMARY KEY, v NVARCHAR(32)); WITH g AS (SELECT TOP 50 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects) INSERT INTO marker SELECT n, CONCAT('m188-', (n*7919)%1000) FROM g" >/dev/null
}
mssql_sum() { msql "SET NOCOUNT ON; SELECT CONCAT(COUNT(*), ' ', CONVERT(VARCHAR(32), HASHBYTES('MD5', STRING_AGG(CONCAT(i, ':', v), ',') WITHIN GROUP (ORDER BY i)), 2)) FROM [${DB}].dbo.marker" 2>/dev/null | sed '/^\s*$/d' | tail -n1; }
# mssql_drop [NAME]: drop NAME (default the scratch database) if it exists.
mssql_drop() {
  local n="${1:-${DB}}"
  msql "IF DB_ID('${n}') IS NOT NULL BEGIN ALTER DATABASE [${n}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [${n}]; END" >/dev/null 2>&1 || true
}
mssql_has() { [ "$(msql "SET NOCOUNT ON; SELECT CASE WHEN DB_ID(N'$1') IS NULL THEN 0 ELSE 1 END" | tr -d '[:space:]')" = 1 ]; }

# cleanup: drop every scratch database and scratch dir this run could have made.
cleanup() {
  running mongo && mongo_drop
  if running cockroach; then
    cockroach_drop
    crdb "DROP DATABASE IF EXISTS ${CRQ} CASCADE" >/dev/null 2>&1 || true
    docker exec "${PREFIX}-cockroach" rm -rf "${CRDB_DIR:?}/${HID}" || true
  fi
  if running mssql; then
    mssql_drop
    mssql_drop "${PROBE}"
    docker exec "${PREFIX}-mssql" rm -rf "${MSSQL_DIR:?}/${HID}" || true
  fi
  rm -rf "${WORK}"
}
trap cleanup EXIT

# ── hostile archives ──────────────────────────────────────────────────────────
# make_shim: a docker in ${WORK}/shim that appends each call's argv to
# ${WORK}/docker.log, then runs the real docker.
make_shim() {
  mkdir -p "${WORK}/shim"
  cat >"${WORK}/shim/docker" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"${WORK}/docker.log"
exec "$(command -v docker)" "\$@"
EOF
  chmod +x "${WORK}/shim/docker"
}
# pack TAR [OPTION|MEMBER]...: tar ${WORK}/TAR from the staging dir ${WORK}/h,
# holding ${HID}/ and the MEMBERs given, nothing else.
pack() {
  local out="$1"
  shift
  tar -C "${WORK}/h" --no-recursion -cf "${WORK}/${out}" "${HID}/" "$@"
}
# build_archives: stage empty files (and one symlink) and pack each hostile tar.
build_archives() {
  local s="${WORK}/h/${HID}" m
  mkdir -p "${s}"
  for m in ok msdb "MoDeL " "${EVIL}" "${WIDE}"; do : >"${s}/${m}.bak"; done
  : >"${WORK}/h/escape.bak"
  ln -s /etc/passwd "${s}/link.bak"
  pack link.tar "${HID}/ok.bak" "${HID}/link.bak"
  pack dotdot.tar "${HID}/ok.bak" --transform="s|^escape|${HID}/../escape|" escape.bak
  pack msdb.tar "${HID}/msdb.bak"
  pack model.tar "${HID}/MoDeL .bak"
  pack evil.tar "${HID}/${EVIL}.bak"
  pack wide.tar "${HID}/${WIDE}.bak"
}
# refused WANT ENGINE TAR [ARG...]: restore TAR through the shim; pass when the
# tool exits non-zero saying WANT and made no docker call but `docker ps`.
refused() {
  local want="$1" engine="$2" tar="$3" calls
  shift 3
  : >"${WORK}/docker.log"
  if PATH="${WORK}/shim:${PATH}" bash "${TOOL}" restore "${engine}" "${WORK}/${tar}" "$@" >"${WORK}/h.log" 2>&1; then
    bad "${engine} ${tar} $*: restore SUCCEEDED, expected a refusal (${want})"
    return 1
  fi
  calls=$(grep -v '^ps ' "${WORK}/docker.log" | head -n1 || true)
  if [ -n "${calls}" ] || ! grep -qF -- "${want}" "${WORK}/h.log"; then
    bad "${engine} ${tar} $*: not refused up front — $(tail -n1 "${WORK}/h.log")${calls:+ :: reached: docker ${calls}}"
    return 1
  fi
  ok "${engine} ${tar}${*:+ $*}: refused, no docker exec (${want})"
}
# evil_leg: evil.tar, as a dry run and as a restore, must fail on its empty
# .bak with DB_ID(PROBE) still NULL and nothing left in the scratch dir.
evil_leg() {
  local mode
  for mode in --dry-run ""; do
    if bash "${TOOL}" restore mssql "${WORK}/evil.tar" ${mode:+"${mode}"} >"${WORK}/evil.log" 2>&1; then
      bad "mssql evil.tar ${mode:-restore}: an empty .bak restored"
      return 1
    fi
    if mssql_has "${PROBE}" || docker exec "${PREFIX}-mssql" test -e "${MSSQL_DIR}/${HID}"; then
      bad "mssql evil.tar ${mode:-restore}: the member name ran as SQL (${PROBE} exists) or the scratch dir was left behind"
      return 1
    fi
  done
  ok "mssql evil.tar: a member named $(printf '%q' "${EVIL}") stayed data (${PROBE} absent, dry run and restore)"
}
# shellcheck disable=SC2016
# mutant_leg: evil.tar through a tool copy with sql_lit (dry run) or sql_ident
# (restore) un-escaped MUST create PROBE: proof the probe can see an injection.
mutant_leg() {
  local fn expr mode
  for fn in sql_lit sql_ident; do
    expr='s|"${1//$q/$q$q}"|"$1"|' mode=--dry-run
    [ "${fn}" = sql_lit ] || expr='s|"${1//$rb/$rb$rb}"|"$1"|' mode=
    sed "${expr}" "${TOOL}" >"${WORK}/mutant.sh"
    if cmp -s "${TOOL}" "${WORK}/mutant.sh"; then
      bad "mutant ${fn}: its escaping is not in the tool any more — rebuild this leg"
      return 1
    fi
    bash "${WORK}/mutant.sh" restore mssql "${WORK}/evil.tar" ${mode:+"${mode}"} >"${WORK}/mutant.log" 2>&1 || true
    if ! mssql_has "${PROBE}"; then
      bad "mutant ${fn}: un-escaped, evil.tar did not create ${PROBE} — the probe is blind"
      return 1
    fi
    mssql_drop "${PROBE}"
    ok "mutant ${fn}: un-escaped, evil.tar ran its SQL (${PROBE} created, then dropped) — the probe sees it"
  done
}
# wide_leg: tempdb in full-width letters is not ASCII, so only the RESTORE's
# own DB_ID <= 4 guard can stop it; needs a UTF-8 locale for tar to list it.
wide_leg() {
  if ! LC_ALL=C.UTF-8 tar -tf "${WORK}/wide.tar" 2>/dev/null | grep -qF "${WIDE}"; then
    skip "mssql wide.tar: no C.UTF-8 locale, tar escapes the name — skipped"
    return 0
  fi
  if LC_ALL=C.UTF-8 bash "${TOOL}" restore mssql "${WORK}/wide.tar" >"${WORK}/wide.log" 2>&1 ||
    ! grep -qF 'refusing to restore over a system database' "${WORK}/wide.log"; then
    bad "mssql wide.tar: ${WIDE} not stopped by the DB_ID guard — $(tail -n1 "${WORK}/wide.log")"
    return 1
  fi
  ok "mssql wide.tar: ${WIDE} (tempdb, full width) stopped by the RESTORE's DB_ID <= 4 guard"
}
# crdb_name_leg: back up a database named CRNAME by hand, drop it, restore the
# archive WITHOUT --db: it must come back under exactly that name.
crdb_name_leg() {
  local file="${WORK}/crname.tar" got
  crdb "CREATE DATABASE ${CRQ}; CREATE TABLE ${CRQ}.marker (i INT PRIMARY KEY); INSERT INTO ${CRQ}.marker VALUES (188)" >/dev/null
  crdb "BACKUP DATABASE ${CRQ} INTO 'nodelocal://1/engine-backup/${HID}'" >/dev/null
  docker exec "${PREFIX}-cockroach" tar -C "${CRDB_DIR}" -cf - "${HID}" >"${file}"
  docker exec "${PREFIX}-cockroach" rm -rf "${CRDB_DIR:?}/${HID}"
  crdb "DROP DATABASE ${CRQ} CASCADE" >/dev/null
  bash "${TOOL}" restore cockroach "${file}" >"${WORK}/crname.log" 2>&1 || true
  got=$(crdb "SELECT i FROM ${CRQ}.marker" 2>/dev/null | tail -n1 || true)
  if [ "${got}" != 188 ]; then
    bad "cockroach: $(printf '%q' "${CRNAME}") not restored under its own name — $(tail -n1 "${WORK}/crname.log")"
    return 1
  fi
  ok "cockroach: $(printf '%q' "${CRNAME}") restored without --db under exactly that name"
}

step "0/3 preconditions"
command -v docker >/dev/null 2>&1 || fail "docker is required"
[ -x "${TOOL}" ] || [ -f "${TOOL}" ] || fail "${TOOL} not found"
[ "${#RESTORE_ARGS[@]}" -eq 0 ] || skip "restore runs with extra args: ${RESTORE_ARGS[*]}"

step "1/3 round trip per engine (scratch database ${DB})"
tested=0
broken=0
for engine in mongo cockroach mssql; do
  if ! running "${engine}"; then
    skip "${engine}: ${PREFIX}-${engine} not running — skipped"
    continue
  fi
  tested=$((tested + 1))
  file="${WORK}/${engine}.archive"
  "${engine}_seed" || {
    bad "${engine}: could not seed the scratch database"
    broken=$((broken + 1))
    continue
  }
  before=$("${engine}_sum")
  case "${before}" in 50\ *) ;; *)
    bad "${engine}: seed checksum unexpected: '${before}'"
    broken=$((broken + 1))
    continue
    ;;
  esac
  if ! bash "${TOOL}" dump "${engine}" "${file}" --db "${DB}" >"${WORK}/${engine}.log" 2>&1; then
    bad "${engine}: dump failed — $(tail -n1 "${WORK}/${engine}.log")"
    broken=$((broken + 1))
    continue
  fi
  size=$(wc -c <"${file}")
  "${engine}_drop"
  gone=$("${engine}_sum" || true)
  case "${gone}" in 50\ *)
    bad "${engine}: the scratch database survived the drop, the round trip would prove nothing"
    broken=$((broken + 1))
    continue
    ;;
  esac
  if ! bash "${TOOL}" restore "${engine}" "${file}" --db "${DB}" "${RESTORE_ARGS[@]}" >>"${WORK}/${engine}.log" 2>&1; then
    bad "${engine}: restore failed — $(tail -n1 "${WORK}/${engine}.log")"
    broken=$((broken + 1))
    continue
  fi
  after=$("${engine}_sum" || true)
  if [ "${after}" = "${before}" ]; then
    ok "${engine}: 50 rows back, checksum identical (${before#* }, archive ${size} bytes)"
  else
    bad "${engine}: restored data differs — before '${before}', after '${after:-<no data>}'"
    broken=$((broken + 1))
  fi
done

step "2/3 hostile archives (id ${HID}, probe database ${PROBE})"
make_shim
build_archives
hostile=0
hbroken=0
for engine in mongo cockroach mssql; do
  running "${engine}" || continue
  hostile=$((hostile + 1))
  refused "refusing database name" "${engine}" evil.tar --db "${BADDB}" || hbroken=$((hbroken + 1))
done
if running cockroach; then
  refused "link or special member" cockroach link.tar || hbroken=$((hbroken + 1))
  refused "outside ${HID}/" cockroach dotdot.tar || hbroken=$((hbroken + 1))
  crdb_name_leg || hbroken=$((hbroken + 1))
else
  skip "cockroach: not running — its hostile-archive legs skipped"
fi
if running mssql; then
  refused "link or special member" mssql link.tar || hbroken=$((hbroken + 1))
  refused "outside ${HID}/" mssql dotdot.tar || hbroken=$((hbroken + 1))
  refused "refusing to restore system database" mssql msdb.tar || hbroken=$((hbroken + 1))
  refused "refusing to restore system database" mssql model.tar || hbroken=$((hbroken + 1))
  evil_leg || hbroken=$((hbroken + 1))
  mutant_leg || hbroken=$((hbroken + 1))
  wide_leg || hbroken=$((hbroken + 1))
else
  skip "mssql: not running — its hostile-archive legs skipped"
fi

step "3/3 verdict"
[ "${tested}" -gt 0 ] || fail "no engine was running: nothing was proven (start mongo, cockroach or mssql)"
[ "${broken}" -eq 0 ] || fail "${broken} of ${tested} engine round trip(s) failed"
[ "${hbroken}" -eq 0 ] || fail "${hbroken} hostile-archive check(s) failed"
ok "${tested} engine(s) round-tripped through scripts/ops/engine-backup.sh; hostile archives handled on ${hostile}"
