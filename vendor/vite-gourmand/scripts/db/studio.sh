#!/bin/bash
# ============================================
# Database: Prisma Studio GUI
# Usage: make db-studio
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "🖥️  Opening Prisma Studio"

cd "$BACKEND_PATH"

load_env

log "Starting Prisma Studio..."
log "Opening at http://localhost:5555"

npx prisma studio
