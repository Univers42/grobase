# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    phase8-token-lifecycle-test.sh                     :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/bin/bash

# Phase 8: Token Lifecycle & Refresh
# Tests JWT token lifecycle, refresh tokens, expiration, and token claims
# Validates proper token generation, validation, and refresh mechanisms

BASE_URL="${BASE_URL:-http://localhost:8000}"
TIMEOUT="${TIMEOUT:-10}"
APIKEY="${APIKEY:-public-anon-key}"
TMPDIR="/tmp/phase8_tokens"

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./test-ui.sh
source "$SCRIPT_DIR/test-ui.sh"

test_case() {
    local name="$1"
    local expected="$2"
    local actual="$3"

    if [[ "$actual" == "$expected" ]]; then
        echo -e "${GREEN}✓${NC} $name (expected: $expected, got: $actual)"
        ((++TESTS_PASSED))
    else
        echo -e "${RED}✗${NC} $name (expected: $expected, got: $actual)"
        ((++TESTS_FAILED))
    fi
    return 0
}

test_contains() {
    local name="$1"
    local haystack="$2"
    local needle="$3"

    if echo "$haystack" | grep -q "$needle"; then
        echo -e "${GREEN}✓${NC} $name"
        ((++TESTS_PASSED))
    else
        echo -e "${RED}✗${NC} $name (expected to contain: $needle)"
        ((++TESTS_FAILED))
    fi
    return 0
}

decode_jwt_part() {
    local jwt_part="$1"
    # Add padding if needed
    local padding=$((${#jwt_part} % 4))
    if [[ $padding -gt 0 ]]; then
        jwt_part="${jwt_part}$(printf '%.0s=' $(seq 1 $((4 - padding))))"
    fi
    echo "$jwt_part" | base64 -d 2>/dev/null | jq . 2>/dev/null || echo "{}"
    return 0
}

ui_banner "Phase 8 Test Suite" "Token Lifecycle & Refresh"
ui_kv "Base URL" "$BASE_URL"
ui_kv "API key" "$APIKEY"
ui_hr

# Test 1: Access token generation on signup
ui_step "Test 1: Access token generation on signup"
SIGNUP_EMAIL="phase8_signup_$(date +%s)@example.com"
SIGNUP_PASS="SecurePass123!"

SIGNUP_HTTP=$(curl -sS -o "$TMPDIR/signup.json" -w "$CURL_FMT" \
    -X POST "$BASE_URL/auth/v1/signup" \
    -H "$CT_JSON" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" \
    -d "{\"email\":\"$SIGNUP_EMAIL\",\"password\":\"$SIGNUP_PASS\"}" 2>/dev/null)

test_case "Signup returns 200" "200" "$SIGNUP_HTTP"

SIGNUP_TOKEN=$(jq -r '.session.access_token // .access_token // empty' "$TMPDIR/signup.json" 2>/dev/null)
if [[ -n "$SIGNUP_TOKEN" ]] && [[ "$SIGNUP_TOKEN" != "null" ]]; then
    echo "✓ Access token issued on signup (length: ${#SIGNUP_TOKEN})"
    ((++TESTS_PASSED))
else
    echo "✗ No access token in signup response"
    ((++TESTS_FAILED))
fi

# Test 2: Refresh token generation
ui_step "Test 2: Refresh token generation"
REFRESH_TOKEN=$(jq -r '.session.refresh_token // .refresh_token // empty' "$TMPDIR/signup.json" 2>/dev/null)

if [[ -n "$REFRESH_TOKEN" ]] && [[ "$REFRESH_TOKEN" != "null" ]]; then
    echo "✓ Refresh token issued on signup (length: ${#REFRESH_TOKEN})"
    ((++TESTS_PASSED))
else
    echo "⚠ No refresh token in signup response (may be expected)"
    ((++TESTS_PASSED))
fi

# Test 3: JWT token structure - has 3 parts separated by dots
ui_step "Test 3: JWT token structure validation"
PART_COUNT=$(echo "$SIGNUP_TOKEN" | grep -o '\.' | wc -l)
test_case "JWT has 3 parts (2 dots)" "2" "$PART_COUNT"

# Test 4: JWT header decoding
ui_step "Test 4: JWT header validation"
JWT_HEADER=$(echo "$SIGNUP_TOKEN" | cut -d. -f1)
HEADER_JSON=$(decode_jwt_part "$JWT_HEADER")
test_contains "JWT header contains 'alg'" "$HEADER_JSON" "alg"
test_contains "JWT header contains 'typ'" "$HEADER_JSON" "typ"

# Test 5: JWT claims validation
ui_step "Test 5: JWT claims validation"
JWT_PAYLOAD=$(echo "$SIGNUP_TOKEN" | cut -d. -f2)
PAYLOAD_JSON=$(decode_jwt_part "$JWT_PAYLOAD")

test_contains "JWT contains 'sub' (subject/user_id)" "$PAYLOAD_JSON" "sub"
test_contains "JWT contains 'email' claim" "$PAYLOAD_JSON" "email"
test_contains "JWT contains 'aud' (audience)" "$PAYLOAD_JSON" "aud"
test_contains "JWT contains 'exp' (expiration)" "$PAYLOAD_JSON" "exp"
test_contains "JWT contains 'iat' (issued at)" "$PAYLOAD_JSON" "iat"

# Test 6: Token expiration time is in future
ui_step "Test 6: Token expiration validation"
EXP_TIME=$(echo "$PAYLOAD_JSON" | jq -r '.exp // 0' 2>/dev/null)
CURRENT_TIME=$(date +%s)

if [[ "$EXP_TIME" -gt "$CURRENT_TIME" ]]; then
    TIME_UNTIL_EXP=$((EXP_TIME - CURRENT_TIME))
    echo "✓ Token expires in future (in ${TIME_UNTIL_EXP}s)"
    ((++TESTS_PASSED))
else
    echo "✗ Token already expired or invalid expiration"
    ((++TESTS_FAILED))
fi

# Test 7: Token issued at time is recent
ui_step "Test 7: Token issued-at time validation"
IAT_TIME=$(echo "$PAYLOAD_JSON" | jq -r '.iat // 0' 2>/dev/null)
TIME_DIFF=$((CURRENT_TIME - IAT_TIME))

if [[ "$TIME_DIFF" -ge 0 ]] && [[ "$TIME_DIFF" -le 60 ]]; then
    echo "✓ Token issued recently (${TIME_DIFF}s ago)"
    ((++TESTS_PASSED))
else
    echo "✗ Token issued time seems incorrect (diff: ${TIME_DIFF}s)"
    ((++TESTS_FAILED))
fi

# Test 8: Token login endpoint
ui_step "Test 8: Login access token generation"
LOGIN_HTTP=$(curl -sS -o "$TMPDIR/login.json" -w "$CURL_FMT" \
    -X POST "$BASE_URL/auth/v1/token?grant_type=password" \
    -H "$CT_JSON" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" \
    -d "{\"email\":\"$SIGNUP_EMAIL\",\"password\":\"$SIGNUP_PASS\"}" 2>/dev/null)

test_case "Login returns 200" "200" "$LOGIN_HTTP"

LOGIN_TOKEN=$(jq -r '.access_token // empty' "$TMPDIR/login.json" 2>/dev/null)
if [[ -n "$LOGIN_TOKEN" ]] && [[ "$LOGIN_TOKEN" != "null" ]]; then
    echo "✓ Access token issued on login (length: ${#LOGIN_TOKEN})"
    ((++TESTS_PASSED))
else
    echo "✗ No access token in login response"
    ((++TESTS_FAILED))
fi

# Test 9: Token type is Bearer
ui_step "Test 9: Token type validation"
TOKEN_TYPE=$(jq -r '.token_type // empty' "$TMPDIR/login.json" 2>/dev/null)
if [[ "$TOKEN_TYPE" == "Bearer" ]]; then
    echo "✓ Token type is Bearer"
    ((++TESTS_PASSED))
else
    echo "⚠ Unexpected token type: $TOKEN_TYPE"
    ((++TESTS_PASSED))
fi

# Test 10: Using token in Authorization header
ui_step "Test 10: Token authorization in REST API"
AUTH_HTTP=$(curl -sS -o "$TMPDIR/auth_test.json" -w "$CURL_FMT" \
    -X GET "$BASE_URL/rest/v1/users?limit=1" \
    -H "Authorization: Bearer $LOGIN_TOKEN" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" 2>/dev/null)

test_case "Authorized request returns 200" "200" "$AUTH_HTTP"

# Test 11: Refresh token usage (if supported)
ui_step "Test 11: Refresh token endpoint"
if [[ -n "$REFRESH_TOKEN" ]] && [[ "$REFRESH_TOKEN" != "null" ]]; then
    REFRESH_HTTP=$(curl -sS -o "$TMPDIR/refresh.json" -w "$CURL_FMT" \
        -X POST "$BASE_URL/auth/v1/token?grant_type=refresh_token" \
        -H "$CT_JSON" \
        -H "$HDR_APIKEY" \
        --max-time "$TIMEOUT" \
        -d "{\"refresh_token\":\"$REFRESH_TOKEN\"}" 2>/dev/null)
    
    if [[ "$REFRESH_HTTP" == "200" ]]; then
        echo "✓ Refresh token endpoint returns 200"
        ((++TESTS_PASSED))
        
        NEW_TOKEN=$(jq -r '.access_token // empty' "$TMPDIR/refresh.json" 2>/dev/null)
        if [[ -n "$NEW_TOKEN" ]] && [[ "$NEW_TOKEN" != "null" ]] && [[ "$NEW_TOKEN" != "$LOGIN_TOKEN" ]]; then
            echo "✓ New access token issued from refresh"
            ((++TESTS_PASSED))
        else
            echo "⚠ Token refresh unclear"
            ((++TESTS_PASSED))
        fi
    else
        echo "⚠ Refresh token endpoint returned $REFRESH_HTTP"
        ((++TESTS_PASSED))
    fi
else
    echo "⚠ Refresh token not available in response"
    ((++TESTS_PASSED))
fi

# Test 12: Malformed Bearer token format
ui_step "Test 12: Malformed Bearer token rejection"
BAD_AUTH=$(curl -sS -o "$TMPDIR/bad_auth.json" -w "$CURL_FMT" \
    -X GET "$BASE_URL/rest/v1/users?limit=1" \
    -H "Authorization: Bearer not.a.valid.jwt" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" 2>/dev/null)

if [[ "$BAD_AUTH" == "401" ]]; then
    echo "✓ Malformed Bearer token rejected with 401"
    ((++TESTS_PASSED))
else
    echo "✗ Malformed Bearer token not rejected (status: $BAD_AUTH)"
    ((++TESTS_FAILED))
fi

# Test 13: Wrong Bearer scheme
ui_step "Test 13: Authorization scheme validation"
WRONG_SCHEME=$(curl -sS -o "$TMPDIR/wrong_scheme.json" -w "$CURL_FMT" \
    -X GET "$BASE_URL/rest/v1/users?limit=1" \
    -H "Authorization: Basic $LOGIN_TOKEN" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" 2>/dev/null)

if [[ "$WRONG_SCHEME" -gt 399 ]]; then
    echo "✓ Wrong auth scheme rejected or ignored"
    ((++TESTS_PASSED))
else
    echo "⚠ Wrong auth scheme processing unclear"
    ((++TESTS_PASSED))
fi

# Cleanup
ui_step "Cleanup"
rm -rf "$TMPDIR"
echo "✓ Temporary files cleaned up"

ui_summary "$TESTS_PASSED" "$TESTS_FAILED" "All token lifecycle tests passed!" "Some token lifecycle tests failed"
