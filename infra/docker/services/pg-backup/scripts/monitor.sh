#!/bin/bash
# Optional completion monitoring. Verify uploaded bytes before publishing success.
# Metadata contains only artifact names, timestamps and checksums, never credentials.
set -euo pipefail

monitor_on() { [[ "${PG_BACKUP_MONITOR:-0}" = 1 ]]; }

# Monitored jobs cannot silently succeed when retention failed.
retention_failed() {
  echo '[pg-backup] retention failed' >&2
  monitor_on && return 1
  return 0
}

# Copy every artifact back from object storage and require identical bytes.
verify_upload() {
  local file="$1" key="$2" downloaded
  monitor_on || return 0
  downloaded="$(mktemp)"
  if ! mc cp "$key" "$downloaded" >/dev/null || ! cmp -s "$file" "$downloaded"; then
    rm -f "$downloaded"
    echo '[pg-backup] uploaded artifact failed integrity verification' >&2
    return 1
  fi
  rm -f "$downloaded"
  sha256sum "$file" | sed "s#  .*#  $(basename "$file")#" >"${file}.sha256"
  mc cp "${file}.sha256" "${key}.sha256" >/dev/null
}

# Publish success only after all artifacts and retention operations completed.
monitor_complete() {
  local marker
  monitor_on || return 0
  marker="$(mktemp)"
  date -u +%s >"$marker"
  mc cp "$marker" "baas/${PG_BACKUP_BUCKET}/${PG_BACKUP_PREFIX}/monitor/last-success" >/dev/null || { rm -f "$marker"; return 1; }
  rm -f "$marker"
}

# No previous backup, a failed read, future timestamp or stale backup is unhealthy.
monitor_fresh() {
  local at now maximum
  maximum="${PG_BACKUP_MAX_AGE_SECONDS:-172800}"
  [[ "$maximum" =~ ^[1-9][0-9]{0,8}$ ]] || return 1
  at="$(timeout 3 mc cat "baas/${PG_BACKUP_BUCKET:-backups}/${PG_BACKUP_PREFIX:-postgres}/monitor/last-success")" || return 1
  [[ "$at" =~ ^[1-9][0-9]{0,10}$ ]] || return 1
  now="$(date -u +%s)"
  (( at <= now && now - at <= maximum ))
}

# Monitored restore verifies encrypted bytes before decrypting the archive.
verify_download() {
  local file="$1" key="$2" checksum expected actual
  monitor_on || return 0
  checksum="$(timeout 10 mc cat "${key}.sha256")" || return 1
  expected="${checksum%% *}"
  [[ "$expected" =~ ^[a-f0-9]{64}$ ]] || return 1
  actual="$(sha256sum "$file")"
  [[ "${actual%% *}" = "$expected" ]]
}
