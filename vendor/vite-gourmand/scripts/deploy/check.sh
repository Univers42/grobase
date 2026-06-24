#!/bin/bash
# ============================================
# Deploy: Pre-deployment Checks
# Usage: make deploy-check
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "✅ Pre-Deployment Checks"

cd "$PROJECT_ROOT"

ERRORS=0

# Check 1: TypeScript compilation
log "1. TypeScript compilation..."
cd "$BACKEND_PATH"
if npm run build 2>&1 | grep -q "error"; then
    print_error "TypeScript compilation failed!"
    ERRORS=$((ERRORS + 1))
else
    print_ok "TypeScript compiles successfully"
fi

# Check 2: ESLint
log "2. ESLint check..."
if npm run lint 2>&1 | grep -qE "error|Error"; then
    print_warn "ESLint has errors"
    ERRORS=$((ERRORS + 1))
else
    print_ok "ESLint passes"
fi

# Check 3: Unit tests
log "3. Unit tests..."
if npm test -- --passWithNoTests 2>&1 | grep -q "FAIL"; then
    print_error "Unit tests failed!"
    ERRORS=$((ERRORS + 1))
else
    print_ok "Unit tests pass"
fi

# Check 4: Environment variables
log "4. Required environment variables..."
cd "$PROJECT_ROOT"
REQUIRED_VARS=("DATABASE_URL" "JWT_SECRET")
for var in "${REQUIRED_VARS[@]}"; do
    if grep -q "^$var=" .env 2>/dev/null || grep -q "^$var=" Back/.env 2>/dev/null; then
        print_ok "$var is set"
    else
        print_warn "$var may not be set"
    fi
done

# Check 5: Fly config exists
log "5. Deployment configuration..."
FLY_CONFIG="infrastructure/services/fly/config/fly.toml"
if [ -f "$FLY_CONFIG" ]; then
    print_ok "$FLY_CONFIG exists"
else
    print_error "$FLY_CONFIG not found!"
    ERRORS=$((ERRORS + 1))
fi

echo ""
if [ $ERRORS -eq 0 ]; then
    print_ok "All pre-deployment checks passed! Ready to deploy."
else
    print_error "$ERRORS check(s) failed. Fix issues before deploying."
    exit 1
fi
