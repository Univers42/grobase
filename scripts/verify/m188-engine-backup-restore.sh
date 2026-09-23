#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m188-engine-backup-restore.sh — MongoDB, CockroachDB and SQL Server must    #
#  survive a backup -> drop -> restore round trip, row for row                 #
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
#  Mutant: M188_RESTORE_ARGS=--dry-run (manifest row engine-restore-dry)       #
#  validates the archive and applies nothing: the restore "succeeds", the      #
#  data is not there, and this gate must go red on the checksum.               #
#                                                                              #
#  Scratch databases are dropped by an EXIT trap.                              #
# **************************************************************************** #
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TOOL="${ROOT}/scripts/ops/engine-backup.sh"
PREFIX="${ENGINE_BACKUP_PREFIX:-mini-baas}"
DB="m188_$$"
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

msql() { docker exec "${PREFIX}-mssql" sh -c '/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -No -b -h -1 -W -Q "$1"' _ "$1"; }
mssql_seed() {
  msql "CREATE DATABASE [${DB}]" >/dev/null
  msql "SET NOCOUNT ON; USE [${DB}]; CREATE TABLE marker (i INT PRIMARY KEY, v NVARCHAR(32)); WITH g AS (SELECT TOP 50 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects) INSERT INTO marker SELECT n, CONCAT('m188-', (n*7919)%1000) FROM g" >/dev/null
}
mssql_sum() { msql "SET NOCOUNT ON; SELECT CONCAT(COUNT(*), ' ', CONVERT(VARCHAR(32), HASHBYTES('MD5', STRING_AGG(CONCAT(i, ':', v), ',') WITHIN GROUP (ORDER BY i)), 2)) FROM [${DB}].dbo.marker" 2>/dev/null | sed '/^\s*$/d' | tail -n1; }
mssql_drop() { msql "IF DB_ID('${DB}') IS NOT NULL BEGIN ALTER DATABASE [${DB}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [${DB}]; END" >/dev/null 2>&1 || true; }

cleanup() {
  running mongo && mongo_drop
  running cockroach && cockroach_drop
  running mssql && mssql_drop
  rm -rf "${WORK}"
}
trap cleanup EXIT

step "0/2 preconditions"
command -v docker >/dev/null 2>&1 || fail "docker is required"
[ -x "${TOOL}" ] || [ -f "${TOOL}" ] || fail "${TOOL} not found"
[ "${#RESTORE_ARGS[@]}" -eq 0 ] || skip "restore runs with extra args: ${RESTORE_ARGS[*]}"

step "1/2 round trip per engine (scratch database ${DB})"
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

step "2/2 verdict"
[ "${tested}" -gt 0 ] || fail "no engine was running: nothing was proven (start mongo, cockroach or mssql)"
[ "${broken}" -eq 0 ] || fail "${broken} of ${tested} engine round trip(s) failed"
ok "${tested} engine(s) round-tripped through scripts/ops/engine-backup.sh"
