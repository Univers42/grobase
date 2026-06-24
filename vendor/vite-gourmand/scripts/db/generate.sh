#!/bin/bash
# ============================================
# Database: Generate Prisma Client
# Usage: make db-generate
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "⚙️  Generating Prisma Client"

cd "$BACKEND_PATH"

log "Running Prisma generate..."
npx prisma generate

print_ok "Prisma client generated!"
