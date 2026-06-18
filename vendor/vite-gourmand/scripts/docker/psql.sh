#!/bin/bash
# ============================================
# Docker: Open PostgreSQL shell
# Usage: make psql
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "$SCRIPT_DIR")/lib/common.sh"

print_header "🐘 PostgreSQL Shell"

cd "$PROJECT_ROOT"

if ! docker_container_running "$POSTGRES_CONTAINER"; then
    print_error "PostgreSQL container is not running"
    log "Start containers with: make up"
    exit 1
fi

log "Connecting to PostgreSQL..."
docker exec -it "$POSTGRES_CONTAINER" psql -U postgres -d vite_gourmand
