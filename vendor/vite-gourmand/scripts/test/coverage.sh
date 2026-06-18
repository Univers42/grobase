#!/bin/bash
# ============================================
# Test: Coverage Report
# Usage: make coverage
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "📊 Running Tests with Coverage"

cd "$BACKEND_PATH"

log "Running Jest with coverage..."
npm test -- --coverage --passWithNoTests

log "Coverage report generated in $BACKEND_PATH/coverage/"

if [ -f "$BACKEND_PATH/coverage/lcov-report/index.html" ]; then
    print_ok "Open coverage/lcov-report/index.html to see the full report"
fi

print_ok "Coverage analysis completed!"
