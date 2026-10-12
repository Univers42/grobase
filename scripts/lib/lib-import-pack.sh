#!/usr/bin/env bash
#
# lib-import-pack.sh — pack function definitions for grobase-import.sh
# This file is sourced by scripts/ops/grobase-import.sh and defines only functions;
# it sets no shell options.
# Relies on (caller helpers from grobase-import.sh): die, note, valid_id, import_dir,
# packets_json, IMPORT_ROOT
#

parse_pack_args() {
  PACK_SEED=""
  PACK_ID=""
  PACK_FORCE=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --id)
      [ "$#" -ge 2 ] || refuse "--id needs a value"
      PACK_ID="$2"
      shift 2
      ;;
    --force)
      PACK_FORCE=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) refuse "unknown option: $1" ;;
    *)
      [ -z "${PACK_SEED}" ] || refuse "pack takes one SEED_DIR"
      PACK_SEED="$1"
      shift
      ;;
    esac
  done
  [ -n "${PACK_SEED}" ] || refuse "pack needs SEED_DIR"
}

seed_manifest() {
  local seed="${1%/}"
  [ -d "$seed" ] || refuse "not a directory: $seed"
  [ -f "${seed}/MANIFEST.json" ] || refuse "${seed}/MANIFEST.json is missing — not a seed set"
  jq -e . "${seed}/MANIFEST.json" >/dev/null 2>&1 ||
    refuse "${seed}/MANIFEST.json is not valid JSON"
}

prepare_dest() {
  [ -e "$1" ] || return 0
  [ "${PACK_FORCE}" -eq 1 ] || refuse "$1 already exists — pass --force to replace it"
  note "replacing $1"
  rm -rf "$1"
}

link_or_copy() {
  ln "$1" "$2" 2>/dev/null || cp -p "$1" "$2"
}

stage() {
  local seed="$1" dir="$2" packets="$3" artifact pid
  while IFS= read -r artifact; do
    link_or_copy "${seed}/${artifact}" "${dir}/${artifact}"
  done < <(printf '%s\n' "$packets" | jq -r '.[].artifact')
  printf '%s\n' "$packets" | jq -r '.[] | "\(.sha256)  \(.artifact)"' >"${dir}/packets.sha256"
  mkdir -m 0700 "${dir}/state"
  while IFS= read -r pid; do
    printf 'staged\n' >"${dir}/state/${pid}"
  done < <(printf '%s\n' "$packets" | jq -r '.[].id')
}

write_manifest() {
  jq -n --arg import_id "$3" --argjson packets "$4" --argjson seed "$(cat "$1")" '{
    created_utc: $seed.created_utc,
    source: $seed.source,
    captured: $seed.captured,
    skipped: $seed.skipped,
    manifest_version: 2,
    import_id: $import_id,
    packets: $packets
  }' >"$2/manifest.json"
}

cmd_pack() {
  local id dest packets
  local -a engines=()
  parse_pack_args "$@"
  seed_manifest "$PACK_SEED"
  id="${PACK_ID:-seeds-$(date -u +%Y%m%dT%H%M%SZ)}"
  valid_id "$id" || refuse "invalid import id: ${id}"
  dest="$(import_dir "$id")"
  mapfile -t engines < <(jq -r 'if (.captured | type) == "array" then .captured[] else empty end' "${PACK_SEED%/}/MANIFEST.json")
  [ "${#engines[@]}" -gt 0 ] || refuse "${PACK_SEED%/}/MANIFEST.json captured no engine — nothing to pack"
  packets="$(packets_json "${PACK_SEED%/}" "${engines[@]}")" ||
    refuse "cannot describe the packets of ${PACK_SEED} — a captured dump is missing"
  prepare_dest "$dest"
  mkdir -p "${IMPORT_ROOT%/}"
  STAGING="${IMPORT_ROOT%/}/.${id}.tmp"
  rm -rf "$STAGING"
  mkdir -m 0700 "$STAGING"
  stage "${PACK_SEED%/}" "$STAGING" "$packets"
  write_manifest "${PACK_SEED%/}/MANIFEST.json" "$STAGING" "$id" "$packets"
  mv "$STAGING" "$dest"
  STAGING=""
  note "packed ${#engines[@]} packet(s) into ${dest}"
  printf '%s\n' "$dest"
}
