#!/bin/bash
# ============================================
# Database: Run Migrations
# Usage: make db-migrate
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "🔄 Running Database Migrations"

cd "$BACKEND_PATH"

load_env

if [ "${1:-}" = "deploy" ]; then
    log "Running Prisma migrate deploy (production)..."
    npx prisma migrate deploy
else
    log "Running Prisma migrate dev..."
    npx prisma migrate dev
fi

print_ok "Migrations completed!"
