#!/bin/bash
# ============================================
# Database: Run Prisma Seed
# Usage: make db-seed
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "🌱 Seeding Database"

cd "$BACKEND_PATH"

load_env

log "Running Prisma seed..."
npx prisma db seed

print_ok "Database seeded successfully!"
