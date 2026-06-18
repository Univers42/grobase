#!/bin/bash
# ============================================
# Docker: Start all containers
# Usage: make up
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "$SCRIPT_DIR")/lib/common.sh"

print_header "🐳 Starting Docker Containers"

cd "$PROJECT_ROOT"

log "Starting containers with $DC..."
$DC up -d --build

log "Waiting for containers to be healthy..."
sleep 3

# Show status
$DC ps

print_ok "Containers started!"
