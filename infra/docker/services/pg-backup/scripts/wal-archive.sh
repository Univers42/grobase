#!/bin/bash
# Ship ONE write-ahead-log segment to the artifact store. Postgres invokes this
# as its `archive_command` (one process per completed WAL file):
#
#   archive_command = '/opt/pg-backup/wal-archive.sh %p %f'
#     %p = full path of the segment on the primary  (e.g. pg_wal/0000000100000000000000A3)
#     %f = bare segment file name                   (e.g. 0000000100000000000000A3)
#
# Postgres requires archive_command to exit 0 ONLY when the segment is safely
# stored; a non-zero exit makes postgres retry the SAME segment, so we must never
# report success on a failed upload (that would silently break PITR continuity).
#
# This is the WAL half of PITR (C4b): base backups come from run-backup.sh
# (PG_BACKUP_PHYSICAL=1), the WAL stream comes from here, and pitr-restore.sh
# replays a base + the WAL up to a target time. ALL of it is gated by
# PG_BACKUP_PITR — when unset this script is never wired into postgres at all, so
# the live baseline (whole-cluster logical pg_dump) is byte-identical.
set -euo pipefail

SRC_PATH="${1:?usage: wal-archive.sh <%p source-path> <%f segment-name>}"
SEG_NAME="${2:?usage: wal-archive.sh <%p source-path> <%f segment-name>}"

: "${PG_BACKUP_BUCKET:?required}"
: "${PG_BACKUP_PREFIX:?required}"

# Reject a path-traversal segment name: postgres only ever passes a flat WAL
# segment / history file name, never a path. Refusing '/' keeps the object key
# pinned under the wal/ prefix.
case "${SEG_NAME}" in
*/* | ..)
  echo "[wal-archive] refusing suspicious segment name '${SEG_NAME}'" >&2
  exit 1
  ;;
esac

DEST_KEY="baas/${PG_BACKUP_BUCKET}/${PG_BACKUP_PREFIX}/wal/${SEG_NAME}"

# mc must already be aliased (the loop/once entrypoint does mc_alias once); when
# postgres spawns this directly the alias config is inherited via MC_CONFIG_DIR /
# the per-archive entrypoint. Re-alias defensively (cheap, idempotent) so a bare
# `archive_command` invocation that did not inherit the alias still works.
if [ -n "${MINIO_ENDPOINT:-}" ]; then
  mc alias set baas "${MINIO_ENDPOINT}" \
    "${MINIO_ROOT_USER:-minioadmin}" "${MINIO_ROOT_PASSWORD:-minioadmin}" >/dev/null 2>&1 || true
fi

# Idempotent: if the segment is already stored (postgres retried a previously
# succeeded archive after a crash), treat it as success — re-uploading identical
# WAL is harmless and postgres must not loop.
if mc stat "${DEST_KEY}" >/dev/null 2>&1; then
  echo "[wal-archive] ${SEG_NAME} already stored — ok"
  exit 0
fi

# `mc cp` is atomic per-object on MinIO; only exit 0 once it returns success so
# postgres never advances past an un-stored segment.
if mc cp "${SRC_PATH}" "${DEST_KEY}" >/dev/null 2>&1; then
  echo "[wal-archive] archived ${SEG_NAME} -> ${DEST_KEY}"
  exit 0
fi

echo "[wal-archive] FAILED to archive ${SEG_NAME} -> ${DEST_KEY}" >&2
exit 1
