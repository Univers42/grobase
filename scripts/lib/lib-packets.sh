# shellcheck shell=sh
# lib-packets.sh — the MANIFEST.json packet block: one {artifact, sha256, bytes,
#   format, target, mode} object per captured engine, so a manifest says what a restore
#   would replay instead of only which engines ran. Shared by scripts/ops/vault-seed.sh and
#   the future scripts/ops/grobase-import.sh. Sets no shell options, runs nothing.
# The engine -> artifact names MUST stay equal to vault-restore.sh's dump_for (and its
#   mssql/dynamodb file names): restore resolves every dump by those fixed names.

# packet_artifact ENGINE — the captured file name for ENGINE. An unknown engine prints
# nothing and returns 1: a caller that guessed would write a packet for a file no restore
# opens, which is the exact half-capture this name list exists to prevent.
packet_artifact() {
  case "$1" in
  postgres) printf 'postgres-all.sql.gz\n' ;;
  mysql) printf 'mysql-all.sql.gz\n' ;;
  mongo) printf 'mongo.archive.gz\n' ;;
  minio) printf 'minio.tar.gz\n' ;;
  redis) printf 'redis.rdb\n' ;;
  mssql) printf 'mssql-all.tar.gz\n' ;;
  dynamodb) printf 'dynamodb-all.tar.gz\n' ;;
  *) return 1 ;;
  esac
}

# packet_format ENGINE — how the artefact was produced, so an importer can pick a loader
# without sniffing a magic byte. Same unknown-engine contract as packet_artifact.
packet_format() {
  case "$1" in
  postgres) printf 'pg_dumpall_sql_gz\n' ;;
  mysql) printf 'mysqldump_sql_gz\n' ;;
  mongo) printf 'mongodump_archive_gz\n' ;;
  minio) printf 'tar_gz\n' ;;
  redis) printf 'rdb\n' ;;
  mssql) printf 'mssql_bak_tar_gz\n' ;;
  dynamodb) printf 'dynamodb_json_tar_gz\n' ;;
  *) return 1 ;;
  esac
}

# packets_json DIR ENGINE... — the JSON array of packet objects for ENGINE..., in the order
# given, indented to nest under a 2-space key. FAIL CLOSED: every object is built before
# anything is printed, so one unknown engine or one missing dump yields a stderr line and
# empty stdout rather than a manifest that describes a file nobody wrote.
packets_json() {
  _pj_dir="$1"
  shift
  if [ "$#" -eq 0 ]; then
    printf '[]\n'
    return 0
  fi
  _pj_body=""
  # The separator carries the newline with it: one packet per line is what makes the
  # block readable as a diff between two seed sets, and JSON wants a comma either way.
  _pj_sep=""
  for _pj_eng in "$@"; do
    if ! _pj_file="$(packet_artifact "$_pj_eng")"; then
      printf 'lib-packets: unknown engine %s: no artifact name for it\n' "$_pj_eng" >&2
      return 1
    fi
    if [ ! -f "$_pj_dir/$_pj_file" ]; then
      printf 'lib-packets: %s: expected %s in %s\n' "$_pj_eng" "$_pj_file" "$_pj_dir" >&2
      return 1
    fi
    _pj_fmt="$(packet_format "$_pj_eng")"
    _pj_sum="$(sha256sum "$_pj_dir/$_pj_file" | cut -d' ' -f1)"
    _pj_bytes="$(wc -c <"$_pj_dir/$_pj_file" | tr -d ' ')"
    _pj_body="${_pj_body}${_pj_sep}    {\"id\": \"${_pj_eng}\", \"engine\": \"${_pj_eng}\", \"artifact\": \"${_pj_file}\", \"sha256\": \"${_pj_sum}\", \"bytes\": ${_pj_bytes}, \"format\": \"${_pj_fmt}\", \"target\": {\"database\": \"*\"}, \"mode\": \"replace\", \"depends_on\": []}"
    _pj_sep=",
"
  done
  printf '[\n%s\n  ]\n' "$_pj_body"
}
