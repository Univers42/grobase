#!/bin/bash
# At-rest encryption for the pg-backup scripts, which source this file.
#
# BACKUP_AGE_RECIPIENTS (age public keys, comma or space separated) turns it on:
# every artifact is encrypted to all of them before it is uploaded, and gets a
# .age suffix. Unset keeps today's plaintext artifacts. A restore of a .age
# artifact reads BACKUP_AGE_IDENTITY_FILE, which only a one-off restore run
# holds; the backup service refuses to start with it (entrypoint.sh).

# age_on succeeds when backups must be encrypted.
age_on() { [ -n "${BACKUP_AGE_RECIPIENTS:-}" ]; }

# age_encrypt runs `age -e` to every recipient; the remaining arguments pass
# through (default: stdin to stdout).
age_encrypt() {
  local list r args=()
  IFS=', ' read -r -a list <<<"${BACKUP_AGE_RECIPIENTS:-}"
  for r in "${list[@]}"; do [ -z "$r" ] || args+=(-r "$r"); done
  [ "${#args[@]}" -gt 0 ] || {
    echo "[age] BACKUP_AGE_RECIPIENTS names no recipient" >&2
    return 1
  }
  age -e "${args[@]}" "$@"
}

# age_ready fails, naming why, unless age is installed and accepts every
# recipient. Run it before a dump, so a bad key fails before anything is written.
age_ready() {
  command -v age >/dev/null || {
    echo "[age] BACKUP_AGE_RECIPIENTS is set but age is not installed: refusing to write a plaintext backup" >&2
    return 1
  }
  age_encrypt </dev/null >/dev/null || {
    echo "[age] age refuses a recipient in BACKUP_AGE_RECIPIENTS: no backup written" >&2
    return 1
  }
}

# age_decrypt runs `age -d` with BACKUP_AGE_IDENTITY_FILE; the remaining
# arguments pass through. Refuses, by name, without a readable identity.
age_decrypt() {
  [ -n "${BACKUP_AGE_IDENTITY_FILE:-}" ] && [ -r "${BACKUP_AGE_IDENTITY_FILE}" ] || {
    echo "[age] an encrypted artifact needs BACKUP_AGE_IDENTITY_FILE (a readable age identity file) to restore" >&2
    return 1
  }
  age -d -i "${BACKUP_AGE_IDENTITY_FILE}" "$@"
}

# age_seal FILE replaces FILE with FILE.age, encrypted.
age_seal() { age_encrypt -o "$1.age" "$1" && rm -f "$1"; }

# age_open FILE.age replaces FILE.age with FILE, decrypted.
age_open() { age_decrypt -o "${1%.age}" "$1" && rm -f "$1"; }

# age_open_all DIR decrypts every *.age file directly in DIR in place.
age_open_all() {
  local f
  for f in "$1"/*.age; do
    [ -e "$f" ] || continue
    age_open "$f" || return 1
  done
}
