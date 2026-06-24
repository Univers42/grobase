#!/bin/bash
# ============================================
# Utils: Project Status Overview
# Usage: make status
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "📊 Project Status"

cd "$PROJECT_ROOT"

# Git status
log "Git Branch:"
git branch --show-current 2>/dev/null || echo "Not a git repository"
echo ""

log "Git Status:"
git status -s 2>/dev/null || echo "N/A"
echo ""

# Backend
log "Backend Dependencies:"
cd "$BACKEND_PATH"
BACKEND_DEPS=$(cat package.json | grep -c '"' || echo "0")
echo "  Total entries in package.json: ~$BACKEND_DEPS"
echo "  node_modules exists: $([ -d node_modules ] && echo 'Yes' || echo 'No')"
echo ""

# Code stats
log "Code Statistics:"
cd "$PROJECT_ROOT"

TS_FILES=$(find Back/src -name "*.ts" ! -name "*.spec.ts" 2>/dev/null | wc -l)
SPEC_FILES=$(find Back/src -name "*.spec.ts" 2>/dev/null | wc -l)
MODULES=$(find Back/src -name "*.module.ts" 2>/dev/null | wc -l)
SERVICES=$(find Back/src -name "*.service.ts" 2>/dev/null | wc -l)
CONTROLLERS=$(find Back/src -name "*.controller.ts" 2>/dev/null | wc -l)

echo "  TypeScript files: $TS_FILES"
echo "  Test files (*.spec.ts): $SPEC_FILES"
echo "  NestJS Modules: $MODULES"
echo "  Services: $SERVICES"
echo "  Controllers: $CONTROLLERS"
echo ""

# Docker
log "Docker Status:"
if command -v docker &> /dev/null; then
    RUNNING=$(docker ps -q 2>/dev/null | wc -l)
    echo "  Running containers: $RUNNING"
else
    echo "  Docker not available"
fi
echo ""

print_ok "Status check completed!"
