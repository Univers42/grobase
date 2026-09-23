#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  engine-backup.sh — dump and restore the engines pg-backup never covered:    #
#  MongoDB, CockroachDB and SQL Server, one portable archive file each         #
#                                                                              #
#  WHY                                                                         #
#    The backup story covered PostgreSQL (pg-backup, m47) and nothing else.    #
#    infra/docker/services/mongo/tools/backup.sh ran `mongodump` inside a     #
#    mongo image that ships only mongod + mongosh, so it could never have      #
#    produced a file; CockroachDB and SQL Server had no dump path at all. A    #
#    multi-engine BaaS whose backups hold one engine is mis-sold.             #
#                                                                              #
#  HOW, per engine (always inside the engine's own running container, so no   #
#  port is published and the credentials never leave it)                      #
#    mongo      mongodump --archive --gzip / mongorestore --archive --gzip     #
#               --drop, as the root user from the container's own env.        #
#    cockroach  BACKUP ... INTO 'nodelocal://1/engine-backup/<id>' (built in,  #
#               free for full backups), the directory tarred out; restore      #
#               tars it back and runs RESTORE ... FROM LATEST IN.              #
#    mssql      BACKUP DATABASE ... TO DISK (native .bak, WITH COPY_ONLY so a  #
#               log chain is never disturbed), tarred out; RESTORE ... WITH    #
#               REPLACE.                                                       #
#  The archive on the host is ONE file whatever the engine: mongo's is the    #
#  gzip archive itself, the other two a tar stream.                           #
#                                                                              #
#  RESTORE SEMANTICS                                                           #
#    mongo and mssql replace the named databases (--drop / WITH REPLACE).      #
#    cockroach refuses to restore over an existing database, by design of      #
#    RESTORE; drop it first. --dry-run reads and validates the archive and     #
#    applies nothing -- the gate's mutant uses it to prove a restore that      #
#    does not land data is caught.                                             #
#                                                                              #
#  USAGE                                                                       #
#    engine-backup.sh dump    <mongo|cockroach|mssql> <file> [--db NAME]...   #
#    engine-backup.sh restore <mongo|cockroach|mssql> <file> [--db NAME]...   #
#                                                     [--dry-run]              #
#    Without --db: every user database of that engine.                        #
#    ENGINE_BACKUP_PREFIX (default mini-baas) names the containers.            #
#                                                                              #
#  Proven by scripts/verify/m188-engine-backup-restore.sh (round trip of a     #
#  scratch database per engine, checksums compared).                          #
# **************************************************************************** #
set -euo pipefail
PREFIX="${ENGINE_BACKUP_PREFIX:-mini-baas}"

die() {
  echo "engine-backup: $*" >&2
  exit 1
}
usage() { die "usage: engine-backup.sh dump|restore <mongo|cockroach|mssql> <file> [--db NAME]... [--dry-run]"; }

[ $# -ge 3 ] || usage
ACTION="$1" ENGINE="$2" FILE="$3"
shift 3
DBS=()
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
  --db)
    [ $# -ge 2 ] || usage
    DBS+=("$2")
    shift 2
    ;;
  --dry-run)
    DRY=1
    shift
    ;;
  *) usage ;;
  esac
done
case "$ACTION" in dump | restore) ;; *) usage ;; esac
C="${PREFIX}-${ENGINE}"
docker ps --format '{{.Names}}' | grep -qx "$C" || die "container $C is not running"
if [ "$ACTION" = restore ]; then
  [ -s "$FILE" ] || die "archive $FILE is missing or empty"
fi
# Names are passed into SQL and shell inside the container: allow only what a
# database name in this stack looks like, so none of it needs quoting.
for d in "${DBS[@]}"; do
  [[ "$d" =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]] || die "refusing database name '$d'"
done
STAMP="eb$(date +%s)$$"

# ── mongo ─────────────────────────────────────────────────────────────────────
mongo_auth='-u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin'
mongo_dump() {
  docker exec "$C" sh -c 'command -v mongodump >/dev/null' ||
    die "no mongodump in $C: the image predates mongodb-database-tools (rebuild the mongo image)"
  # mongodump selects with --db, ONE database per archive (--nsInclude is a
  # mongorestore option; mongodump rejects it). Several --db: one dump each
  # is the caller's loop, so say so rather than silently dumping one.
  local sel=""
  [ "${#DBS[@]}" -le 1 ] || die "mongo: one --db per dump (mongodump archives a single database)"
  [ "${#DBS[@]}" -eq 0 ] || sel=" --db=${DBS[0]}"
  docker exec "$C" sh -c "mongodump --quiet --archive --gzip $mongo_auth$sel" >"$FILE"
}
mongo_restore() {
  docker exec "$C" sh -c 'command -v mongorestore >/dev/null' ||
    die "no mongorestore in $C (rebuild the mongo image)"
  local sel="" dry=""
  [ "${#DBS[@]}" -eq 0 ] || sel=$(printf -- ' --nsInclude=%s.*' "${DBS[@]}")
  [ "$DRY" = 0 ] || dry=" --dryRun"
  docker exec -i "$C" sh -c "mongorestore --quiet --archive --gzip --drop$dry $mongo_auth$sel" <"$FILE"
}

# ── cockroach ─────────────────────────────────────────────────────────────────
crdb_sql() { docker exec "$C" cockroach sql --insecure --format=tsv -e "$1"; }
crdb_user_dbs() {
  crdb_sql "SELECT database_name FROM [SHOW DATABASES] WHERE database_name NOT IN ('system','defaultdb','postgres')" | tail -n +2
}
crdb_dump() {
  local dbs=("${DBS[@]}")
  [ "${#dbs[@]}" -gt 0 ] || mapfile -t dbs < <(crdb_user_dbs)
  [ "${#dbs[@]}" -gt 0 ] || die "cockroach has no user database to back up"
  local list
  list=$(printf '%s,' "${dbs[@]}")
  crdb_sql "BACKUP DATABASE ${list%,} INTO 'nodelocal://1/engine-backup/${STAMP}'" >/dev/null
  docker exec "$C" tar -C /cockroach/cockroach-data/extern/engine-backup -cf - "$STAMP" >"$FILE"
  docker exec "$C" rm -rf "/cockroach/cockroach-data/extern/engine-backup/${STAMP}"
}
crdb_restore() {
  local id dbs=("${DBS[@]}")
  # awk reads the listing to the end: `| head -n1` closed the pipe early, tar
  # died of SIGPIPE on a long archive, and pipefail + set -e aborted the
  # restore with no message (cockroach's archive lists hundreds of entries).
  id=$(tar -tf "$FILE" | awk -F/ 'NR == 1 { print $1 }')
  [[ "$id" =~ ^eb[0-9]+$ ]] || die "$FILE is not an engine-backup cockroach archive"
  docker exec -i "$C" sh -c 'mkdir -p /cockroach/cockroach-data/extern/engine-backup && tar -C /cockroach/cockroach-data/extern/engine-backup -xf -' <"$FILE"
  local where="'nodelocal://1/engine-backup/${id}'" rc=0
  if [ "$DRY" = 1 ]; then
    crdb_sql "SHOW BACKUP FROM LATEST IN ${where}" >/dev/null || rc=$?
  elif [ "${#dbs[@]}" -gt 0 ]; then
    local list
    list=$(printf '%s,' "${dbs[@]}")
    crdb_sql "RESTORE DATABASE ${list%,} FROM LATEST IN ${where}" >/dev/null || rc=$?
  else
    mapfile -t dbs < <(crdb_sql "SELECT DISTINCT database_name FROM [SHOW BACKUP FROM LATEST IN ${where}] WHERE object_type = 'database'" | tail -n +2)
    local list
    list=$(printf '%s,' "${dbs[@]}")
    crdb_sql "RESTORE DATABASE ${list%,} FROM LATEST IN ${where}" >/dev/null || rc=$?
  fi
  docker exec "$C" rm -rf "/cockroach/cockroach-data/extern/engine-backup/${id}"
  return "$rc"
}

# ── mssql ─────────────────────────────────────────────────────────────────────
MSSQL_DIR=/var/opt/mssql/engine-backup
mssql_sql() {
  docker exec "$C" sh -c '/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -No -b -h -1 -W -Q "$1"' _ "$1"
}
mssql_dump() {
  local dbs=("${DBS[@]}") d
  [ "${#dbs[@]}" -gt 0 ] || mapfile -t dbs < <(mssql_sql "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id > 4" | sed '/^\s*$/d')
  [ "${#dbs[@]}" -gt 0 ] || die "mssql has no user database to back up"
  docker exec "$C" mkdir -p "${MSSQL_DIR}/${STAMP}"
  for d in "${dbs[@]}"; do
    mssql_sql "BACKUP DATABASE [${d}] TO DISK = N'${MSSQL_DIR}/${STAMP}/${d}.bak' WITH COPY_ONLY, INIT, FORMAT" >/dev/null
  done
  docker exec "$C" tar -C "$MSSQL_DIR" -cf - "$STAMP" >"$FILE"
  docker exec "$C" rm -rf "${MSSQL_DIR:?}/${STAMP}"
}
mssql_restore() {
  local id bak d rc=0 dbs=("${DBS[@]}")
  # awk reads the listing to the end: `| head -n1` closed the pipe early, tar
  # died of SIGPIPE on a long archive, and pipefail + set -e aborted the
  # restore with no message (cockroach's archive lists hundreds of entries).
  id=$(tar -tf "$FILE" | awk -F/ 'NR == 1 { print $1 }')
  [[ "$id" =~ ^eb[0-9]+$ ]] || die "$FILE is not an engine-backup mssql archive"
  docker exec -i "$C" sh -c "mkdir -p '${MSSQL_DIR}' && tar -C '${MSSQL_DIR}' -xf -" <"$FILE"
  [ "${#dbs[@]}" -gt 0 ] || mapfile -t dbs < <(tar -tf "$FILE" | sed -n 's|^[^/]*/\(.*\)\.bak$|\1|p')
  for d in "${dbs[@]}"; do
    bak="${MSSQL_DIR}/${id}/${d}.bak"
    if [ "$DRY" = 1 ]; then
      mssql_sql "RESTORE VERIFYONLY FROM DISK = N'${bak}'" >/dev/null || rc=$?
    else
      mssql_sql "RESTORE DATABASE [${d}] FROM DISK = N'${bak}' WITH REPLACE" >/dev/null || rc=$?
    fi
  done
  docker exec "$C" rm -rf "${MSSQL_DIR:?}/${id}"
  return "$rc"
}

case "${ENGINE}:${ACTION}" in
mongo:dump) mongo_dump ;;
mongo:restore) mongo_restore ;;
cockroach:dump) crdb_dump ;;
cockroach:restore) crdb_restore ;;
mssql:dump) mssql_dump ;;
mssql:restore) mssql_restore ;;
*) usage ;;
esac
[ "$ACTION" = restore ] || [ -s "$FILE" ] || die "dump of ${ENGINE} produced an empty ${FILE}"
echo "engine-backup: ${ACTION} ${ENGINE} ${FILE}${DBS[*]:+ (${DBS[*]})}$([ "$DRY" = 1 ] && echo ' [dry-run]')"
