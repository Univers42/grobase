#!/bin/bash
# ============================================
# Docker: Stop all containers
# Usage: make down
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "$SCRIPT_DIR")/lib/common.sh"

print_header "🛑 Stopping Docker Containers"

cd "$PROJECT_ROOT"

log "Stopping containers..."
$DC down

print_ok "Containers stopped!"
