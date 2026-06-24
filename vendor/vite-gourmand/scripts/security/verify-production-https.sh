#!/bin/bash
# ============================================
# Security: Verify production HTTPS and CA certificate
# Usage:
#   scripts/security/verify-production-https.sh
#   HOSTS="vite-gourmand.fr www.vite-gourmand.fr" PAGES="/ /menus" scripts/security/verify-production-https.sh
# ============================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

cd "$PROJECT_ROOT"
docker_compose_with_production_env --profile tools run --rm fly infrastructure/services/fly/scripts/verify-production-https.sh