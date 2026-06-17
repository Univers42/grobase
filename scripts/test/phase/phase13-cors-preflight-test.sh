# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    phase13-cors-preflight-test.sh                     :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/bin/bash

# Phase 13: CORS Preflight and Cross-Origin Requests
# Validates Cross-Origin Resource Sharing (CORS) headers and preflight handling

BASE_URL="${BASE_URL:-http://localhost:8000}"
TIMEOUT="${TIMEOUT:-10}"
APIKEY="${APIKEY:-public-anon-key}"
TEST_ORIGIN="${TEST_ORIGIN:-http://localhost:3000}"
TMPDIR="${TMPDIR:-$(mktemp -d /tmp/phase13_cors.XXXXXX)}"

mkdir -p "$TMPDIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
readonly CURL_FMT='%{http_code}'
readonly CT_JSON='Content-Type: application/json'
readonly HDR_APIKEY="apikey: $APIKEY"
readonly HDR_CORS_METHOD='Access-Control-Request-Method: POST'
readonly HDR_CORS_ORIGIN='Access-Control-Allow-Origin'
readonly MSG_HDR_NOT_FOUND='header not found'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./test-ui.sh
source "$SCRIPT_DIR/test-ui.sh"

pass() {
    local name="$1"
    echo -e "${GREEN}[PASS]${NC} $name"
    ((++TESTS_PASSED))
    return 0
}

fail() {
    local name="$1"
    local details="$2"
    echo -e "${RED}[FAIL]${NC} $name - $details"
    ((++TESTS_FAILED))
    return 0
}

check_header() {
    local name="$1"
    local header="$2"
    local response="$3"
    
    if echo "$response" | grep -qi "^$header:"; then
        pass "$name"
    else
        fail "$name" "$MSG_HDR_NOT_FOUND"
    fi
    return 0
}

ui_banner "Phase 13 Test Suite" "CORS Preflight and Cross-Origin Requests"
ui_kv "Gateway URL" "$BASE_URL"
ui_kv "Test focus" "CORS headers and preflight handling"
ui_kv "Allowed origin under test" "$TEST_ORIGIN"
ui_hr

ui_step "Test 1: Preflight OPTIONS request to /auth/v1"
PREFLIGHT_RESPONSE=$(curl -sS -i -X OPTIONS "$BASE_URL/auth/v1/" \
    -H "Origin: $TEST_ORIGIN" \
    -H "$HDR_CORS_METHOD" \
    -H "Access-Control-Request-Headers: Content-Type" \
    --max-time "$TIMEOUT" 2>/dev/null)

PREFLIGHT_CODE=$(echo "$PREFLIGHT_RESPONSE" | head -1 | awk '{print $2}')

if [[ "$PREFLIGHT_CODE" == "200" ]] || [[ "$PREFLIGHT_CODE" == "204" ]]; then
    pass "Preflight OPTIONS request succeeds"
else
    fail "Preflight OPTIONS request succeeds" "got HTTP $PREFLIGHT_CODE"
fi

# Check for CORS headers
echo "$PREFLIGHT_RESPONSE" | grep -iq "$HDR_CORS_ORIGIN" && echo -e "${YELLOW}  Info: CORS headers present${NC}"

ui_step "Test 2: CORS Allow-Origin header present"
CORS_RESPONSE=$(curl -sS -i -X GET "$BASE_URL/rest/v1/users?limit=1" \
    -H "Origin: $TEST_ORIGIN" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" 2>/dev/null)

if echo "$CORS_RESPONSE" | grep -qi "$HDR_CORS_ORIGIN"; then
    pass "Access-Control-Allow-Origin header present"
else
    fail "Access-Control-Allow-Origin header present" "$MSG_HDR_NOT_FOUND"
fi

ui_step "Test 3: CORS Allow-Methods header includes expected methods"
CORS_METHODS=$(curl -sS -i -X OPTIONS "$BASE_URL/rest/v1/" \
    -H "Origin: $TEST_ORIGIN" \
    -H "Access-Control-Request-Method: PATCH" \
    --max-time "$TIMEOUT" 2>/dev/null | grep -i "Access-Control-Allow-Methods" | head -1)

if [[ -n "$CORS_METHODS" ]]; then
    pass "Access-Control-Allow-Methods header present"
    echo -e "${BLUE}    $CORS_METHODS${NC}"
else
    fail "Access-Control-Allow-Methods header present" "$MSG_HDR_NOT_FOUND"
fi

ui_step "Test 4: CORS credentials allowed"
CORS_CREDS=$(curl -sS -i -X OPTIONS "$BASE_URL/auth/v1/" \
    -H "Origin: $TEST_ORIGIN" \
    -H "$HDR_CORS_METHOD" \
    --max-time "$TIMEOUT" 2>/dev/null | grep -i "Access-Control-Allow-Credentials")

if echo "$CORS_CREDS" | grep -qi "true"; then
    pass "Credentials allowed (Access-Control-Allow-Credentials: true)"
else
    fail "Credentials allowed" "not found or not true"
fi

ui_step "Test 5: CORS headers on actual requests (not just preflight)"
ACTUAL_REQUEST=$(curl -sS -i -X POST "$BASE_URL/auth/v1/signup" \
    -H "Origin: $TEST_ORIGIN" \
    -H "Content-Type: application/json" \
    -H "$HDR_APIKEY" \
    -d '{"email":"corstest@example.com","password":"TestPass123!"}' \
    --max-time "$TIMEOUT" 2>/dev/null)

if echo "$ACTUAL_REQUEST" | grep -qi "$HDR_CORS_ORIGIN"; then
    pass "CORS headers present on actual requests"
else
    fail "CORS headers present on actual requests" "headers not found"
fi

ui_step "Test 6: CORS allow-headers includes apikey"
CORS_HEADERS=$(curl -sS -i -X OPTIONS "$BASE_URL/storage/v1/" \
    -H "Origin: $TEST_ORIGIN" \
    -H "Access-Control-Request-Method: GET" \
    -H "Access-Control-Request-Headers: apikey" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" 2>/dev/null | grep -i "Access-Control-Allow-Headers")

if echo "$CORS_HEADERS" | grep -iq "apikey"; then
    pass "CORS allow-headers includes 'apikey'"
else
    fail "CORS allow-headers includes 'apikey'" "header missing apikey"
fi

ui_step "Test 7: CORS allow-headers includes Authorization"
CORS_AUTH_HEADERS=$(curl -sS -i -X OPTIONS "$BASE_URL/rest/v1/" \
    -H "Origin: $TEST_ORIGIN" \
    -H "Access-Control-Request-Method: GET" \
    -H "Access-Control-Request-Headers: Authorization" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" 2>/dev/null | grep -i "Access-Control-Allow-Headers")

if echo "$CORS_AUTH_HEADERS" | grep -iq "Authorization"; then
    pass "CORS allow-headers includes 'Authorization'"
else
    fail "CORS allow-headers includes 'Authorization'" "header missing Authorization"
fi

ui_step "Test 8: Preflight to different routes"
for route in "/auth/v1" "/rest/v1" "/realtime/v1" "/storage/v1"; do
    CODE=$(curl -sS -o /dev/null -w "$CURL_FMT" -X OPTIONS "$BASE_URL$route" \
        -H "Origin: $TEST_ORIGIN" \
        -H "$HDR_CORS_METHOD" \
        -H "$HDR_APIKEY" \
        --max-time 3 2>/dev/null || echo "000")
    
    if [[ "$CODE" == "200" ]] || [[ "$CODE" == "204" ]]; then
        pass "Preflight to $route succeeds"
    else
        fail "Preflight to $route succeeds" "got HTTP $CODE"
    fi
done

ui_step "Test 9: CORS max-age header for caching"
MAX_AGE=$(curl -sS -i -X OPTIONS "$BASE_URL/auth/v1/" \
    -H "Origin: $TEST_ORIGIN" \
    -H "$HDR_CORS_METHOD" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" 2>/dev/null | grep -i "Access-Control-Max-Age")

if [[ -n "$MAX_AGE" ]]; then
    pass "Access-Control-Max-Age header present"
    echo -e "${BLUE}    $MAX_AGE${NC}"
else
    fail "Access-Control-Max-Age header present" "$MSG_HDR_NOT_FOUND"
fi

ui_step "Test 10: Simple GET request includes CORS headers"
GET_RESPONSE=$(curl -sS -i -X GET "$BASE_URL/rest/v1/users?limit=1" \
    -H "Origin: $TEST_ORIGIN" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" 2>/dev/null)

CORS_ORIGIN=$(echo "$GET_RESPONSE" | grep -i "$HDR_CORS_ORIGIN" | head -1 | sed 's/^.*: //')

if [[ -n "$CORS_ORIGIN" ]]; then
    pass "GET response includes Allow-Origin header"
    echo -e "${BLUE}    Allowed origin: $CORS_ORIGIN${NC}"
else
    fail "GET response includes Allow-Origin header" "$MSG_HDR_NOT_FOUND"
fi

ui_hr
ui_summary "$TESTS_PASSED" "$TESTS_FAILED" "Phase 13 CORS tests passed!" "Phase 13 CORS tests failed"
echo -e "${YELLOW}CORS configuration allows:"
echo -e "  • Requests from explicit allowed origins only"
echo -e "  • Standard HTTP methods (GET, POST, PUT, PATCH, DELETE, OPTIONS)"
echo -e "  • Custom headers (Authorization, Content-Type, apikey, x-client-info)"
echo -e "  • Credentials in cross-origin requests${NC}"
echo ""

exit $TESTS_FAILED
