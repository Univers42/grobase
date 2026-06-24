#!/bin/bash
# ============================================
# Docker: Restart containers
# Usage: make restart
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "$SCRIPT_DIR")/lib/common.sh"

print_header "🔄 Restarting Docker Containers"

cd "$PROJECT_ROOT"

log "Restarting containers..."
$DC restart

print_ok "Containers restarted!"
