#!/usr/bin/env bash
# grobase-import-rebind.sh — derive an import whose tenant mounts work on another grobase.
#
#   grobase-import-rebind.sh SRC_ID NEW_ID [--target-ssh HOST] [--source-env FILE] [--force]
#
# A seed's public.tenant_databases rows hold DSNs encrypted under the SOURCE VAULT_ENC_KEY,
# and the ones on platform engines carry the SOURCE engine passwords. Restored as they are,
# the target can open none of them. This copies SRC_ID to NEW_ID (hard links), rewrites only
# postgres-all.sql.gz through cmd/mount-rebind (the control plane's own Encryptor), and
# records derived_from plus the per-row outcome in NEW_ID's manifest.
#
# The target logins and key are read from the target's RUNNING containers (docker inspect,
# over `ssh HOST` when --target-ssh is given), because those are what will open the mounts.
# Every secret travels in a pipe: never argv, never a file, never printed. The source key
# is VAULT_ENC_KEY in --source-env (default: this checkout's .env).
#
# Exit codes: 0 derived · 1 a step failed (NEW_ID not created) · 2 refused, nothing written.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GROBASE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
IMPORT_CLI="${SCRIPT_DIR}/grobase-import.sh"
IMPORT_ROOT="${IMPORT_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/grobase/import}"
GO_IMAGE="${GO_IMAGE:-golang:1.26-bookworm}"
STAGING=""

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}
refuse() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}
note() { printf '[grobase-import-rebind] %s\n' "$*" >&2; }
cleanup() { [ -z "$STAGING" ] || rm -rf "$STAGING"; }
trap cleanup EXIT

# target_docker ARGS… — docker on the target; ssh carries no port forwards (the b2b alias
# defines some that collide with a running link) and the remote shell sees quoted args.
target_docker() {
  if [ -n "$TARGET_SSH" ]; then
    ssh -o ClearAllForwardings=yes -o LogLevel=ERROR "$TARGET_SSH" "docker $(printf '%q ' "$@")"
  else
    docker "$@"
  fi
}

# Ponytail: the redis password is read from a `--requirepass` argument only; one set in a
# mounted redis.conf is missed, the DSN is rebound without a password, and the mount fails
# AUTH — the data-plane probe after apply is what catches it.
# config_program — jq over `docker inspect` of every running target container → the
# mount-rebind config line. Refuses unless exactly one VAULT_ENC_KEY is in use there.
config_program() {
  cat <<'JQ'
def env($c): (map(select(.Name == "/" + $c)) | .[0].Config.Env // [])
  | map(capture("^(?<key>[^=]+)=(?<value>.*)$")) | from_entries;
def running($c): any(.[]; .Name == "/" + $c);
def target($e; $s; $h; $p; $u; $pw): {engine: $e, schemes: $s, hosts: $h, port: $p, user: $u, password: $pw};
def srckey: $srcenv | split("\n") | map(select(startswith("VAULT_ENC_KEY="))) | (.[0] // "")
  | sub("^VAULT_ENC_KEY="; "") | sub("^[\"']|[\"']$"; ""; "g");
([.[].Config.Env // [] | .[] | select(startswith("VAULT_ENC_KEY="))] | unique) as $keys
| if ($keys | length) != 1 then error("target: \($keys | length) distinct VAULT_ENC_KEY values in running containers; need exactly 1") else . end
| if srckey == "" then error("source env file has no VAULT_ENC_KEY") else . end
| . as $all
| (map(select(.Name == "/mini-baas-redis")) | .[0].Args // []) as $ra
| {source_key: srckey, target_key: ($keys[0] | sub("^VAULT_ENC_KEY="; "")),
   targets: [
    (env("mini-baas-postgres") | select(.POSTGRES_PASSWORD) | target("postgresql"; ["postgres", "postgresql"]; ["postgres", "mini-baas-postgres"]; 5432; .POSTGRES_USER // "postgres"; .POSTGRES_PASSWORD)),
    (env("mini-baas-mysql") | select(.MYSQL_PASSWORD) | target("mysql"; ["mysql", "mariadb"]; ["mysql", "mini-baas-mysql"]; 3306; .MYSQL_USER; .MYSQL_PASSWORD)),
    (env("mini-baas-mongo") | select(.MONGO_INITDB_ROOT_PASSWORD) | target("mongodb"; ["mongodb"]; ["mongo", "mini-baas-mongo"]; 27017; .MONGO_INITDB_ROOT_USERNAME; .MONGO_INITDB_ROOT_PASSWORD)),
    (env("mini-baas-mssql") | select(.MSSQL_SA_PASSWORD // .SA_PASSWORD) | target("mssql"; ["mssql", "sqlserver"]; ["mssql", "mini-baas-mssql"]; 1433; "sa"; .MSSQL_SA_PASSWORD // .SA_PASSWORD)),
    ($all | select(running("mini-baas-redis")) | ($ra | index(["--requirepass"])) as $i
      | target("redis"; ["redis"]; ["redis", "mini-baas-redis"]; 6379; ""; (if $i then $ra[$i + 1] else "" end)))
  ]}
JQ
}

# target_config — jq's stderr is filtered to this script's own error() texts: a jq type
# error quotes the offending value, and here every value is a secret.
target_config() {
  local -a ids
  mapfile -t ids < <(target_docker ps -q) || die "cannot reach docker on the target${TARGET_SSH:+ (ssh ${TARGET_SSH})}"
  [ "${#ids[@]}" -gt 0 ] || refuse "no running container on the target"
  target_docker inspect "${ids[@]}" |
    jq -c --rawfile srcenv "$SOURCE_ENV" "$(config_program)" 2> >(grep -oE '(target|source env)[^"]*' >&2) ||
    refuse "cannot build the rebind config from the target's running containers"
}

# mount_rebind — build and run cmd/mount-rebind in the Go toolchain image; stdin and
# stdout pass straight through, and `exec` keeps its exit status.
mount_rebind() {
  docker run -i --rm -v "${GROBASE_ROOT}/src/control-plane:/src:ro" -w /src \
    -v mini-baas-gomod:/go/pkg/mod -v mini-baas-gobuild:/root/.cache/go-build -e CGO_ENABLED=0 \
    "$GO_IMAGE" sh -c 'go build -o /tmp/mount-rebind ./cmd/mount-rebind >&2 && exec /tmp/mount-rebind'
}

parse_args() {
  TARGET_SSH=""
  SOURCE_ENV="${GROBASE_ROOT}/.env"
  FORCE=0
  [ "$#" -ge 2 ] || refuse "usage: $(basename "$0") SRC_ID NEW_ID [--target-ssh HOST] [--source-env FILE] [--force]"
  SRC_ID="$1" NEW_ID="$2"
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --target-ssh) TARGET_SSH="${2:?--target-ssh needs a host}" && shift 2 ;;
    --source-env) SOURCE_ENV="${2:?--source-env needs a file}" && shift 2 ;;
    --force) FORCE=1 && shift ;;
    *) refuse "unknown argument: $1" ;;
    esac
  done
  case "$NEW_ID" in '' | . | .. | *[!A-Za-z0-9._-]*) refuse "invalid import id: ${NEW_ID}" ;; esac
  [ -r "$SOURCE_ENV" ] || refuse "source env ${SOURCE_ENV} is not readable"
}

# stage_copy SRC DEST — every artifact by hard link except the one that gets rewritten.
stage_copy() {
  local f
  for f in "$1"/*; do
    [ -f "$f" ] || continue
    case "${f##*/}" in postgres-all.sql.gz | manifest.json | packets.sha256) continue ;; esac
    ln "$f" "$2/" 2>/dev/null || cp -p "$f" "$2/"
  done
}

# rewrite_manifest SRC_DIR — new id, the rewritten artifact's sha256 and size, derived_from
# and the rebind report; packets.sha256 is regenerated from the manifest it must agree with.
rewrite_manifest() {
  local sum bytes
  sum="$(sha256sum "${STAGING}/postgres-all.sql.gz" | cut -d' ' -f1)"
  bytes="$(stat -c %s "${STAGING}/postgres-all.sql.gz")"
  jq --arg id "$NEW_ID" --arg src "$SRC_ID" --arg sum "$sum" --argjson bytes "$bytes" \
    --slurpfile report "${STAGING}/.report.json" \
    '.import_id = $id | .derived_from = $src | .rebind = $report[0]
     | .packets |= map(if .engine == "postgres" then .sha256 = $sum | .bytes = $bytes else . end)' \
    "${1}/manifest.json" >"${STAGING}/manifest.json"
  jq -r '.packets[] | "\(.sha256)  \(.artifact)"' "${STAGING}/manifest.json" >"${STAGING}/packets.sha256"
}

run_rebind() {
  local config src_dir="${IMPORT_ROOT%/}/${SRC_ID}"
  config="$(target_config)"
  {
    printf '%s\n' "$config"
    gzip -dc "${src_dir}/postgres-all.sql.gz"
  } |
    mount_rebind 2>"${STAGING}/.rebind.log" | gzip -n >"${STAGING}/postgres-all.sql.gz" ||
    die "mount-rebind failed: $(grep -v '^{' "${STAGING}/.rebind.log" | tail -3)"
  grep '^{' "${STAGING}/.rebind.log" | tail -1 >"${STAGING}/.report.json"
  rewrite_manifest "$src_dir"
  rm -f "${STAGING}/.rebind.log" "${STAGING}/.report.json"
}

main() {
  parse_args "$@"
  bash "$IMPORT_CLI" verify "$SRC_ID"
  local dest="${IMPORT_ROOT%/}/${NEW_ID}"
  [ ! -e "$dest" ] || [ "$FORCE" = 1 ] || refuse "${dest} exists (--force replaces it)"
  STAGING="${IMPORT_ROOT%/}/.${NEW_ID}.tmp"
  rm -rf "$STAGING"
  mkdir -m 0700 "$STAGING"
  stage_copy "${IMPORT_ROOT%/}/${SRC_ID}" "$STAGING"
  run_rebind
  rm -rf "$dest"
  mv "$STAGING" "$dest"
  STAGING=""
  bash "$IMPORT_CLI" verify "$NEW_ID"
  jq -r '.rebind.rows[]? | [.id, .engine, .outcome] | @tsv' "${dest}/manifest.json" >&2
  printf '%s\n' "$dest"
}

main "$@"
