#!/bin/bash
# ============================================
# Docker: Show container status
# Usage: make ps
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "$SCRIPT_DIR")/lib/common.sh"

print_header "📊 Docker Container Status"

cd "$PROJECT_ROOT"

log "Container status:"
echo ""
$DC ps

echo ""
log "Resource usage:"
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" 2>/dev/null || true
