#!/usr/bin/env bash
# ============================================
# MongoDB Analytics Management Script
# ============================================
# Manages MongoDB Atlas analytics collections.
# Commands: init, reset, cleanup, stats, test
# ============================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BACKEND_DIR="$PROJECT_ROOT/Back"
NOSQL_SCRIPTS="$BACKEND_DIR/src/Model/nosql/scripts"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Load environment (avoid sourcing due to spaces in some values)
if [ -f "$BACKEND_DIR/.env" ]; then
    export MONGODB_URI=$(grep -E '^MONGODB_URI=' "$BACKEND_DIR/.env" | cut -d '=' -f2- | tr -d '"')
    export MONGODB_MAX_STORAGE_MB=$(grep -E '^MONGODB_MAX_STORAGE_MB=' "$BACKEND_DIR/.env" | cut -d '=' -f2- | tr -d '"')
    export MONGODB_CLEANUP_THRESHOLD_PERCENT=$(grep -E '^MONGODB_CLEANUP_THRESHOLD_PERCENT=' "$BACKEND_DIR/.env" | cut -d '=' -f2- | tr -d '"')
fi

show_help() {
    echo "MongoDB Analytics Management"
    echo ""
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  init      Create collections and indexes"
    echo "  reset     Drop and recreate all collections (DESTRUCTIVE)"
    echo "  cleanup   Run storage cleanup based on retention policy"
    echo "  emergency Run emergency cleanup (halves TTL)"
    echo "  stats     Show storage statistics"
    echo "  test      Test MongoDB Atlas connection"
    echo "  help      Show this help message"
    echo ""
}

check_uri() {
    if [ -z "${MONGODB_URI:-}" ]; then
        error "MONGODB_URI not set. Check Back/.env"
    fi
}

run_script() {
    local script="$1"
    shift
    cd "$BACKEND_DIR" || error "Cannot cd to $BACKEND_DIR"
    npx tsx "$script" "$@"
}

cmd_init() {
    log "Initializing MongoDB analytics collections..."
    check_uri
    run_script "$NOSQL_SCRIPTS/init-mongodb.ts"
    ok "MongoDB initialized!"
}

cmd_reset() {
    log "⚠️  DESTRUCTIVE: Resetting MongoDB analytics..."
    check_uri
    
    echo ""
    read -rp "Are you sure? This will DELETE all analytics data. (y/N) " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        warn "Aborted."
        exit 0
    fi
    
    run_script "$NOSQL_SCRIPTS/reset-mongodb.ts"
    ok "MongoDB reset complete!"
}

cmd_cleanup() {
    log "Running storage cleanup..."
    check_uri
    run_script "$NOSQL_SCRIPTS/cleanup-mongodb.ts"
    ok "Cleanup complete!"
}

cmd_emergency() {
    log "⚠️  Running EMERGENCY cleanup (halved TTL)..."
    check_uri
    run_script "$NOSQL_SCRIPTS/cleanup-mongodb.ts" --emergency
    ok "Emergency cleanup complete!"
}

cmd_stats() {
    log "Fetching MongoDB statistics..."
    check_uri
    run_script "$NOSQL_SCRIPTS/stats-mongodb.ts"
}

cmd_test() {
    log "Testing MongoDB Atlas connection..."
    check_uri
    
    cd "$BACKEND_DIR" || error "Cannot cd to $BACKEND_DIR"
    
    npx tsx -e "
const { MongoClient, ServerApiVersion } = require('mongodb');

async function test() {
    const client = new MongoClient(process.env.MONGODB_URI, {
        serverApi: { version: ServerApiVersion.v1 }
    });
    
    try {
        await client.connect();
        await client.db('admin').command({ ping: 1 });
        console.log('✅ Connected to MongoDB Atlas!');
        
        const db = client.db('vite_gourmand');
        const collections = await db.listCollections().toArray();
        console.log('📂 Collections:', collections.length);
        
        const stats = await db.stats();
        console.log('💾 Size:', (stats.dataSize / 1024 / 1024).toFixed(2), 'MB');
    } finally {
        await client.close();
    }
}

test().catch(e => { console.error('❌', e.message); process.exit(1); });
"
    
    ok "Connection test passed!"
}

# Main
case "${1:-help}" in
    init)      cmd_init ;;
    reset)     cmd_reset ;;
    cleanup)   cmd_cleanup ;;
    emergency) cmd_emergency ;;
    stats)     cmd_stats ;;
    test)      cmd_test ;;
    help|*)    show_help ;;
esac
