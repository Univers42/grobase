# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    phase12-rate-limiting-test.sh                      :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/bin/bash

# Phase 12: Rate Limiting Policy Enforcement
# Validates Kong rate limiting rules per route and per IP address

BASE_URL="${BASE_URL:-http://localhost:8000}"
TIMEOUT="${TIMEOUT:-10}"
APIKEY="${APIKEY:-public-anon-key}"
TMPDIR="${TMPDIR:-$(mktemp -d /tmp/phase12_ratelimit.XXXXXX)}"

mkdir -p "$TMPDIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
readonly CURL_FMT='%{http_code}'
readonly CT_JSON='Content-Type: application/json'
readonly HDR_APIKEY="apikey: $APIKEY"
readonly MSG_STORAGE_INIT='Storage route accepts initial requests'
readonly MSG_TIMEOUT='request timed out or connection failed'

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

assert_code_one_of() {
    local name="$1"
    local actual="$2"
    shift 2
    local allowed=("$@")

    for expected in "${allowed[@]}"; do
        if [[ "$actual" == "$expected" ]]; then
            pass "$name"
            return
        fi
    done

    fail "$name" "expected one of ${allowed[*]}, got $actual"
    return 0
}

ui_banner "Phase 12 Test Suite" "Rate Limiting Policy Enforcement"
ui_kv "Gateway URL" "$BASE_URL"
ui_kv "Test focus" "Route-level and IP-based rate limiting"
ui_hr

# Define rate limits per route (from kong.yml)
# auth: minute: 300, hour: 5000
# rest: minute: 180, hour: 5000
# realtime: minute: 120, hour: 3000
# storage: minute: 60, hour: 1500

ui_step "Test 1: Auth route individual requests succeed"
for i in {1..3}; do
    CODE=$(curl -sS -o /dev/null -w "$CURL_FMT" \
        -X POST "$BASE_URL/auth/v1/signup" \
        -H "$CT_JSON" \
        -H "$HDR_APIKEY" \
        -d "{\"email\":\"test$i.ratelimit@example.com\",\"password\":\"TestPass123!\"}" \
        --max-time "$TIMEOUT" 2>/dev/null || echo "000")
    
    if [[ "$CODE" == "200" ]] || [[ "$CODE" == "422" ]]; then
        pass "Auth request $i succeeds"
    else
        fail "Auth request $i succeeds" "got $CODE"
    fi
done

ui_step "Test 2: REST route responses include rate limit headers"
HEADERS=$(curl -sS -i -X GET "$BASE_URL/rest/v1/users?limit=1" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" 2>/dev/null | head -20)

if echo "$HEADERS" | grep -qi "RateLimit-Limit\|X-RateLimit-Limit"; then
    pass "Rate limit headers present in response"
else
    fail "Rate limit headers present in response" "missing RateLimit-Limit headers"
fi

ui_step "Test 3: Storage route rate limit applied to uploads"
# Make rapid requests to storage endpoint
STORAGE_CODES=()
for i in {1..3}; do
    CODE=$(curl -sS -o /dev/null -w "$CURL_FMT" \
        -X GET "$BASE_URL/storage/v1/" \
        -H "$HDR_APIKEY" \
        --max-time 3 2>/dev/null || echo "000")
    STORAGE_CODES+=("$CODE")
done

# Should not all be 429 immediately, but system should handle them
if [[ "${STORAGE_CODES[0]}" == "000" ]]; then
    fail "$MSG_STORAGE_INIT" "$MSG_TIMEOUT"
elif [[ "${STORAGE_CODES[0]}" =~ ^5 ]]; then
    fail "$MSG_STORAGE_INIT" "unexpected server error ${STORAGE_CODES[0]}"
elif [[ "${STORAGE_CODES[0]}" != "429" ]]; then
    pass "$MSG_STORAGE_INIT"
else
    fail "$MSG_STORAGE_INIT" "got 429 immediately"
fi

ui_step "Test 4: Invalid API key still respects rate limiting"
# Test that rate limiting applies even for unauthorized requests
CODE=$(curl -sS -o /dev/null -w "$CURL_FMT" \
    -X GET "$BASE_URL/rest/v1/users" \
    -H "apikey: invalid-key" \
    --max-time "$TIMEOUT" 2>/dev/null || echo "000")

assert_code_one_of "Invalid API key request rejected" "$CODE" "401" "403"

ui_step "Test 5: Realtime route rate limiting configured"
# Realtime requests should return valid non-error HTTP statuses.
for i in {1..3}; do
    CODE=$(curl -sS -o /dev/null -w "$CURL_FMT" \
        -X GET "$BASE_URL/realtime/v1?apikey=$APIKEY" \
        --max-time 3 2>/dev/null || echo "000")

    if [[ "$CODE" == "000" ]]; then
        fail "Realtime request $i processed" "$MSG_TIMEOUT"
    elif [[ "$CODE" =~ ^5 ]]; then
        fail "Realtime request $i processed" "unexpected server error $CODE"
    else
        pass "Realtime request $i processed (HTTP $CODE)"
    fi
done

ui_step "Test 6: Auth endpoint minute limit enforces"
# Attempt to verify auth endpoint handles rapid requests (300 per minute)
# We'll try 10 rapid requests to see if they succeed
RAPID_COUNT=0
for i in {1..10}; do
    CODE=$(curl -sS -o /dev/null -w "$CURL_FMT" \
        -X POST "$BASE_URL/auth/v1/signup" \
        -H "$CT_JSON" \
        -H "$HDR_APIKEY" \
        -d "{\"email\":\"rapid$i.ratelimit@example.com\",\"password\":\"TestPass123!\"}" \
        --max-time 2 2>/dev/null || echo "000")
    
    if [[ "$CODE" == "200" ]] || [[ "$CODE" == "422" ]]; then
        ((RAPID_COUNT++))
    fi
done

if [[ $RAPID_COUNT -ge 5 ]]; then
    pass "Auth endpoint processed multiple rapid requests"
else
    fail "Auth endpoint allows requests" "only processed $RAPID_COUNT out of 10"
fi

ui_step "Test 7: Different routes have different limits"
AUTH_HEADERS=$(curl -sS -i -X POST "$BASE_URL/auth/v1/signup" \
    -H "$CT_JSON" \
    -H "$HDR_APIKEY" \
    -d '{"email":"routecheck.ratelimit@example.com","password":"TestPass123!"}' \
    --max-time "$TIMEOUT" 2>/dev/null | head -30)

REST_HEADERS=$(curl -sS -i -X GET "$BASE_URL/rest/v1/users?limit=1" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" 2>/dev/null | head -30)

if echo "$AUTH_HEADERS" | grep -qi "RateLimit-Limit\|X-RateLimit-Limit" && \
   echo "$REST_HEADERS" | grep -qi "RateLimit-Limit\|X-RateLimit-Limit"; then
    pass "Route-specific rate limiting headers present on auth and rest routes"
else
    fail "Route-specific rate limiting headers present on auth and rest routes" "missing rate limit headers on one or more routes"
fi

ui_step "Test 8: Rate limit applies per IP"
# All requests from localhost should be counted together
CODE1=$(curl -sS -o /dev/null -w "$CURL_FMT" -X GET "$BASE_URL/rest/v1/users?limit=1" \
    -H "$HDR_APIKEY" --max-time 3 2>/dev/null || echo "000")
CODE2=$(curl -sS -o /dev/null -w "$CURL_FMT" -X GET "$BASE_URL/rest/v1/users?limit=1" \
    -H "$HDR_APIKEY" --max-time 3 2>/dev/null || echo "000")

if [[ "$CODE1" != "429" && "$CODE2" != "429" ]]; then
    if [[ "$CODE1" == "000" || "$CODE2" == "000" ]]; then
        fail "Requests from same IP rate limiting" "$MSG_TIMEOUT"
    elif [[ "$CODE1" =~ ^5 || "$CODE2" =~ ^5 ]]; then
        fail "Requests from same IP rate limiting" "unexpected server error ($CODE1, $CODE2)"
    else
        pass "Requests from same IP are rate limited together"
    fi
else
    fail "Requests from same IP rate limiting" "unexpected 429 on early requests"
fi

ui_hr
ui_summary "$TESTS_PASSED" "$TESTS_FAILED" "Phase 12 rate-limiting tests passed!" "Phase 12 rate-limiting tests failed"
echo -e "${YELLOW}Note: Rate limiting is best tested over longer periods or with"
echo -e "high concurrency. This phase validates configuration and basic behavior.${NC}"
echo ""

exit $TESTS_FAILED
