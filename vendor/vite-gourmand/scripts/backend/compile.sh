#!/bin/bash
# ============================================
# Backend: TypeScript Compile Check
# Usage: make compile
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "📝 TypeScript Compile Check"

cd "$BACKEND_PATH"

log "Checking TypeScript compilation (no emit)..."
npx tsc --noEmit 2>&1 | head -50 || true

ERRORS=$(npx tsc --noEmit 2>&1 | grep -c "error TS" || echo "0")

if [[ "$ERRORS" == "0" ]]; then
    print_ok "No TypeScript errors!"
else
    print_fail "Found $ERRORS TypeScript errors"
    exit 1
fi
