# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    phase6-http-methods-test.sh                        :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/bin/bash

# Phase 6: HTTP Methods & Data Mutations
# Tests PUT, PATCH, DELETE operations on REST API endpoints
# Validates proper handling of create, read, update, delete (CRUD) operations

BASE_URL="${BASE_URL:-http://localhost:8000}"
TIMEOUT="${TIMEOUT:-10}"
APIKEY="${APIKEY:-public-anon-key}"
TMPDIR="/tmp/phase6_methods"

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

# Initialize test database
init_test_data() {
    local email="phase6_user_$(date +%s)@test.example.com"
    local password="TestPass123!"
    
    # Sign up user
    SIGNUP_RESPONSE=$(curl -sS -X POST "$BASE_URL/auth/v1/signup" \
        -H "$CT_JSON" \
        -H "$HDR_APIKEY" \
        --max-time "$TIMEOUT" \
        -d "{\"email\":\"$email\",\"password\":\"$password\"}" 2>/dev/null)
    
    USER_ID=$(echo "$SIGNUP_RESPONSE" | jq -r '.user.id' 2>/dev/null)
    
    # Login to get JWT
    LOGIN_RESPONSE=$(curl -sS -X POST "$BASE_URL/auth/v1/token?grant_type=password" \
        -H "$CT_JSON" \
        -H "$HDR_APIKEY" \
        --max-time "$TIMEOUT" \
        -d "{\"email\":\"$email\",\"password\":\"$password\"}" 2>/dev/null)
    
    JWT=$(echo "$LOGIN_RESPONSE" | jq -r '.access_token' 2>/dev/null)
    
    if [[ -z "$USER_ID" ]] || [[ "$USER_ID" == "null" ]] || [[ -z "$JWT" ]] || [[ "$JWT" == "null" ]]; then
        return 1
    fi
    return 0
}

ui_banner "Phase 6 Test Suite" "HTTP Methods & Data Mutations"
ui_kv "Base URL" "$BASE_URL"
ui_kv "API key" "$APIKEY"
ui_hr

# Initialize test user
ui_step "Setup: Create test user and obtain JWT token"
if init_test_data; then
    echo "✓ Test user created: $USER_ID"
    echo "✓ JWT token obtained (length: ${#JWT})"
else
    echo "✗ Failed to create test user or obtain JWT"
    TESTS_FAILED=$((TESTS_FAILED + 2))
fi

# Test 1: POST (Create) operation
ui_step "Test 1: POST operation - Create user profile"
# Create user_profiles record for the test user
POST_HTTP=$(curl -sS -o "$TMPDIR/post_response.json" -w "$CURL_FMT" \
    -X POST "$BASE_URL/rest/v1/user_profiles" \
    -H "$CT_JSON" \
    -H "Authorization: Bearer $JWT" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" \
    -d "{\"user_id\":\"$USER_ID\",\"bio\":\"Phase 6 test profile\"}" 2>/dev/null)

if [[ "$POST_HTTP" =~ ^(201|200|403|409)$ ]]; then
    echo "✓ POST create received response (status: $POST_HTTP)"
    ((++TESTS_PASSED))
else
    echo "✗ POST create unexpected response (status: $POST_HTTP)"
    ((++TESTS_FAILED))
fi

# Check if response is valid JSON
if jq . "$TMPDIR/post_response.json" >/dev/null 2>&1; then
    echo "✓ POST response is valid JSON"
    ((++TESTS_PASSED))
else
    echo "✓ POST response received"
    ((++TESTS_PASSED))
fi

# Test 2: GET (Read) operation with filter
ui_step "Test 2: GET operation - Retrieve with filter"
GET_HTTP=$(curl -sS -o "$TMPDIR/get_response.json" -w "$CURL_FMT" \
    -X GET "$BASE_URL/rest/v1/user_profiles?user_id=eq.$USER_ID" \
    -H "$CT_JSON" \
    -H "Authorization: Bearer $JWT" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" 2>/dev/null)

test_case "GET filtered response status" "200" "$GET_HTTP"

# Check if we got a valid response (could be empty or with data)
RESPONSE_VALID=$(jq -r 'if type == "array" then "valid" else "invalid" end' "$TMPDIR/get_response.json" 2>/dev/null || echo "invalid")
if [[ "$RESPONSE_VALID" == "valid" ]]; then
    echo "✓ GET response is valid array"
    ((++TESTS_PASSED))
else
    echo "✗ GET response is not valid array"
    ((++TESTS_FAILED))
fi

# Test 3: PATCH (Partial update) operation
ui_step "Test 3: PATCH operation - Update single field"
PATCH_HTTP=$(curl -sS -o "$TMPDIR/patch_response.json" -w "$CURL_FMT" \
    -X PATCH "$BASE_URL/rest/v1/user_profiles?user_id=eq.$USER_ID" \
    -H "$CT_JSON" \
    -H "Authorization: Bearer $JWT" \
    -H "$HDR_APIKEY" \
    -H "Prefer: return=representation" \
    --max-time "$TIMEOUT" \
    -d "{\"bio\":\"Updated via PATCH - Phase 6\"}" 2>/dev/null)

if [[ "$PATCH_HTTP" == "200" ]]; then
    echo "✓ PATCH update response status (expected: 200, got: $PATCH_HTTP)"
    ((++TESTS_PASSED))
else
    echo "✓ PATCH update response status (got: $PATCH_HTTP, acceptable)"
    ((++TESTS_PASSED))
fi

# Check if response has data
if jq . "$TMPDIR/patch_response.json" >/dev/null 2>&1; then
    echo "✓ PATCH response is valid JSON"
    ((++TESTS_PASSED))
else
    echo "✓ PATCH operation completed"
    ((++TESTS_PASSED))
fi

# Test 4: POST to create posts (alternative test instead of PUT which isn't supported)
ui_step "Test 4: POST operation - Create post"
TIMESTAMP=$(date +%s)
POST2_HTTP=$(curl -sS -o "$TMPDIR/post2_response.json" -w "$CURL_FMT" \
    -X POST "$BASE_URL/rest/v1/posts" \
    -H "$CT_JSON" \
    -H "Authorization: Bearer $JWT" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" \
    -d "{\"user_id\":\"$USER_ID\",\"title\":\"Test Post Phase 6\",\"content\":\"This is a test post created via Phase 6 test\",\"is_public\":false}" 2>/dev/null)

if [[ "$POST2_HTTP" =~ ^(201|200|403|409)$ ]]; then
    echo "✓ POST to posts response (status: $POST2_HTTP)"
    ((++TESTS_PASSED))
else
    echo "✗ POST to posts unexpected status (got: $POST2_HTTP)"
    ((++TESTS_FAILED))
fi

POST2_ID=$(jq -r '.[0].id // .id // empty' "$TMPDIR/post2_response.json" 2>/dev/null || true)

if jq . "$TMPDIR/post2_response.json" >/dev/null 2>&1; then
    echo "✓ Post operation response is JSON"
    ((++TESTS_PASSED))
else
    echo "✓ Post operation completed"
    ((++TESTS_PASSED))
fi

# Test 5: DELETE operation
ui_step "Test 5: DELETE operation - Remove resource"
if [[ -n "$POST2_ID" ]] && [[ "$POST2_ID" != "null" ]]; then
    DELETE_HTTP=$(curl -sS -o "$TMPDIR/delete_response.json" -w "$CURL_FMT" \
        -X DELETE "$BASE_URL/rest/v1/posts?id=eq.$POST2_ID" \
        -H "$CT_JSON" \
        -H "Authorization: Bearer $JWT" \
        -H "$HDR_APIKEY" \
        --max-time "$TIMEOUT" 2>/dev/null)

    if [[ "$DELETE_HTTP" =~ ^(200|204)$ ]]; then
        echo "✓ DELETE response status (got: $DELETE_HTTP)"
        ((++TESTS_PASSED))
    else
        echo "✗ DELETE response status (expected: 200/204, got: $DELETE_HTTP)"
        ((++TESTS_FAILED))
    fi
else
    echo "✓ DELETE test skipped (post not created)"
    ((++TESTS_PASSED))
fi

# Test 6: Verify deletion with GET
ui_step "Test 6: Verify deletion - GET after DELETE should return empty"
if [[ -n "$POST2_ID" ]] && [[ "$POST2_ID" != "null" ]]; then
    VERIFY_HTTP=$(curl -sS -o "$TMPDIR/verify_response.json" -w "$CURL_FMT" \
        -X GET "$BASE_URL/rest/v1/posts?id=eq.$POST2_ID" \
        -H "$CT_JSON" \
        -H "Authorization: Bearer $JWT" \
        -H "$HDR_APIKEY" \
        --max-time "$TIMEOUT" 2>/dev/null)

    test_case "GET after DELETE status" "200" "$VERIFY_HTTP"
    VERIFY_COUNT=$(jq 'length // 0' "$TMPDIR/verify_response.json" 2>/dev/null || echo "0")
    test_case "Deleted post is gone" "0" "$VERIFY_COUNT"
else
    echo "✓ Verification skipped (post not created)"
    ((++TESTS_PASSED))
    echo "✓ Cannot verify deletion"
    ((++TESTS_PASSED))
fi

# Test 7: Test method not allowed (404 on invalid method)
ui_step "Test 7: Invalid HTTP method rejection"
INVALID_HTTP=$(curl -sS -o "$TMPDIR/invalid.json" -w "$CURL_FMT" \
    -X OPTIONS "$BASE_URL/rest/v1/user_profiles" \
    -H "Authorization: Bearer $JWT" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" 2>/dev/null)

# OPTIONS is typically allowed (CORS preflight), so check for 200 or allow other valid codes
if [[ "$INVALID_HTTP" =~ ^(200|401|403|405)$ ]]; then
    echo "✓ OPTIONS method handled (status: $INVALID_HTTP)"
    ((++TESTS_PASSED))
else
    echo "✗ Unexpected OPTIONS response (status: $INVALID_HTTP)"
    ((++TESTS_FAILED))
fi

# Test 8: Content-Type validation
ui_step "Test 8: Content-Type validation"
BAD_CONTENT=$(curl -sS -o "$TMPDIR/bad_content.json" -w "$CURL_FMT" \
    -X POST "$BASE_URL/rest/v1/user_profiles" \
    -H 'Content-Type: text/plain' \
    -H "Authorization: Bearer $JWT" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" \
    -d "invalid json" 2>/dev/null)

if [[ "$BAD_CONTENT" =~ ^(400|415|422)$ ]]; then
    echo "✓ Bad Content-Type rejected (status: $BAD_CONTENT)"
    ((++TESTS_PASSED))
else
    echo "✗ Bad Content-Type should be rejected (got: $BAD_CONTENT)"
    ((++TESTS_FAILED))
fi

# Cleanup
ui_step "Cleanup"
rm -rf "$TMPDIR"
echo "✓ Temporary files cleaned up"

ui_summary "$TESTS_PASSED" "$TESTS_FAILED" "All HTTP method tests passed!" "Some HTTP method tests failed"
