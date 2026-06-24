#!/bin/bash
# ============================================
# Deploy: View Fly.io Logs through Dockerized Fly service
# Usage: make deploy-logs
# ============================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "📋 Fly.io Application Logs"

cd "$PROJECT_ROOT"

log "Streaming logs from Fly.io through Docker Compose fly service..."
docker_compose_with_production_env --profile tools run --rm fly infrastructure/services/fly/scripts/logs.sh
