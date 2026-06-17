# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    smoke-test-quick.sh                                :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
# File: scripts/smoke-test-quick.sh
# Quick post-deploy smoke test — under 30 seconds.
# Tests only essential service liveness. Suitable for production.
# Usage: bash scripts/smoke-test-quick.sh
# Env:   BASE_URL (default: http://localhost:8000)
#        APIKEY   (default: public-anon-key)

set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
APIKEY="${APIKEY:-public-anon-key}"
TIMEOUT="${TIMEOUT:-5}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASSED=0
FAILED=0
readonly CURL_FMT='%{http_code}'
readonly HDR_APIKEY="apikey: $APIKEY"

smoke() {
  local name="$1"
  local url="$2"
  local expected="${3:-200}"

  code=$(curl -sS -o /dev/null -w "$CURL_FMT" \
    --max-time "$TIMEOUT" \
    -H "$HDR_APIKEY" \
    "$url" 2>/dev/null || echo "000")

  if [[ "$code" = "$expected" ]]; then
    echo -e "  ${GREEN}✓${NC} $name  (HTTP $code)"
    PASSED=$((PASSED + 1))
  else
    echo -e "  ${RED}✗${NC} $name  (expected $expected, got $code)"
    FAILED=$((FAILED + 1))
  fi
  return 0
}

echo -e "${BOLD}═══ Quick Smoke Test ═══${NC}"
echo -e "  Target: $BASE_URL"
echo ""

t0=$(date +%s)

# ── Kong gateway health ──────────────────────────────────────────
smoke "Kong gateway"           "$BASE_URL/auth/v1/health"

# ── GoTrue auth health ──────────────────────────────────────────
smoke "GoTrue auth"            "$BASE_URL/auth/v1/health"

# ── PostgREST schema ────────────────────────────────────────────
# PostgREST returns the OpenAPI schema on GET /
smoke "PostgREST schema"       "$BASE_URL/rest/v1/"

# ── Mongo-api health ────────────────────────────────────────────
smoke "Mongo-api liveness"     "$BASE_URL/mongo/v1/health/live"

# ── Adapter-registry liveness ────────────────────────────────────
smoke "Adapter-registry"       "$BASE_URL/admin/v1/databases/health/live" "401"
# 401 is expected: no JWT, but service is alive and responding

t1=$(date +%s)
elapsed=$((t1 - t0))

echo ""
echo -e "${BOLD}Results:${NC} ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}  (${elapsed}s)"

if [[ "$FAILED" -gt 0 ]]; then
  echo -e "${RED}${BOLD}✗ Smoke test failed${NC}"
  exit 1
fi

echo -e "${GREEN}${BOLD}✓ All smoke checks passed${NC}"
exit 0
