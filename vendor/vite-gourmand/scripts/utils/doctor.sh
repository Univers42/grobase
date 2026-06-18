#!/bin/bash
# ============================================
# Utils: Doctor - Check Development Environment
# Usage: make doctor
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "🩺 Development Environment Check"

WARNINGS=0
ERRORS=0

check_command() {
    local cmd="$1"
    local name="$2"
    local required="${3:-yes}"
    
    if command -v "$cmd" &> /dev/null; then
        VERSION=$($cmd --version 2>&1 | head -n 1)
        printf "${GREEN}✓${NC} %-15s %s\n" "$name:" "$VERSION"
    else
        if [ "$required" = "yes" ]; then
            printf "${RED}✗${NC} %-15s Not installed (required)\n" "$name:"
            ERRORS=$((ERRORS + 1))
        else
            printf "${YELLOW}○${NC} %-15s Not installed (optional)\n" "$name:"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi
}

log "Required Tools:"
check_command node "Node.js" yes
check_command npm "npm" yes
check_command npx "npx" yes
check_command git "Git" yes

echo ""
log "Optional Tools:"
check_command docker "Docker" no
check_command flyctl "Fly CLI" no
check_command psql "PostgreSQL CLI" no

echo ""
log "Project Files:"

cd "$PROJECT_ROOT"

check_file() {
    local file="$1"
    local name="$2"
    local required="${3:-yes}"
    
    if [ -f "$file" ]; then
        printf "${GREEN}✓${NC} %-30s exists\n" "$name:"
    else
        if [ "$required" = "yes" ]; then
            printf "${RED}✗${NC} %-30s missing\n" "$name:"
            ERRORS=$((ERRORS + 1))
        else
            printf "${YELLOW}○${NC} %-30s not found (optional)\n" "$name:"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi
}

check_file "Back/package.json" "Backend package.json" yes
check_file "Back/src/Model/prisma/schema.prisma" "Prisma schema" yes
check_file "infrastructure/services/fly/config/fly.toml" "Fly.io config" yes
check_file "Dockerfile" "Dockerfile" yes

# Check for .env in either location (optional - can use env vars)
if [ -f ".env" ] || [ -f "Back/.env" ]; then
    printf "${GREEN}✓${NC} %-30s found\n" ".env file:"
else
    printf "${YELLOW}○${NC} %-30s not found (optional)\n" ".env file:"
    WARNINGS=$((WARNINGS + 1))
fi

echo ""
log "Node Modules:"
if [ -d "Back/node_modules" ]; then
    print_ok "Backend node_modules installed"
else
    print_warn "Backend node_modules not installed - run 'npm install' in Back/"
    WARNINGS=$((WARNINGS + 1))
fi

echo ""
if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    print_ok "Environment is healthy! ✨"
elif [ $ERRORS -eq 0 ]; then
    print_warn "$WARNINGS warning(s) found"
else
    print_fail "$ERRORS error(s) and $WARNINGS warning(s) found"
    exit 1
fi
