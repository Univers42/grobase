#!/bin/bash
# ============================================
# Backend: Run ESLint
# Usage: make lint [FIX=1]
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "🔍 ESLint Check"

cd "$BACKEND_PATH"

FIX_FLAG=""
[[ "${FIX:-}" == "1" ]] && FIX_FLAG="--fix"

log "Running ESLint..."
npx eslint "{src,apps,libs,test}/**/*.ts" $FIX_FLAG || {
    print_fail "Linting errors found"
    exit 1
}

print_ok "No linting errors!"
