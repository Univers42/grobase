#!/bin/bash
# ============================================
# Deploy: Deploy to Fly.io through the Dockerized Fly service
# Usage: make deploy-fly
# ============================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "🚀 Deploying to Fly.io"

cd "$PROJECT_ROOT"

FLY_CONFIG="infrastructure/services/fly/config/fly.toml"

if [[ ! -f "$FLY_CONFIG" ]]; then
    print_error "Fly config not found: $FLY_CONFIG"
    exit 1
fi

log "Current Fly app configuration:"
grep -E "^app\s*=" "$FLY_CONFIG" || true

log "Deploying through Docker Compose fly service..."
docker_compose_with_production_env --profile tools run --rm fly infrastructure/services/fly/scripts/deploy.sh

print_ok "Deployment to Fly.io completed!"
