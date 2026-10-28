#!/usr/bin/env bash
# Concrete HTTP/persistence and backup failure-path tests. --live additionally
# runs the isolated PostgreSQL/MinIO restore drill; never touches deployed data.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 "${ROOT}/infra/docker/services/status-page/test_availability.py"
python3 "${ROOT}/scripts/test/backup-monitor-test.py"
if [ "${1:-}" = --live ]; then
  bash "${ROOT}/scripts/verify/m242-monitored-backup-restore.sh"
else
  echo '[M241] local HTTP/persistence and command-adapter tests passed; live PostgreSQL/MinIO restore NOT run (use --live)'
fi
