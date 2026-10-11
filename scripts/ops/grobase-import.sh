#!/usr/bin/env bash
# grobase-import.sh — operator CLI that moves a seed set into a grobase data center:
# a seed set is what scripts/ops/vault-seed.sh captured (engine dumps + MANIFEST.json
# naming the engines captured and skipped). pack makes it a self-contained, checksummed
# import dir holding ONLY the captured dumps. Nothing here opens a database or container.
#
#   pack SEED_DIR [--id ID] [--force]   stage the import dir, then move it into place
#   verify ID                           re-checksum every packet, record its state
#   status ID                           one JSON object describing the import dir
#   push ID [--dest DEST] [--dry-run]   verify ID here, then rsync the import to DEST/<id>
#   apply ID [--confirm] [--force]      replay ID into this daemon's engines (grobase-import-apply.sh)
#   rollback ID [--confirm]             put the volumes back from apply's snapshot (…-rollback.sh)
#
# Exit codes: 0 ok · 1 a step failed · 2 refused before any change, or a usage error ·
# 3 (apply) restored, but postgres row counts differ.
#
# Layout, one dir per id under IMPORT_ROOT (default $XDG_STATE_HOME/grobase/import):
#   <id>/manifest.json   <id>/packets.sha256   <id>/state/<packet id>   <id>/<artifact>
set -euo pipefail

IMPORT_ROOT="${IMPORT_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/grobase/import}"
STAGING=""
IMPORT_DIR=""

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# refuse — exit 2 promises that nothing was changed, so a caller can retry or look.
refuse() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

note() { printf '[grobase-import] %s\n' "$*" >&2; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not on PATH"; }

# WHY: the engine -> artifact -> sha256 contract has exactly one source, so an import dir
# can never describe a dump vault-seed.sh would not have written, or under another name.
# shellcheck source=scripts/lib/lib-import-push.sh
. "$(CDPATH='' cd -- "$(dirname -- "$0")/../lib" && pwd)/lib-import-push.sh"

# shellcheck source=scripts/lib/lib-import-pack.sh
. "$(CDPATH='' cd -- "$(dirname -- "$0")/../lib" && pwd)/lib-import-pack.sh"

. "$(CDPATH='' cd -- "$(dirname -- "$0")/../lib" && pwd)/lib-packets.sh"

# cleanup — the staging dir is a sibling of the real one, so an interrupted pack can be
# swept without ever touching an import dir another verb may be reading.
cleanup() {
  if [ -n "${STAGING}" ] && [ -d "${STAGING}" ]; then rm -rf "${STAGING}"; fi
}

usage() {
  cat <<'EOF'
usage: grobase-import.sh pack SEED_DIR [--id ID] [--force]
       grobase-import.sh verify ID
       grobase-import.sh status ID
       grobase-import.sh push ID [--dest DEST] [--dry-run]
       grobase-import.sh apply ID [--confirm] [--force]
       grobase-import.sh rollback ID [--confirm]
       grobase-import.sh --help

pack    turn a seed set into a checksummed import dir and print its path. Only the
        artifacts the manifest lists as captured are packed. --id defaults to
        seeds-<utc timestamp>; --force replaces an existing import dir.
verify   re-checksum every packet of ID and record staged|verified_checksum|failed.
status   print one JSON object describing ID.
push     run verify ID first, then rsync the import to DEST/<id>: manifest.json,
        packets.sha256 and the packet artifacts, never state/ (the far side records
        its own state from its own verify). DEST is a local path or host:/path and
        defaults to $GROBASE_IMPORT_DEST; with neither, push refuses. --dry-run lists
        the files it would send and creates nothing.
apply   on the data center: without --confirm print the plan; with it stop every
        container, snapshot the target volumes, restore, count postgres rows, start what
        ran before. rollback puts the snapshot back. See grobase-import-apply.sh --help.

exit codes: 0 ok · 1 a step failed · 2 refused before any change, or a usage error.

Import dirs live under IMPORT_ROOT (default: $XDG_STATE_HOME/grobase/import).
EOF
}

# valid_id ID — one path segment, no traversal: the charset alone still admits "." and "..",
# which would aim the staging rm -rf at the parent of IMPORT_ROOT.
valid_id() {
  case "${1:-}" in
  '' | . | ..) return 1 ;;
  *[!A-Za-z0-9._-]*) return 1 ;;
  *) return 0 ;;
  esac
}

import_dir() { printf '%s/%s\n' "${IMPORT_ROOT%/}" "$1"; }

# open_import ID — every verb that reads an import dir goes through here, so "there is no
# such import" is one refusal with one message instead of one per call site.
open_import() {
  [ -n "${1:-}" ] || refuse "needs an import id"
  valid_id "$1" || refuse "invalid import id: $1"
  IMPORT_DIR="$(import_dir "$1")"
  [ -d "$IMPORT_DIR" ] || refuse "no import dir named $1 under ${IMPORT_ROOT%/}"
  [ -f "${IMPORT_DIR}/manifest.json" ] || refuse "${IMPORT_DIR} has no manifest.json"
  jq -e . "${IMPORT_DIR}/manifest.json" >/dev/null 2>&1 ||
    refuse "${IMPORT_DIR}/manifest.json is not valid JSON"
  packets_trusted
}

# packets_trusted — after push the manifest is input from another machine, and a packet's id
# and artifact become paths: each must be the name lib-packets.sh gives its engine.
packets_trusted() {
  local pid engine artifact
  while IFS=$'\t' read -r pid engine artifact; do
    if ! valid_id "$pid" || [ "$artifact" != "$(packet_artifact "$engine")" ]; then
      refuse "manifest packet '${pid}' (engine '${engine}', artifact '${artifact}') is not a name lib-packets.sh produces"
    fi
  done < <(jq -r '.packets[]? | [.id, .engine, .artifact] | @tsv' "${IMPORT_DIR}/manifest.json")
}

# never leave its neighbours looking untouched.
check_packet() {
  local dir="$1" pid="$2" artifact="$3" want="$4" got
  if [ ! -f "${dir}/${artifact}" ]; then
    note "${pid}: missing"
  else
    got="$(sha256sum "${dir}/${artifact}" | cut -d' ' -f1)"
    if [ "$got" = "$want" ]; then
      printf 'verified_checksum\n' >"${dir}/state/${pid}"
      return 0
    fi
    note "${pid}: sha256 mismatch"
  fi
  printf 'failed\n' >"${dir}/state/${pid}"
  return 1
}

cmd_verify() {
  local pid engine artifact want failed=0
  [ "$#" -eq 1 ] || refuse "verify takes exactly one import id"
  open_import "$1"
  mkdir -p "${IMPORT_DIR}/state"
  while IFS=$'\t' read -r pid engine artifact want; do
    check_packet "$IMPORT_DIR" "$pid" "$artifact" "$want" || failed=1
  done < <(jq -r '.packets[]? | [.id, .engine, .artifact, .sha256] | @tsv' "${IMPORT_DIR}/manifest.json")
  if [ "$failed" -ne 0 ]; then
    note "at least one packet failed — nothing was applied"
    exit 2
  fi
  note "every packet verified_checksum"
}

# status_row — one jq-built object per packet; the state word is the file's own content so
# status reports what verify actually recorded, never what it assumed.
status_row() {
  local pid="$1" engine="$2" artifact="$3" state="unknown"
  if [ -f "${IMPORT_DIR}/state/${pid}" ]; then
    state="$(cat "${IMPORT_DIR}/state/${pid}")"
  fi
  jq -cn --arg id "$pid" --arg engine "$engine" --arg artifact "$artifact" --arg state "$state" \
    '{id: $id, engine: $engine, artifact: $artifact, state: $state}'
}

cmd_status() {
  local pid engine artifact
  local -a rows=()
  [ "$#" -eq 1 ] || refuse "status takes exactly one import id"
  open_import "$1"
  while IFS=$'\t' read -r pid engine artifact; do
    rows+=("$(status_row "$pid" "$engine" "$artifact")")
  done < <(jq -r '.packets[]? | [.id, .engine, .artifact] | @tsv' "${IMPORT_DIR}/manifest.json")
  if [ "${#rows[@]}" -eq 0 ]; then
    jq -n --arg import_id "$1" '{import_id: $import_id, packets: []}'
    return 0
  fi
  printf '%s\n' "${rows[@]}" | jq -s --arg import_id "$1" '{import_id: $import_id, packets: .}'
}

main() {
  need jq
  need sha256sum
  trap cleanup EXIT
  case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  pack)
    shift
    cmd_pack "$@"
    ;;
  verify)
    shift
    cmd_verify "$@"
    ;;
  status)
    shift
    cmd_status "$@"
    ;;
  push)
    shift
    cmd_push "$@"
    ;;
  apply)
    exec bash "$(dirname -- "$0")/grobase-import-apply.sh" "$@"
    ;;
  rollback)
    exec bash "$(dirname -- "$0")/grobase-import-rollback.sh" "$@"
    ;;
  *)
    usage >&2
    exit 2
    ;;
  esac
}

main "$@"
