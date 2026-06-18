#!/bin/bash
# ============================================
# Utils: Clean Build Artifacts
# Usage: make clean
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "🧹 Cleaning Build Artifacts"

cd "$PROJECT_ROOT"

# Clean backend
log "Cleaning Backend..."
cd "$BACKEND_PATH"
rm -rf dist 2>/dev/null && log "  Removed dist/" || true
rm -rf coverage 2>/dev/null && log "  Removed coverage/" || true
rm -rf .turbo 2>/dev/null && log "  Removed .turbo/" || true

# Clean frontend if exists
if [ -d "$PROJECT_ROOT/Front" ]; then
    log "Cleaning Frontend..."
    cd "$PROJECT_ROOT/Front"
    rm -rf dist 2>/dev/null && log "  Removed dist/" || true
    rm -rf .next 2>/dev/null && log "  Removed .next/" || true
    rm -rf coverage 2>/dev/null && log "  Removed coverage/" || true
fi

# Clean node_modules if requested
if [ "${DEEP:-}" = "1" ]; then
    print_warn "Deep clean: removing node_modules..."
    cd "$BACKEND_PATH"
    rm -rf node_modules && log "  Removed Backend/node_modules/"
    
    if [ -d "$PROJECT_ROOT/Front/node_modules" ]; then
        cd "$PROJECT_ROOT/Front"
        rm -rf node_modules && log "  Removed Front/node_modules/"
    fi
fi

print_ok "Clean completed!"
log "Tip: Use DEEP=1 make clean to also remove node_modules"
