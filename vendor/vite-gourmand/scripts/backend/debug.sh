#!/bin/bash
# ============================================
# Backend: Start with Debug Mode
# Usage: make debug
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "🐛 Starting Debug Server"

cd "$BACKEND_PATH"

log "Starting NestJS with Node.js inspector..."
echo "  Debugger: chrome://inspect"
echo ""
exec npm run start:debug
