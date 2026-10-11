#!/usr/bin/env bash
#
# lib-import-push.sh — push function definitions for grobase-import.sh
# This file is sourced by scripts/ops/grobase-import.sh and defines only functions;
# it sets no shell options.
# Relies on (caller helpers from grobase-import.sh): die, note, need, valid_id, import_dir,
# open_import, packets_trusted, check_packet, IMPORT_ROOT, GROBASE_IMPORT_DEST
#

parse_push_args() {
  PUSH_ID=""
  PUSH_DEST=""
  PUSH_DRY=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --dest)
      [ "$#" -ge 2 ] || refuse "--dest needs a value"
      PUSH_DEST="$2"
      shift 2
      ;;
    --dry-run)
      PUSH_DRY=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) refuse "unknown option: $1" ;;
    *)
      [ -z "${PUSH_ID}" ] || refuse "push takes one import id"
      PUSH_ID="$1"
      shift
      ;;
    esac
  done
  [ -n "${PUSH_ID}" ] || refuse "push needs an import id"
}

push_dest() {
  PUSH_DEST="${1:-${GROBASE_IMPORT_DEST:-}}"
  [ -n "${PUSH_DEST}" ] ||
    refuse "no destination: pass --dest DEST or set GROBASE_IMPORT_DEST (e.g. b2b:/var/lib/grobase-import)"
  PUSH_DEST="${PUSH_DEST%/}"
  [ -n "${PUSH_DEST}" ] ||
    refuse "/ is not a destination root — name the directory that will hold the import dir"
}

push_files() {
  printf '%s/%s\n' "${PUSH_ID}" "manifest.json"
  printf '%s/%s\n' "${PUSH_ID}" "packets.sha256"
  jq -r --arg id "${PUSH_ID}" '.packets[]? | "\($id)/\(.artifact)"' "${IMPORT_DIR}/manifest.json"
}

rsync_push() {
  local -a args=(-R --files-from=- --mkpath --partial "--chmod=D700,F600")
  if [ "${PUSH_DRY}" -eq 1 ]; then
    args+=(-n)
  fi
  push_files | rsync "${args[@]}" -- "${IMPORT_ROOT%/}/" "${PUSH_DEST}/"
}

push_dry_notes() {
  local name
  while IFS= read -r name; do note "would send ${name}"; done < <(push_files)
}

cmd_push() {
  parse_push_args "$@"
  need rsync
  push_dest "${PUSH_DEST}"
  cmd_verify "${PUSH_ID}"
  if [ "${PUSH_DRY}" -eq 1 ]; then
    push_dry_notes
    rsync_push || exit 1
    note "dry run — nothing was sent"
  else
    rsync_push || exit 1
    note "pushed ${PUSH_ID} to ${PUSH_DEST}"
  fi
  printf '%s\n' "${PUSH_DEST}/${PUSH_ID}"
}
