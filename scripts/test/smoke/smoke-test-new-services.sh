# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    smoke-test-new-services.sh                         :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
# File: scripts/smoke-test-new-services.sh
# Smoke tests for the 6 new BaaS services:
#   analytics (3070), gdpr (3080), newsletter (3090),
#   ai (3100), log (3110), session (3120)
#
# Usage: bash scripts/smoke-test-new-services.sh
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
DIM='\033[2m'
NC='\033[0m'

PASSED=0
FAILED=0
SKIPPED=0
readonly CURL_FMT='%{http_code}'
readonly HDR_APIKEY="apikey: $APIKEY"
readonly HEALTH_LIVE='Health live'
readonly HEALTH_READY='Health ready'

smoke() {
  local name="$1"
  local url="$2"
  local expected="${3:-200}"
  local method="${4:-GET}"
  local data="${5:-}"

  local curl_args=(-sS -o /dev/null -w "$CURL_FMT" --max-time "$TIMEOUT" -H "$HDR_APIKEY")

  if [[ "$method" == "POST" ]]; then
    curl_args+=(-X POST -H "Content-Type: application/json")
    if [[ -n "$data" ]]; then
      curl_args+=(-d "$data")
    fi
  fi

  code=$(curl "${curl_args[@]}" "$url" 2>/dev/null || echo "000")

  if [[ "$code" = "$expected" ]]; then
    echo -e "  ${GREEN}✓${NC} $name  (HTTP $code)"
    PASSED=$((PASSED + 1))
  else
    echo -e "  ${RED}✗${NC} $name  (expected $expected, got $code)"
    FAILED=$((FAILED + 1))
  fi
  return 0
}

echo -e "${BOLD}═══ New BaaS Services — Smoke Test ═══${NC}"
echo -e "  Target: $BASE_URL"
echo ""

t0=$(date +%s)

# ── Analytics Service ────────────────────────────────────────────
echo -e "${BOLD}Analytics Service (/analytics/v1)${NC}"
smoke "$HEALTH_LIVE"        "$BASE_URL/analytics/v1/health/live"
smoke "$HEALTH_READY"       "$BASE_URL/analytics/v1/health/ready"
smoke "Track event (anon)"  "$BASE_URL/analytics/v1/events" "201" "POST" \
  '{"eventType":"smoke_test","data":{"source":"smoke-test"}}'
echo ""

# ── GDPR Service ────────────────────────────────────────────────
echo -e "${BOLD}GDPR Service (/gdpr/v1)${NC}"
smoke "$HEALTH_LIVE"        "$BASE_URL/gdpr/v1/health/live"
smoke "$HEALTH_READY"       "$BASE_URL/gdpr/v1/health/ready"
# Consent endpoints require auth — 401 expected
smoke "Consents (no auth)"  "$BASE_URL/gdpr/v1/consents" "401"
echo ""

# ── Newsletter Service ──────────────────────────────────────────
echo -e "${BOLD}Newsletter Service (/newsletter/v1)${NC}"
smoke "$HEALTH_LIVE"        "$BASE_URL/newsletter/v1/health/live"
smoke "$HEALTH_READY"       "$BASE_URL/newsletter/v1/health/ready"
# Subscribe is public
smoke "Subscribe"           "$BASE_URL/newsletter/v1/subscribe" "201" "POST" \
  '{"email":"smoke-test@example.com"}'
echo ""

# ── AI Service ──────────────────────────────────────────────────
echo -e "${BOLD}AI Service (/ai/v1)${NC}"
smoke "$HEALTH_LIVE"        "$BASE_URL/ai/v1/health/live"
smoke "$HEALTH_READY"       "$BASE_URL/ai/v1/health/ready"
# Chat is OptionalAuth — should work anonymously
smoke "Chat (anon)"         "$BASE_URL/ai/v1/chat" "201" "POST" \
  '{"message":"Hello"}'
echo ""

# ── Log Service ─────────────────────────────────────────────────
echo -e "${BOLD}Log Service (/logs/v1)${NC}"
smoke "$HEALTH_LIVE"        "$BASE_URL/logs/v1/health/live"
smoke "$HEALTH_READY"       "$BASE_URL/logs/v1/health/ready"
smoke "Ingest log"          "$BASE_URL/logs/v1/logs/ingest" "201" "POST" \
  '{"level":"info","source":"smoke-test","message":"Hello from smoke test"}'
echo ""

# ── Session Service ─────────────────────────────────────────────
echo -e "${BOLD}Session Service (/sessions/v1)${NC}"
smoke "$HEALTH_LIVE"        "$BASE_URL/sessions/v1/health/live"
smoke "$HEALTH_READY"       "$BASE_URL/sessions/v1/health/ready"
# Session endpoints require auth — 401 expected
smoke "My sessions (no auth)" "$BASE_URL/sessions/v1/sessions/mine" "401"
echo ""

t1=$(date +%s)
elapsed=$((t1 - t0))

echo -e "${BOLD}Results:${NC} ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}  (${elapsed}s)"

if [[ "$FAILED" -gt 0 ]]; then
  echo -e "${RED}${BOLD}✗ Smoke test failed${NC}"
  exit 1
fi

echo -e "${GREEN}${BOLD}✓ All new service smoke checks passed${NC}"
