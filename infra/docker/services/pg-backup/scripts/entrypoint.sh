#!/bin/bash
# pg-backup container entrypoint.
#
# Modes:
#   loop                       - default; install cron, run scheduled backups
#   once                       - run a single backup now and exit
#   restore <key>              - download a backup artifact from MinIO to /restore
#   archive-wal <%p> <%f>      - PITR (C4b): ship one WAL segment to the store
#                                (postgres archive_command target; needs PG_BACKUP_PITR=1)
#   pitr-restore <base> <time> - PITR (C4b): rebuild a PGDATA from a base + replay
#                                WAL to recovery_target_time (needs PG_BACKUP_PITR=1)
#   liveness                   - exit 0 if config is sane (used by healthchecks)
set -euo pipefail

MODE="${1:-loop}"

mc_alias() {
  local endpoint="${MINIO_ENDPOINT:-http://minio:9000}"
  mc alias set baas "$endpoint" \
    "${MINIO_ROOT_USER:-minioadmin}" \
    "${MINIO_ROOT_PASSWORD:-minioadmin}" >/dev/null
}

ensure_bucket() {
  mc mb -p "baas/${PG_BACKUP_BUCKET}" 2>/dev/null || true
}

case "$MODE" in
liveness)
  test -n "${DATABASE_URL:-}" || {
    echo "DATABASE_URL is required"
    exit 1
  }
  test -n "${MINIO_ENDPOINT:-http://minio:9000}" || exit 1
  exit 0
  ;;

once)
  mc_alias
  ensure_bucket
  exec /opt/pg-backup/run-backup.sh
  ;;

restore)
  shift || true
  key="${1:-}"
  if [ -z "$key" ]; then
    echo "Usage: restore <key>"
    echo "Available backups:"
    mc_alias
    mc ls "baas/${PG_BACKUP_BUCKET}/${PG_BACKUP_PREFIX}/" || true
    exit 1
  fi
  mc_alias
  exec /opt/pg-backup/restore.sh "$key"
  ;;

archive-wal)
  # PITR WAL shipping — postgres archive_command target. Flag-gated: refuse
  # unless PITR is explicitly enabled so the OFF baseline never ships WAL.
  shift || true
  [ "${PG_BACKUP_PITR:-0}" = "1" ] || {
    echo "archive-wal requires PG_BACKUP_PITR=1"
    exit 1
  }
  mc_alias
  exec /opt/pg-backup/wal-archive.sh "$@"
  ;;

pitr-restore)
  # PITR base+WAL replay to a target time. Flag-gated for symmetry with the
  # archive path; the OFF baseline keeps the plain logical restore only.
  shift || true
  [ "${PG_BACKUP_PITR:-0}" = "1" ] || {
    echo "pitr-restore requires PG_BACKUP_PITR=1"
    exit 1
  }
  # MinIO alias is only needed for the MinIO transport. A local store
  # (PITR_LOCAL_STORE) is self-contained — calling mc_alias without a reachable
  # MinIO would fail under set -e and kill the restore before pitr-restore.sh runs.
  [ -n "${PITR_LOCAL_STORE:-}" ] || mc_alias
  exec /opt/pg-backup/pitr-restore.sh "$@"
  ;;

loop)
  mc_alias
  ensure_bucket

  # Install crontab with the schedule from env. We capture env so cron can
  # see DATABASE_URL/MINIO_* (cron strips most of the parent env by default).
  env >/etc/environment
  : "${PG_BACKUP_SCHEDULE:?must be set}"
  echo "${PG_BACKUP_SCHEDULE} root /opt/pg-backup/run-backup.sh >> /var/log/pg-backup.log 2>&1" \
    >/etc/cron.d/pg-backup
  chmod 0644 /etc/cron.d/pg-backup
  touch /var/log/pg-backup.log

  echo "[pg-backup] schedule='${PG_BACKUP_SCHEDULE}' bucket='${PG_BACKUP_BUCKET}' prefix='${PG_BACKUP_PREFIX}'"
  cron -f &
  CRON_PID=$!

  # Stream logs to stdout for docker.
  tail -F /var/log/pg-backup.log &
  TAIL_PID=$!

  trap 'kill $CRON_PID $TAIL_PID 2>/dev/null || true' TERM INT
  wait $CRON_PID
  ;;

*)
  echo "Unknown mode: $MODE"
  echo "Modes: loop | once | restore <key> | archive-wal <%p> <%f> | pitr-restore <base> <time> | liveness"
  exit 1
  ;;
esac
