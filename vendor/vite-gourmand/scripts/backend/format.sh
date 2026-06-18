#!/bin/bash
# ============================================
# Backend: Format Code with Prettier
# Usage: make format
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "✨ Code Formatting"

cd "$BACKEND_PATH"

log "Formatting with Prettier..."
npm run format

print_ok "Code formatted!"
