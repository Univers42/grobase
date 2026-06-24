#!/bin/bash
# ============================================
# Security: Check for Secrets in Code
# Usage: make security-secrets
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "🔍 Scanning for Secrets in Code"

cd "$PROJECT_ROOT"

FOUND_ISSUES=0

# Patterns to search for
PATTERNS=(
    "password\s*=\s*['\"][^'\"]+['\"]"
    "secret\s*=\s*['\"][^'\"]+['\"]"
    "api_key\s*=\s*['\"][^'\"]+['\"]"
    "apikey\s*=\s*['\"][^'\"]+['\"]"
    "private_key\s*=\s*['\"][^'\"]+['\"]"
    "token\s*=\s*['\"][^'\"]+['\"]"
    "AWS_SECRET"
    "SUPABASE_SERVICE_ROLE_KEY"
)

log "Scanning source files for potential secrets..."

for pattern in "${PATTERNS[@]}"; do
    RESULTS=$(grep -rniE "$pattern" --include="*.ts" --include="*.js" --include="*.tsx" --include="*.jsx" \
        --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=.git \
        --exclude="*.spec.ts" --exclude="*.test.ts" --exclude="*.d.ts" 2>/dev/null || true)
    
    if [ -n "$RESULTS" ]; then
        print_warn "Pattern '$pattern' found:"
        echo "$RESULTS"
        echo ""
        FOUND_ISSUES=1
    fi
done

# Check for .env files that might be committed
log "Checking for .env files in git..."
if git ls-files --error-unmatch .env .env.local .env.production 2>/dev/null; then
    print_error "WARNING: .env files may be tracked by git!"
    FOUND_ISSUES=1
fi

if [ $FOUND_ISSUES -eq 0 ]; then
    print_ok "No obvious secrets found in code!"
else
    print_warn "Review the findings above for potential security issues"
fi
