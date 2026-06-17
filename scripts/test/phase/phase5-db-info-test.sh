# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    phase5-db-info-test.sh                             :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/bin/bash

# Phase 5 Test: REST Metadata Retrieval
# Validates REST metadata endpoint exposure through Kong

BASE_URL="${BASE_URL:-http://localhost:8000}"
TIMEOUT="${TIMEOUT:-10}"
APIKEY="${APIKEY:-public-anon-key}"
TMPDIR="/tmp/phase5_db_info"

mkdir -p "$TMPDIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
readonly CURL_FMT='%{http_code}'
readonly HDR_APIKEY="apikey: $APIKEY"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./test-ui.sh
source "$SCRIPT_DIR/test-ui.sh"

pass() {
    local name="$1"
    echo -e "${GREEN}✓${NC} $name"
    ((++TESTS_PASSED)) || true
    return 0
}

fail() {
    local name="$1"
    local details="$2"
    echo -e "${RED}✗${NC} $name${details:+ ($details)}"
    ((++TESTS_FAILED)) || true
    return 0
}

ui_banner "Phase 5 Test Suite" "REST metadata retrieval"
ui_kv "Base URL" "$BASE_URL"
ui_kv "API key" "$APIKEY"
ui_hr

ui_step "Step 1: Retrieve database info from available gateway route"

SELECTED_ENDPOINT="/rest/v1/"
SELECTED_FILE="$TMPDIR/rest_openapi.json"

REST_HTTP=$(curl -sS -o "$SELECTED_FILE" -w "$CURL_FMT" \
    -X GET "$BASE_URL$SELECTED_ENDPOINT" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" 2>/dev/null || echo "000")

if [[ "$REST_HTTP" == "200" ]]; then
    pass "Database info endpoint reachable"
    echo -e "${GREEN}  └─${NC} Using endpoint: $SELECTED_ENDPOINT"
else
    fail "Database info endpoint reachable" "tried /rest/v1/ (HTTP: $REST_HTTP)"
fi

BODY=""
if [[ -n "$SELECTED_FILE" ]]; then
    BODY=$(cat "$SELECTED_FILE" 2>/dev/null || echo "")
fi

if [[ -n "$SELECTED_FILE" ]] && jq -e . "$SELECTED_FILE" >/dev/null 2>&1; then
    pass "Response is valid JSON"
else
    fail "Response is valid JSON" "invalid JSON payload"
fi

ui_step "Step 2: Validate database metadata presence"

if [[ -n "$SELECTED_FILE" ]] && jq -e '
    (.info.version? != null) or
    (.version? != null) or
    (.database? != null) or
    (.db? != null) or
    (.postgres_version? != null)
' "$SELECTED_FILE" >/dev/null 2>&1; then
    pass "Contains database/version metadata"
else
    fail "Contains database/version metadata" "expected version/database field in response"
fi

if [[ -n "$SELECTED_FILE" ]] && jq -e '
    (.paths? != null) or
    (.schemas? != null) or
    (.tables? != null)
' "$SELECTED_FILE" >/dev/null 2>&1; then
    pass "Contains schema/introspection data"
else
    fail "Contains schema/introspection data" "expected paths/schemas/tables in response"
fi

# Optional diagnostic summary for operator visibility.
if [[ -n "$SELECTED_ENDPOINT" ]]; then
    echo -e "${YELLOW}Info payload preview:${NC} ${BODY:0:200}"
fi

ui_summary "$TESTS_PASSED" "$TESTS_FAILED" "REST metadata retrieval test passed!" "Phase 5 has failing tests"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
else
    exit 0
fi
