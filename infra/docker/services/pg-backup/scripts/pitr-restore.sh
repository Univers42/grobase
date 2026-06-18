#!/bin/bash
# Point-in-time recovery (C4b): rebuild a FRESH postgres data directory from a
# physical base backup, then replay archived WAL up to a target timestamp.
#
# Usage: pitr-restore.sh <base-stamp> <target-time>
#   <base-stamp>   the physical base backup id, e.g. 20260601T030000Z (matches the
#                  run-backup.sh `physical/base-<stamp>/` artifact prefix). The
#                  literal "latest" picks the lexicographically newest base.
#   <target-time>  recovery_target_time, an ISO-8601 instant postgres accepts,
#                  e.g. "2026-06-01 03:14:00+00".
#
# Required env:
#   PG_BACKUP_BUCKET / PG_BACKUP_PREFIX  artifact store coordinates (MinIO source)
#   PITR_PGDATA      target data dir to materialize (must be empty; default /pitr/pgdata)
#   PITR_WAL_STAGE   where archived WAL is staged for restore_command (default /pitr/wal)
#   PITR_LOCAL_STORE optional local artifact root (MinIO-free); when set, the base
#                    + WAL are read from
#                    ${PITR_LOCAL_STORE}/${PREFIX}/physical/base-<stamp>/ and
#                    ${PITR_LOCAL_STORE}/${PREFIX}/wal/ instead of `mc`. This is the
#                    same on-disk layout run-backup.sh / wal-archive.sh write, so
#                    one code path serves both the MinIO store and a local store.
#
# This NEVER restores into a running server. It produces a recovered PGDATA you
# then start to replay WAL + promote (the gate starts a fresh postgres on it).
# Gated by PG_BACKUP_PITR; with the flag unset this path is never invoked and
# restore.sh's logical path is byte-identical to today.
set -euo pipefail

BASE_STAMP="${1:?usage: pitr-restore.sh <base-stamp|latest> <target-time>}"
TARGET_TIME="${2:?usage: pitr-restore.sh <base-stamp|latest> <target-time>}"

: "${PG_BACKUP_PREFIX:?required}"

PGDATA_DIR="${PITR_PGDATA:-/pitr/pgdata}"
WAL_STAGE="${PITR_WAL_STAGE:-/pitr/wal}"
LOCAL_STORE="${PITR_LOCAL_STORE:-}"

if [ -n "${LOCAL_STORE}" ]; then
  BASE_STORE="${LOCAL_STORE}/${PG_BACKUP_PREFIX}/physical"
  WAL_STORE="${LOCAL_STORE}/${PG_BACKUP_PREFIX}/wal"
else
  : "${PG_BACKUP_BUCKET:?required}"
  BASE_STORE="baas/${PG_BACKUP_BUCKET}/${PG_BACKUP_PREFIX}/physical"
  WAL_STORE="baas/${PG_BACKUP_BUCKET}/${PG_BACKUP_PREFIX}/wal"
fi

# Resolve "latest" to the newest base-<stamp>/ under the physical prefix.
if [ "${BASE_STAMP}" = "latest" ]; then
  if [ -n "${LOCAL_STORE}" ]; then
    BASE_STAMP="$(ls -1 "${BASE_STORE}" 2>/dev/null |
      sed -nE 's#^base-([0-9TZ]+)$#\1#p' | sort | tail -1)"
  else
    BASE_STAMP="$(mc ls "${BASE_STORE}/" 2>/dev/null |
      sed -nE 's#.*base-([0-9TZ]+)/?$#\1#p' | sort | tail -1)"
  fi
  [ -n "${BASE_STAMP}" ] || {
    echo "[pitr] no physical base backup found under ${BASE_STORE}/" >&2
    exit 1
  }
fi
BASE_KEY="${BASE_STORE}/base-${BASE_STAMP}"

echo "[pitr] target base=${BASE_STAMP} time='${TARGET_TIME}' -> PGDATA=${PGDATA_DIR}"

# Refuse a non-empty PGDATA — a half-recovered dir produces silent corruption.
if [ -d "${PGDATA_DIR}" ] && [ -n "$(ls -A "${PGDATA_DIR}" 2>/dev/null)" ]; then
  echo "[pitr] PGDATA ${PGDATA_DIR} is not empty — refusing to overwrite" >&2
  exit 1
fi
mkdir -p "${PGDATA_DIR}" "${WAL_STAGE}"

# 1) Fetch + unpack the base backup (run-backup.sh stores tar.gz members:
#    base.tar.gz holds the main data dir, pg_wal.tar.gz the WAL captured at backup
#    start). Untar base into PGDATA.
echo "[pitr] fetching base backup ${BASE_KEY}/"
TMP_BASE="$(mktemp -d)"
trap 'rm -rf "${TMP_BASE}"' EXIT
if [ -n "${LOCAL_STORE}" ]; then
  cp -a "${BASE_KEY}/." "${TMP_BASE}/"
else
  mc cp --recursive "${BASE_KEY}/" "${TMP_BASE}/" >/dev/null
fi
[ -f "${TMP_BASE}/base.tar.gz" ] || {
  echo "[pitr] base.tar.gz missing from ${BASE_KEY}/" >&2
  exit 1
}
tar -xzf "${TMP_BASE}/base.tar.gz" -C "${PGDATA_DIR}"
# pg_basebackup --format=tar emits pg_wal.tar.gz for the WAL directory; restore it
# so the startup WAL needed to reach a consistent point is present.
if [ -f "${TMP_BASE}/pg_wal.tar.gz" ]; then
  tar -xzf "${TMP_BASE}/pg_wal.tar.gz" -C "${PGDATA_DIR}/pg_wal"
fi
chmod 700 "${PGDATA_DIR}"

# 2) Stage archived WAL locally so restore_command can serve it without network
#    per-segment. (A network restore_command also works; staging keeps the gate
#    self-contained and fast.)
echo "[pitr] staging archived WAL from ${WAL_STORE}/"
if [ -n "${LOCAL_STORE}" ]; then
  cp -a "${WAL_STORE}/." "${WAL_STAGE}/" 2>/dev/null || true
else
  mc cp --recursive "${WAL_STORE}/" "${WAL_STAGE}/" >/dev/null 2>&1 || true
fi

# 3) Write the recovery configuration. PG12+ uses postgresql.auto.conf +
#    recovery.signal (NOT the legacy recovery.conf). restore_command copies the
#    requested segment from the local stage; recovery_target_time stops replay at
#    T; recovery_target_action=promote finishes recovery into a usable server;
#    recovery_target_inclusive=true replays records AT exactly T.
cat >>"${PGDATA_DIR}/postgresql.auto.conf" <<CONF
# --- pg-backup PITR (C4b) ---
restore_command = 'cp ${WAL_STAGE}/%f %p'
recovery_target_time = '${TARGET_TIME}'
recovery_target_inclusive = true
recovery_target_action = 'promote'
CONF
touch "${PGDATA_DIR}/recovery.signal"

echo "[pitr] PGDATA ${PGDATA_DIR} prepared for recovery to '${TARGET_TIME}'"
echo "[pitr] start it (pg_ctl start -D ${PGDATA_DIR}) to replay WAL and promote at the target"
