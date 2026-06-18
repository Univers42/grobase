#!/bin/bash
# Take a backup and upload it to MinIO. Idempotent — each run uses a unique
# timestamp-keyed object; old objects beyond PG_BACKUP_RETAIN_DAYS are pruned.
set -euo pipefail

: "${DATABASE_URL:?required}"
: "${PG_BACKUP_BUCKET:?required}"
: "${PG_BACKUP_PREFIX:?required}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LOGICAL_FILE="${TMP}/postgres-${STAMP}.dump"

echo "[pg-backup] $(date -u +%F\ %T) starting logical backup -> ${LOGICAL_FILE}"

# Custom format (-Fc) is compressed and supports parallel restore.
pg_dump --no-owner --no-privileges --format=custom \
  --file="$LOGICAL_FILE" \
  "$DATABASE_URL"

echo "[pg-backup] dump complete ($(du -h "$LOGICAL_FILE" | cut -f1))"

DEST_KEY="baas/${PG_BACKUP_BUCKET}/${PG_BACKUP_PREFIX}/logical/postgres-${STAMP}.dump"
mc cp "$LOGICAL_FILE" "$DEST_KEY"
echo "[pg-backup] uploaded to ${DEST_KEY}"

# Optional physical base backup (PITR-ready).
if [ "${PG_BACKUP_PHYSICAL:-0}" = "1" ]; then
  PHYS_DIR="${TMP}/base-${STAMP}"
  mkdir -p "$PHYS_DIR"
  echo "[pg-backup] starting physical base backup -> ${PHYS_DIR}"

  # pg_basebackup needs PG* connection vars; the URL doesn't always parse.
  PGHOST="$(echo "$DATABASE_URL" | sed -E 's#.*@([^:/]+).*#\1#')"
  PGPORT="$(echo "$DATABASE_URL" | sed -E 's#.*:([0-9]+).*#\1#')"
  PGUSER="$(echo "$DATABASE_URL" | sed -E 's#.*://([^:]+):.*#\1#')"
  PGPASSWORD="$(echo "$DATABASE_URL" | sed -E 's#.*://[^:]+:([^@]+)@.*#\1#')"
  export PGHOST PGPORT PGUSER PGPASSWORD

  pg_basebackup -D "$PHYS_DIR" --format=tar --gzip --checkpoint=fast \
    --progress --no-password
  for f in "$PHYS_DIR"/*; do
    mc cp "$f" "baas/${PG_BACKUP_BUCKET}/${PG_BACKUP_PREFIX}/physical/base-${STAMP}/$(basename "$f")"
  done
  echo "[pg-backup] physical base uploaded"
fi

# Retention pruning. mc has --older-than which accepts e.g. "14d".
#
# Retention-by-tier (C4b): when PG_BACKUP_PITR=1 the retain window is resolved
# from the tier in PG_BACKUP_TIER via the tier→days map, so a higher tier keeps
# WAL/base longer (a longer PITR window is exactly what a paid tier buys). The map
# is overridable per tier with PG_BACKUP_RETAIN_<TIER>_DAYS. With PITR unset this
# is a no-op: DAYS falls back to the original PG_BACKUP_RETAIN_DAYS (default 14)
# and ONLY the logical/physical prefixes are pruned — byte-identical to today.
DAYS="${PG_BACKUP_RETAIN_DAYS:-14}"
if [ "${PG_BACKUP_PITR:-0}" = "1" ]; then
  TIER="${PG_BACKUP_TIER:-essential}"
  case "${TIER}" in
  nano) TIER_DAYS="${PG_BACKUP_RETAIN_NANO_DAYS:-1}" ;;
  basic) TIER_DAYS="${PG_BACKUP_RETAIN_BASIC_DAYS:-3}" ;;
  essential) TIER_DAYS="${PG_BACKUP_RETAIN_ESSENTIAL_DAYS:-7}" ;;
  pro) TIER_DAYS="${PG_BACKUP_RETAIN_PRO_DAYS:-30}" ;;
  max) TIER_DAYS="${PG_BACKUP_RETAIN_MAX_DAYS:-90}" ;;
  *) TIER_DAYS="${DAYS}" ;;
  esac
  DAYS="${TIER_DAYS}"
  echo "[pg-backup] retention-by-tier: tier='${TIER}' -> ${DAYS}d (logical + physical + wal)"
fi

echo "[pg-backup] pruning artifacts older than ${DAYS}d"
mc rm --recursive --force --older-than "${DAYS}d" \
  "baas/${PG_BACKUP_BUCKET}/${PG_BACKUP_PREFIX}/logical/" 2>/dev/null || true
mc rm --recursive --force --older-than "${DAYS}d" \
  "baas/${PG_BACKUP_BUCKET}/${PG_BACKUP_PREFIX}/physical/" 2>/dev/null || true
# WAL is only ever produced/pruned when PITR is on; never touched in the OFF path.
if [ "${PG_BACKUP_PITR:-0}" = "1" ]; then
  mc rm --recursive --force --older-than "${DAYS}d" \
    "baas/${PG_BACKUP_BUCKET}/${PG_BACKUP_PREFIX}/wal/" 2>/dev/null || true
fi

echo "[pg-backup] $(date -u +%F\ %T) done"
