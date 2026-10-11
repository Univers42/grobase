#!/usr/bin/env bash
# grobase-import-rollback.sh — undoes grobase-import-apply.sh: with the compose project stopped,
# each target volume is emptied and refilled from apply's cold snapshot (checksummed first),
# then the containers that ran before apply are started again by their recorded id. Without --confirm it only
# names the volumes it would restore. It shares apply's helpers by sourcing that file.
#
#   rollback ID [--confirm]
#
# Exit: 0 done · 1 a step failed · 2 refused before any change (no snapshot, bad sums).
set -euo pipefail

# shellcheck source=scripts/ops/grobase-import-apply.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/grobase-import-apply.sh"

# restore_volume VOL — empty the volume, then untar its snapshot into it.
restore_volume() {
  docker run --rm -v "${1}:/v" "$SNAPSHOT_IMAGE" sh -c 'find /v -mindepth 1 -delete' ||
    die "cannot empty volume $1"
  docker run --rm -i -v "${1}:/v" "$SNAPSHOT_IMAGE" tar -xzf - -C /v <"${APPLY_DIR}/volumes/${1}.tar.gz" ||
    die "cannot untar the snapshot of $1"
}

cmd_rollback() {
  local sums="${APPLY_DIR}/volumes/SHA256SUMS" vol
  if [ ! -f "$sums" ] || [ ! -f "${APPLY_DIR}/running.before" ]; then
    refuse "${ID} has no apply snapshot"
  fi
  (cd "${APPLY_DIR}/volumes" && sha256sum -c --quiet SHA256SUMS) || refuse "snapshot checksums fail"
  [ "$CONFIRM" -eq 1 ] || {
    note "would stop ${PROJECT}, restore: $(sed 's/.*  //; s/\.tar\.gz$//' "$sums" | tr '\n' ' ')"
    return 0
  }
  project_running | cut -d' ' -f1 | xargs -r docker stop -t 30 >/dev/null || die "docker stop failed"
  while read -r vol; do
    restore_volume "$vol"
  done < <(sed 's/.*  //; s/\.tar\.gz$//' "$sums")
  packet_rows | cut -f1 | while read -r pid; do set_state "$pid" verified_checksum; done
  cut -d' ' -f1 "${APPLY_DIR}/running.before" | xargs -r docker start >/dev/null || die "docker start failed"
  note "rolled back ${ID}: volumes restored, recorded containers started"
}

main_rollback() {
  case "${1:-}" in -h | --help)
    usage
    exit 0
    ;;
  esac
  command -v docker >/dev/null 2>&1 || die "docker is required"
  parse_args "$@"
  [ "$VERB" = rollback ] || refuse "$(usage)"
  cmd_rollback
}

main_rollback "$@"
