# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    phase1-smoke-test.sh                               :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/bin/bash

# Phase 1 Smoke Test: Kong routing + Auth + REST access
# Validates signup -> login -> JWT claims -> PostgREST with positive and negative auth paths

BASE_URL="${BASE_URL:-http://localhost:8000}"
TIMEOUT="${TIMEOUT:-10}"
APIKEY="${APIKEY:-public-anon-key}"
TMPDIR="/tmp/phase1_smoke"

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

test_one_of() {
    local name="$1"
    local actual="$2"
    shift 2
    local allowed=("$@")

    for expected in "${allowed[@]}"; do
        if [[ "$actual" == "$expected" ]]; then
            echo -e "${GREEN}✓${NC} $name (got: $actual)"
            ((++TESTS_PASSED))
            return
        fi
    done

    echo -e "${RED}✗${NC} $name (expected one of: ${allowed[*]}, got: $actual)"
    ((++TESTS_FAILED))
    return 0
}

ui_banner "Phase 1 Smoke Test Suite" "Kong routing + Auth + REST access"
ui_kv "Base URL" "$BASE_URL"
ui_kv "API key" "$APIKEY"
ui_hr

# 1. Gateway health with API key
ui_step "Test 1: Kong -> GoTrue health"
HEALTH_HTTP=$(curl -sS -o "$TMPDIR/health.json" -w "$CURL_FMT" \
    -X GET "$BASE_URL/auth/v1/health" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" 2>/dev/null || echo "000")
test_case "Auth health HTTP status" "200" "$HEALTH_HTTP"

# 2. SIGNUP TEST
ui_step "Test 2: Signup via Kong /auth/v1/signup"
EMAIL="phase1_$(date +%s)@example.com"
PASS='test1234!'

SIGNUP_HTTP=$(curl -sS -o "$TMPDIR/signup.json" -w "$CURL_FMT" \
    -X POST "$BASE_URL/auth/v1/signup" \
    -H "$CT_JSON" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" \
    -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" 2>/dev/null || echo "000")

test_case "Signup HTTP status" "200" "$SIGNUP_HTTP"

if [[ "$SIGNUP_HTTP" == "200" ]]; then
    USER_ID=$(jq -r '.id // .user.id // empty' "$TMPDIR/signup.json" 2>/dev/null || true)
    if [[ -n "$USER_ID" ]]; then
        echo -e "${GREEN}  └─${NC} User created: $USER_ID"
        ((++TESTS_PASSED))
    else
        echo -e "${RED}✗${NC} Signup response contains user id"
        ((++TESTS_FAILED))
    fi
fi

# 3. LOGIN TEST
ui_step "Test 3: Login via Kong /auth/v1/token"

LOGIN_HTTP=$(curl -sS -o "$TMPDIR/login.json" -w "$CURL_FMT" \
    -X POST "$BASE_URL/auth/v1/token?grant_type=password" \
    -H "$CT_JSON" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" \
    -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" 2>/dev/null || echo "000")

test_case "Login HTTP status" "200" "$LOGIN_HTTP"

TOKEN=$(jq -r '.access_token // empty' "$TMPDIR/login.json" 2>/dev/null || true)
REFRESH_TOKEN=$(jq -r '.refresh_token // empty' "$TMPDIR/login.json" 2>/dev/null || true)
TOKEN_LEN=${#TOKEN}

if [[ $TOKEN_LEN -gt 100 ]]; then
    test_case "Access token issued" "true" "true"
    echo -e "${GREEN}  └─${NC} Token length: $TOKEN_LEN bytes"
else
    test_case "Access token issued" "true" "false"
fi

if [[ -n "$REFRESH_TOKEN" ]]; then
    test_case "Refresh token issued" "true" "true"
else
    test_case "Refresh token issued" "true" "false"
fi

ROLE=$(echo "$TOKEN" | python3 -c "
import json, base64, sys
try:
    token = sys.stdin.read().strip()
    payload = token.split('.')[1]
    padding = 4 - len(payload) % 4
    if padding != 4:
        payload += '=' * padding
    decoded = base64.urlsafe_b64decode(payload)
    claims = json.loads(decoded)
    print(claims.get('role', ''))
except Exception:
    print('')
" 2>/dev/null || true)

test_case "JWT role claim" "authenticated" "$ROLE"

# 4. REST WITHOUT TOKEN TEST
ui_step "Test 4: PostgREST access without token (anon behavior)"
REST_NO_AUTH=$(curl -sS -o "$TMPDIR/rest_no_auth.json" -w "$CURL_FMT" \
    -X GET "$BASE_URL/rest/v1/" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" 2>/dev/null || echo "000")
test_one_of "PostgREST no bearer token" "$REST_NO_AUTH" "200" "401"

# 5. REST WITH TOKEN TEST (main validation)
ui_step "Test 5: PostgREST access with JWT"
if [[ -n "$TOKEN" ]]; then
    REST_WITH_AUTH=$(curl -sS -o "$TMPDIR/rest_with_auth.json" -w "$CURL_FMT" \
        -X GET "$BASE_URL/rest/v1/" \
        -H "$HDR_APIKEY" \
        -H "Authorization: Bearer $TOKEN" \
        --max-time "$TIMEOUT" 2>/dev/null || echo "000")
    test_case "JWT-authenticated access" "200" "$REST_WITH_AUTH"
else
    test_case "JWT-authenticated access" "200" "skip"
fi

# 6. NEGATIVE JWT TEST
ui_step "Test 6: Invalid JWT is rejected"
INVALID_REST_HTTP=$(curl -sS -o "$TMPDIR/rest_invalid_jwt.json" -w "$CURL_FMT" \
    -X GET "$BASE_URL/rest/v1/" \
    -H "$HDR_APIKEY" \
    -H 'Authorization: Bearer invalid.jwt.token' \
    --max-time "$TIMEOUT" 2>/dev/null || echo "000")
test_one_of "Invalid JWT rejected" "$INVALID_REST_HTTP" "401" "403"

# 7. KONG HEADERS TEST
ui_step "Test 7: Verify Kong proxied request"
HEADERS=$(curl -sS -i -X GET "$BASE_URL/auth/v1/health" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" 2>/dev/null | head -n 20 || true)

if echo "$HEADERS" | grep -qi "kong\|x-kong"; then
    test_case "Kong proxy identified" "true" "true"
else
    test_case "Kong proxy identified" "true" "false"
fi

ui_summary "$TESTS_PASSED" "$TESTS_FAILED" "Phase 1 flow validated!" "Some tests failed"

if [[ $TESTS_FAILED -eq 0 ]]; then
    exit 0
else
    exit 1
fi
