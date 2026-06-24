#!/bin/bash
# Database backup script for Music Room
# Usage: ./backup-db.sh [output_dir]

set -euo pipefail

MONGO_URI="${MONGO_URI:-mongodb://localhost:27017}"
DB_NAME="${DB_NAME:-music-room}"
BACKUP_DIR="${1:-./backups}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="${BACKUP_DIR}/${DB_NAME}_${TIMESTAMP}"

echo "=== Music Room Database Backup ==="
echo "Database: ${DB_NAME}"
echo "Timestamp: ${TIMESTAMP}"
echo "Output: ${BACKUP_PATH}"
echo ""

# Create backup directory
mkdir -p "${BACKUP_DIR}"

# Run mongodump
echo "Starting backup..."
mongodump \
  --uri="${MONGO_URI}" \
  --db="${DB_NAME}" \
  --out="${BACKUP_PATH}" \
  --gzip

# Check result
if [ $? -eq 0 ]; then
  echo ""
  echo "Backup completed successfully!"
  
  # Calculate size
  SIZE=$(du -sh "${BACKUP_PATH}" | cut -f1)
  echo "Backup size: ${SIZE}"
  
  # Create latest symlink
  ln -sf "${BACKUP_PATH}" "${BACKUP_DIR}/latest"
  
  # Cleanup old backups (keep last 7)
  echo ""
  echo "Cleaning up old backups (keeping last 7)..."
  ls -dt "${BACKUP_DIR}/${DB_NAME}_"* 2>/dev/null | tail -n +8 | xargs rm -rf 2>/dev/null || true
  
  echo "Done!"
else
  echo "Backup failed!"
  exit 1
fi
