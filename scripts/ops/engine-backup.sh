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
#    RESTORE; drop it first. --dry-run restores no data -- the gate's mutant   #
#    uses it to prove a restore that does not land data is caught -- but it    #
#    is not inert: cockroach and mssql still unpack the archive into the       #
#    engine container's scratch dir (removed after) to SHOW BACKUP / RESTORE   #
#    VERIFYONLY it; mongo streams it through mongorestore --dryRun.            #
#                                                                              #
#  NAMES AND ARCHIVES (an archive is untrusted input, dry run or not)          #
#    --db NAME must be a plain identifier, taken exactly (cockroach: case      #
#    kept). Without --db, cockroach names (SHOW DATABASES / the backup) are    #
#    read hex-encoded and pasted as "..." identifiers, a " doubled, so upper   #
#    case, keywords (user, table) and quotes stay the name itself.             #
#    mssql names (sys.databases / the archive) are quoted the QUOTENAME way    #
#    and sqlcmd runs with -x, so ] ' and $( stay data. dump refuses a name     #
#    restore could not read back from its <name>.bak path: \, a control        #
#    character, or an empty, . or .. folder part (a / makes a folder).         #
#    mssql restore refuses master, model, msdb and tempdb (any case, trailing  #
#    spaces ignored) before unpacking anything, and each RESTORE re-checks     #
#    DB_ID <= 4 first, for a name the collation folds onto one (full width).   #
#    Every member of an archive must be a plain file or directory under its    #
#    one eb<N>/ id (mssql: folders and .bak files only), with no .. part, or   #
#    nothing is unpacked. mssql restore takes names from tar's listing: run    #
#    it in a UTF-8 locale, or tar escapes a non-ASCII name and that database   #
#    fails to restore.                                                         #
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

# archive_id ENGINE TAIL: print the eb<N> id of the tar $FILE; die unless every
# member is a plain file or directory <id>/ + TAIL (an ERE) with no `..` part,
# so unpacking stays in <id>/. awk drains each listing (`| head -n1` let tar die
# of SIGPIPE on a long archive).
archive_id() {
  local id
  id=$(tar -tf "$FILE" | awk -F/ 'NR == 1 { print $1 }')
  [[ "$id" =~ ^eb[0-9]+$ ]] || die "$FILE is not an engine-backup $1 archive"
  tar -tvf "$FILE" | awk '!/^[-d]/ { print "engine-backup: refusing member: " $0 > "/dev/stderr"; bad = 1 } END { exit bad }' ||
    die "$FILE holds a link or special member; nothing unpacked"
  tar -tf "$FILE" | RE="^${id}/($2)\$" awk '/(^|\/)\.\.(\/|$)/ || $0 !~ ENVIRON["RE"] { print "engine-backup: refusing member: " $0 > "/dev/stderr"; bad = 1 } END { exit bad }' ||
    die "$FILE holds a member outside ${id}/; nothing unpacked"
  echo "$id"
}

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
# crdb_names SQL: run SQL, whose one column is a database name hex-encoded, and
# print each name NUL-terminated. Hex, because --format=tsv CSV-quotes a name
# holding " or a tab, and a newline in a name would split it.
crdb_names() {
  local esc
  crdb_sql "$1" | tail -n +2 | sed 's/../\\x&/g' | while IFS= read -r esc; do printf '%b\0' "$esc"; done
}
# crdb_list NAME...: the NAMEs comma-joined as double-quoted identifiers, each
# `"` doubled, so upper case and keywords (user, table) stay the name itself.
crdb_list() {
  local d dq='"' list=""
  for d in "$@"; do list+="${list:+,}${dq}${d//$dq/$dq$dq}${dq}"; done
  printf '%s' "$list"
}
crdb_dump() {
  local dbs=("${DBS[@]}")
  [ "${#dbs[@]}" -gt 0 ] || mapfile -d '' -t dbs < <(crdb_names "SELECT encode(database_name::BYTES, 'hex') FROM [SHOW DATABASES] WHERE database_name NOT IN ('system','defaultdb','postgres')")
  [ "${#dbs[@]}" -gt 0 ] || die "cockroach has no user database to back up"
  crdb_sql "BACKUP DATABASE $(crdb_list "${dbs[@]}") INTO 'nodelocal://1/engine-backup/${STAMP}'" >/dev/null
  docker exec "$C" tar -C /cockroach/cockroach-data/extern/engine-backup -cf - "$STAMP" >"$FILE"
  docker exec "$C" rm -rf "/cockroach/cockroach-data/extern/engine-backup/${STAMP}"
}
crdb_restore() {
  local id dbs=("${DBS[@]}")
  id=$(archive_id cockroach '.*')
  docker exec -i "$C" sh -c 'mkdir -p /cockroach/cockroach-data/extern/engine-backup && tar -C /cockroach/cockroach-data/extern/engine-backup -xf -' <"$FILE"
  local where="'nodelocal://1/engine-backup/${id}'" rc=0
  if [ "$DRY" = 1 ]; then
    crdb_sql "SHOW BACKUP FROM LATEST IN ${where}" >/dev/null || rc=$?
  else
    [ "${#dbs[@]}" -gt 0 ] || mapfile -d '' -t dbs < <(crdb_names "SELECT DISTINCT encode(object_name::BYTES, 'hex') FROM [SHOW BACKUP FROM LATEST IN ${where}] WHERE object_type = 'database'")
    crdb_sql "RESTORE DATABASE $(crdb_list "${dbs[@]}") FROM LATEST IN ${where}" >/dev/null || rc=$?
  fi
  docker exec "$C" rm -rf "/cockroach/cockroach-data/extern/engine-backup/${id}"
  return "$rc"
}

# ── mssql ─────────────────────────────────────────────────────────────────────
MSSQL_DIR=/var/opt/mssql/engine-backup
MSSQL_BAK_TAIL='([^/]+/)*([^/]*[.]bak)?'
# mssql_sql SQL: run SQL as sa inside the container. -x stops sqlcmd rewriting
# $(VAR) in it first (the container's env included), so a name stays text; -r0
# sends SQL errors to stderr, not into the stdout a caller parses or drops.
mssql_sql() {
  docker exec "$C" sh -c '/opt/mssql-tools18/bin/sqlcmd -x -r0 -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -No -b -h -1 -W -Q "$1"' _ "$1"
}
# sql_ident NAME: NAME as a bracketed T-SQL identifier, `]` doubled, as QUOTENAME(NAME).
sql_ident() {
  local rb="]"
  printf '[%s]' "${1//$rb/$rb$rb}"
}
# sql_lit TEXT: TEXT as an N'...' T-SQL literal, `'` doubled, as N + QUOTENAME(TEXT, '''').
sql_lit() {
  local q="'"
  printf "N'%s'" "${1//$q/$q$q}"
}
# mssql_check NAME: die unless restore reads NAME back from its <NAME>.bak path:
# no \ (SQL Server turns it into /), no control character (tar escapes it) and
# no empty, . or .. folder part (SQL Server folds it, or writes outside <id>/).
mssql_check() {
  local re='(^|/)[.]{0,2}/'
  [[ "$1" != *[\\[:cntrl:]]* && ! "$1" =~ $re ]] ||
    die "mssql: refusing database name '$1': restore cannot read it back from its .bak path"
}
mssql_dump() {
  local dbs=("${DBS[@]}") d
  [ "${#dbs[@]}" -gt 0 ] || mapfile -t dbs < <(mssql_sql "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id > 4" | sed '/^\s*$/d')
  [ "${#dbs[@]}" -gt 0 ] || die "mssql has no user database to back up"
  for d in "${dbs[@]}"; do mssql_check "$d"; done
  docker exec "$C" mkdir -p "${MSSQL_DIR}/${STAMP}"
  for d in "${dbs[@]}"; do
    mssql_sql "BACKUP DATABASE $(sql_ident "$d") TO DISK = $(sql_lit "${MSSQL_DIR}/${STAMP}/${d}.bak") WITH COPY_ONLY, INIT, FORMAT" >/dev/null
  done
  docker exec "$C" tar -C "$MSSQL_DIR" -cf - "$STAMP" >"$FILE"
  docker exec "$C" rm -rf "${MSSQL_DIR:?}/${STAMP}"
}
# mssql_refuse_system NAME: die when NAME is master, model, msdb or tempdb in
# any case, trailing spaces ignored as SQL Server compares names: restore only
# ever replaces user databases, whatever an archive calls its members.
mssql_refuse_system() {
  local n="${1,,}"
  n="${n%"${n##*[! ]}"}"
  case "$n" in master | model | msdb | tempdb) die "mssql: refusing to restore system database '$1'; nothing unpacked" ;; esac
}
mssql_restore() {
  local id bak d rc=0 dbs=("${DBS[@]}")
  local guard="THROW 50000, N'engine-backup: refusing to restore over a system database', 1;"
  id=$(archive_id mssql "$MSSQL_BAK_TAIL")
  [ "${#dbs[@]}" -gt 0 ] || mapfile -t dbs < <(tar -tf "$FILE" | sed -n 's|^[^/]*/\(.*\)\.bak$|\1|p')
  for d in "${dbs[@]}"; do mssql_refuse_system "$d"; done
  docker exec -i "$C" sh -c "mkdir -p '${MSSQL_DIR}' && tar -C '${MSSQL_DIR}' -xf -" <"$FILE"
  for d in "${dbs[@]}"; do
    bak=$(sql_lit "${MSSQL_DIR}/${id}/${d}.bak")
    if [ "$DRY" = 1 ]; then
      mssql_sql "RESTORE VERIFYONLY FROM DISK = ${bak}" >/dev/null || rc=$?
    else
      mssql_sql "IF DB_ID($(sql_lit "$d")) <= 4 ${guard} RESTORE DATABASE $(sql_ident "$d") FROM DISK = ${bak} WITH REPLACE" >/dev/null || rc=$?
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
