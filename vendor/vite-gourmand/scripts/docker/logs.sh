#!/bin/bash
# ============================================
# Docker: View container logs
# Usage: make logs [SERVICE=backend]
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "$SCRIPT_DIR")/lib/common.sh"

print_header "📋 Docker Logs"

cd "$PROJECT_ROOT"

SERVICE="${SERVICE:-}"
TAIL="${TAIL:-100}"

if [ -n "$SERVICE" ]; then
    log "Streaming logs for: $SERVICE (last $TAIL lines)"
    $DC logs -f --tail="$TAIL" "$SERVICE"
else
    log "Streaming all container logs (last $TAIL lines)"
    $DC logs -f --tail="$TAIL"
fi
