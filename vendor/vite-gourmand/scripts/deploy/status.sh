#!/bin/bash
# ============================================
# Deploy: Check Deployment Status through Dockerized Fly service
# Usage: make deploy-status
# ============================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "📊 Deployment Status"

cd "$PROJECT_ROOT"

docker_compose_with_production_env --profile tools run --rm fly infrastructure/services/fly/scripts/status.sh

print_ok "Status check completed!"
