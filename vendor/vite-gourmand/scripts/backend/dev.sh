#!/bin/bash
# ============================================
# Backend: Start Development Server
# Usage: make dev
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "🚀 Starting Development Server"

cd "$BACKEND_PATH"

# Check if node_modules exists
if [[ ! -d "node_modules" ]]; then
    log "Installing dependencies..."
    npm install
fi

# Check Prisma client
if [[ ! -d "node_modules/.prisma/client" ]]; then
    log "Generating Prisma client..."
    npx prisma generate --schema=src/Model/prisma/schema.prisma
fi

log "Starting NestJS in watch mode..."
echo ""
exec npm run start:dev
