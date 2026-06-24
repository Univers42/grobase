#!/bin/bash
# ============================================
# Database: Reset (Drop all tables and re-seed)
# Usage: make db-reset
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "⚠️  Database Reset"

cd "$BACKEND_PATH"

load_env

print_warn "This will RESET the entire database!"
read -p "Are you sure? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Aborted."
    exit 0
fi

log "Resetting database with Prisma..."
npx prisma migrate reset --force

print_ok "Database reset and re-seeded!"
