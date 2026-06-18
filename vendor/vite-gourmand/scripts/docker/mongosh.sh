#!/bin/bash
# ============================================
# Docker: Open MongoDB shell
# Usage: make mongosh
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "$SCRIPT_DIR")/lib/common.sh"

print_header "🍃 MongoDB Shell"

cd "$PROJECT_ROOT"

if ! docker_container_running "$MONGO_CONTAINER"; then
    print_error "MongoDB container is not running"
    log "Start containers with: make up"
    exit 1
fi

log "Connecting to MongoDB..."
docker exec -it "$MONGO_CONTAINER" mongosh -u root -p example --authenticationDatabase admin vite_gourmand
