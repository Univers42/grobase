#!/bin/bash
# ============================================
# Deploy: Configure Fly managed certificates through Dockerized Fly service
# Usage:
#   CREATE_CERTS=true scripts/deploy/fly-certificates.sh
#   HOSTS="vite-gourmand.fr www.vite-gourmand.fr" scripts/deploy/fly-certificates.sh
# ============================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "Fly Managed Certificates"

cd "$PROJECT_ROOT"

if [[ ! -f "infrastructure/services/fly/config/fly.toml" ]]; then
    print_error "Fly config not found: infrastructure/services/fly/config/fly.toml"
    exit 1
fi

docker_compose_with_production_env --profile tools run --rm fly infrastructure/services/fly/scripts/certificates.sh

print_ok "Fly certificate helper finished"