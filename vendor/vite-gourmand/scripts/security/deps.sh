#!/bin/bash
# ============================================
# Security: Check Dependencies for Known Vulnerabilities
# Usage: make security-deps
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "📦 Dependency Security Check"

cd "$BACKEND_PATH"

log "Checking for outdated dependencies..."
echo ""
npm outdated || true

echo ""
log "Checking for known vulnerabilities..."
npm audit --json 2>/dev/null | node -e "
const data = JSON.parse(require('fs').readFileSync('/dev/stdin', 'utf8'));
if (data.metadata) {
    console.log('');
    console.log('Summary:');
    console.log('  Total dependencies:', data.metadata.totalDependencies || 'N/A');
    console.log('  Vulnerabilities:', JSON.stringify(data.metadata.vulnerabilities || {}));
}
" 2>/dev/null || npm audit

print_ok "Dependency check completed!"
