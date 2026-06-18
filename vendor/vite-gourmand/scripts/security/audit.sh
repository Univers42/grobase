#!/bin/bash
# ============================================
# Security: NPM Audit
# Usage: make security-audit
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "🔐 Security Audit"

cd "$BACKEND_PATH"

log "Running npm audit on Backend..."
npm audit --audit-level=moderate || true

if [ -d "$PROJECT_ROOT/Front" ]; then
    log ""
    log "Running npm audit on Frontend..."
    cd "$PROJECT_ROOT/Front"
    npm audit --audit-level=moderate || true
fi

print_ok "Security audit completed!"
