#!/bin/bash
# ============================================
# Database: Show Status
# Usage: make db-status
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "📊 Database Status"

load_env

if [ -z "$DATABASE_URL" ]; then
    print_warn "DATABASE_URL not found in environment"
    exit 1
fi

log "Checking database connection..."

# Extract host from DATABASE_URL
DB_HOST=$(echo "$DATABASE_URL" | sed -E 's/.*@([^:\/]+).*/\1/')
log "Database host: ${CYAN}$DB_HOST${NC}"

# Run status query
QUERY="
SELECT 
    current_database() as database,
    current_user as user,
    version() as version,
    pg_size_pretty(pg_database_size(current_database())) as db_size
"

log "Running status query..."
psql "$DATABASE_URL" -c "$QUERY" 2>/dev/null && print_ok "Connection successful!" || {
    print_error "Connection failed!"
    exit 1
}

# Show table counts
log ""
log "Table row counts:"
TABLES_QUERY="
SELECT schemaname, relname as table_name, n_live_tup as row_count
FROM pg_stat_user_tables 
ORDER BY n_live_tup DESC
LIMIT 15;
"
psql "$DATABASE_URL" -c "$TABLES_QUERY" 2>/dev/null
