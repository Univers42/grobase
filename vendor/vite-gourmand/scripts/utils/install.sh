#!/bin/bash
# ============================================
# Utils: Install Dependencies
# Usage: make install
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "📦 Installing Dependencies"

cd "$PROJECT_ROOT"

# Backend
log "Installing Backend dependencies..."
cd "$BACKEND_PATH"
npm install

# Frontend
if [ -d "$PROJECT_ROOT/Front" ]; then
    log "Installing Frontend dependencies..."
    cd "$PROJECT_ROOT/Front"
    npm install
fi

# Generate Prisma client
log "Generating Prisma client..."
cd "$BACKEND_PATH"
npx prisma generate

print_ok "All dependencies installed!"
