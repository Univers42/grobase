#!/bin/bash
# ============================================
# Docker: Clean up Docker resources
# Usage: make docker-clean [DEEP=1]
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "$SCRIPT_DIR")/lib/common.sh"

print_header "🧹 Docker Cleanup"

cd "$PROJECT_ROOT"

if [ "${DEEP:-}" = "1" ]; then
    print_warn "Deep clean: removing containers, images, AND volumes..."
    read -p "Are you sure? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Aborted."
        exit 0
    fi
    $DC down -v --rmi all
    log "Pruning unused Docker resources..."
    docker system prune -f
else
    log "Removing containers and images (keeping volumes)..."
    $DC down --rmi all
fi

print_ok "Docker cleanup completed!"
log "Tip: Use DEEP=1 make docker-clean to also remove volumes"
