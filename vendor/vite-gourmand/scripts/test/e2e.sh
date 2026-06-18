#!/bin/bash
# ============================================
# Test: Run E2E Tests
# Usage: make test-e2e
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "🔗 Running E2E Tests"

cd "$BACKEND_PATH"

log "Running Jest E2E tests..."
npm run test:e2e -- --passWithNoTests

print_ok "E2E tests completed!"
