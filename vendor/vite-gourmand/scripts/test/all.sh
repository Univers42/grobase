#!/bin/bash
# ============================================
# Test: Run All Tests (Unit + E2E)
# Usage: make test-all
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "🧪 Running All Tests"

cd "$BACKEND_PATH"

log "Running unit tests..."
npm test -- --passWithNoTests

log "Running E2E tests..."
npm run test:e2e -- --passWithNoTests

print_ok "All tests completed!"
