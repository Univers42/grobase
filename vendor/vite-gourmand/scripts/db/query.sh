#!/bin/bash
# ============================================
# Database: Run Custom Query
# Usage: make db-query SQL="SELECT * FROM users LIMIT 5"
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "🔍 Database Query"

load_env

if [ -z "$DATABASE_URL" ]; then
    print_error "DATABASE_URL not found in environment"
    exit 1
fi

SQL="${SQL:-}"
if [ -z "$SQL" ]; then
    print_error "No query provided!"
    log "Usage: make db-query SQL=\"SELECT * FROM users LIMIT 5\""
    exit 1
fi

log "Executing: ${CYAN}$SQL${NC}"
echo ""
psql "$DATABASE_URL" -c "$SQL"
