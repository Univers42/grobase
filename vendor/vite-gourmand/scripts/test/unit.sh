#!/bin/bash
# ============================================
# Test: Run Unit Tests
# Usage: make test-unit
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "🧪 Running Unit Tests"

cd "$BACKEND_PATH"

log "Running Jest unit tests..."
npm test -- --passWithNoTests

print_ok "Unit tests completed!"
