#!/bin/bash
# Restore a backup artifact from MinIO into a local target database.
#
# Usage: restore.sh <artifact-key>
#   <artifact-key> may be:
#     - bare filename: postgres-20260601T030000Z.dump
#     - full prefix:   logical/postgres-20260601T030000Z.dump
#     - full path:     baas/backups/postgres/logical/postgres-20260601T030000Z.dump
#
# Required env:
#   DATABASE_URL          - source (used by tooling defaults)
#   RESTORE_DATABASE_URL  - target to restore INTO (NEVER point this at prod)
# An encrypted artifact (.age, see age.sh) also needs BACKUP_AGE_IDENTITY_FILE.
# Its decrypted dump is removed on exit; a decrypted physical artifact stays in
# /restore for the manual recovery. Any other artifact is refused, never "done".
set -euo pipefail
# shellcheck source=age.sh
. "$(dirname "$0")/age.sh"

: "${RESTORE_DATABASE_URL:?must point at the target DB to restore into (NOT prod)}"
KEY="${1:?artifact key required}"

# Normalize key into a full mc path.
case "$KEY" in
baas/*) FULL="$KEY" ;;
logical/* | physical/*) FULL="baas/${PG_BACKUP_BUCKET:-backups}/${PG_BACKUP_PREFIX:-postgres}/${KEY}" ;;
*) FULL="baas/${PG_BACKUP_BUCKET:-backups}/${PG_BACKUP_PREFIX:-postgres}/logical/${KEY}" ;;
esac

mkdir -p /restore
LOCAL="/restore/$(basename "$KEY")"

echo "[pg-restore] downloading ${FULL} -> ${LOCAL}"
mc cp "$FULL" "$LOCAL"

if [[ "$LOCAL" == *.age ]]; then
  echo "[pg-restore] decrypting ${LOCAL}"
  age_open "$LOCAL"
  LOCAL="${LOCAL%.age}"
  [[ "$FULL" == */physical/* ]] || trap 'rm -f "$LOCAL"' EXIT
fi

if [[ "$FULL" == */physical/* ]]; then
  echo "[pg-restore] physical artifact downloaded to ${LOCAL}"
  echo "[pg-restore] manual recovery required (stop postgres, untar into PGDATA, point at archived WAL)"
elif [[ "$LOCAL" == *.dump ]]; then
  echo "[pg-restore] applying logical dump to ${RESTORE_DATABASE_URL}"
  # --clean drops objects first; --if-exists avoids errors on first restore.
  pg_restore --no-owner --no-privileges --clean --if-exists \
    --dbname="$RESTORE_DATABASE_URL" "$LOCAL"
  echo "[pg-restore] logical restore complete"
else
  echo "[pg-restore] refusing ${FULL}: not a logical .dump, a physical/ artifact, or either one .age-encrypted" >&2
  exit 1
fi
