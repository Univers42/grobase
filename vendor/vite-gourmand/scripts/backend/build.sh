#!/bin/bash
# ============================================
# Backend: Build for Production
# Usage: make build
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "🔨 Building Backend"

cd "$BACKEND_PATH"

# Clean previous build
if [[ -d "dist" ]]; then
    log "Cleaning previous build..."
    rm -rf dist
fi

# Generate Prisma client
log "Generating Prisma client..."
npx prisma generate --schema=src/Model/prisma/schema.prisma

# Build
log "Compiling TypeScript..."
npm run build

# Copy i18n files
log "Copying i18n files..."
mkdir -p dist/src/i18n
cp -r src/i18n/* dist/src/i18n/ 2>/dev/null || true

print_ok "Build completed!"
echo "  Output: $BACKEND_PATH/dist/"
