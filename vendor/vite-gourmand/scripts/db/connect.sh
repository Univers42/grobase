#!/bin/bash
# ============================================
# Database: Connect to Supabase PostgreSQL
# Usage: make db-connect
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "🔌 Connecting to Supabase Database"

load_env

SUPABASE_HOST="${SUPABASE_HOST:-aws-0-eu-west-3.pooler.supabase.com}"
SUPABASE_PORT="${SUPABASE_PORT:-6543}"
SUPABASE_DB="${SUPABASE_DB:-postgres}"
SUPABASE_USER="${SUPABASE_USER:-postgres.nzqtqkynwzqkxrvzugiq}"

if [ -z "$SUPABASE_PASSWORD" ] && [ -z "$DATABASE_URL" ]; then
    print_warn "SUPABASE_PASSWORD not found in environment"
    log "Set it in .env or export it before running this script"
    exit 1
fi

if [ -n "$DATABASE_URL" ]; then
    log "Connecting using DATABASE_URL..."
    psql "$DATABASE_URL"
else
    log "Connecting to $SUPABASE_HOST:$SUPABASE_PORT/$SUPABASE_DB..."
    PGPASSWORD="$SUPABASE_PASSWORD" psql -h "$SUPABASE_HOST" -p "$SUPABASE_PORT" -d "$SUPABASE_DB" -U "$SUPABASE_USER"
fi
