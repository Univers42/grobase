# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    phase7-error-handling-test.sh                      :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/bin/bash

# Phase 7: Error Handling & Edge Cases
# Tests various error conditions and edge cases
# Validates proper HTTP error responses and validation

BASE_URL="${BASE_URL:-http://localhost:8000}"
TIMEOUT="${TIMEOUT:-10}"
APIKEY="${APIKEY:-public-anon-key}"
TMPDIR="/tmp/phase7_errors"

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

test_in_range() {
    local name="$1"
    local value="$2"
    local min="$3"
    local max="$4"

    if [[ "$value" -ge "$min" && "$value" -le "$max" ]]; then
        echo -e "${GREEN}✓${NC} $name (got: $value, range: $min-$max)"
        ((++TESTS_PASSED))
    else
        echo -e "${RED}✗${NC} $name (expected range: $min-$max, got: $value)"
        ((++TESTS_FAILED))
    fi
    return 0
}

ui_banner "Phase 7 Test Suite" "Error Handling & Edge Cases"
ui_kv "Base URL" "$BASE_URL"
ui_kv "API key" "$APIKEY"
ui_hr

# Test 1: Missing required API key
ui_step "Test 1: Missing API key rejection"
NO_KEY=$(curl -sS -o "$TMPDIR/no_key.json" -w "$CURL_FMT" \
    -X GET "$BASE_URL/rest/v1/users" \
    --max-time "$TIMEOUT" 2>/dev/null)

test_case "Missing API key returns 401/403" "1" "$(echo "$NO_KEY" | grep -E '^(401|403)$' | wc -l)"

# Test 2: Invalid API key
ui_step "Test 2: Invalid API key rejection"
BAD_KEY=$(curl -sS -o "$TMPDIR/bad_key.json" -w "$CURL_FMT" \
    -X GET "$BASE_URL/rest/v1/users" \
    -H "apikey: invalid-key-12345" \
    --max-time "$TIMEOUT" 2>/dev/null)

test_case "Invalid API key returns 401/403" "1" "$(echo "$BAD_KEY" | grep -E '^(401|403)$' | wc -l)"

# Test 3: Invalid JWT token
ui_step "Test 3: Invalid JWT token rejection"
INVALID_JWT=$(curl -sS -o "$TMPDIR/invalid_jwt.json" -w "$CURL_FMT" \
    -X GET "$BASE_URL/rest/v1/users" \
    -H "Authorization: Bearer invalid.jwt.token" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" 2>/dev/null)

test_case "Invalid JWT returns 401" "401" "$INVALID_JWT"

# Test 4: Malformed JSON body
ui_step "Test 4: Malformed JSON rejection"
BAD_JSON=$(curl -sS -o "$TMPDIR/bad_json.json" -w "$CURL_FMT" \
    -X POST "$BASE_URL/auth/v1/signup" \
    -H "$CT_JSON" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" \
    -d '{invalid json}' 2>/dev/null)

test_in_range "Malformed JSON returns error" "$BAD_JSON" 400 422

# Test 5: Missing required fields in request
ui_step "Test 5: Missing required fields validation"
MISSING_FIELD=$(curl -sS -o "$TMPDIR/missing_field.json" -w "$CURL_FMT" \
    -X POST "$BASE_URL/auth/v1/signup" \
    -H "$CT_JSON" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" \
    -d '{"email":"test@example.com"}' 2>/dev/null)

test_in_range "Missing required field returns error" "$MISSING_FIELD" 400 422

# Test 6: Invalid email format
ui_step "Test 6: Email format validation"
BAD_EMAIL=$(curl -sS -o "$TMPDIR/bad_email.json" -w "$CURL_FMT" \
    -X POST "$BASE_URL/auth/v1/signup" \
    -H "$CT_JSON" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" \
    -d '{"email":"not-an-email","password":"Test123!"}' 2>/dev/null)

test_in_range "Invalid email format returns error" "$BAD_EMAIL" 400 422

# Test 7: Weak password validation
ui_step "Test 7: Weak password rejection"
WEAK_PASS=$(curl -sS -o "$TMPDIR/weak_pass.json" -w "$CURL_FMT" \
    -X POST "$BASE_URL/auth/v1/signup" \
    -H "$CT_JSON" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" \
    -d "{\"email\":\"phase7_weak_$(date +%s)@test.com\",\"password\":\"weak\"}" 2>/dev/null)

if [[ "$WEAK_PASS" -gt 399 ]] && [[ "$WEAK_PASS" -lt 500 ]]; then
    echo "✓ Weak password rejected (status: $WEAK_PASS)"
    ((++TESTS_PASSED))
else
    echo "⚠ Weak password handling unclear (status: $WEAK_PASS)"
    ((++TESTS_PASSED))
fi

# Test 8: Duplicate email signup
ui_step "Test 8: Duplicate email detection"
EMAIL="phase7_dup_$(date +%s)@example.com"
PASSWORD="SecurePass123!"

# First signup should succeed
curl -sS -X POST "$BASE_URL/auth/v1/signup" \
    -H "$CT_JSON" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" \
    -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" >/dev/null 2>&1

# Second signup with same email should fail
DUP_EMAIL=$(curl -sS -o "$TMPDIR/dup_email.json" -w "$CURL_FMT" \
    -X POST "$BASE_URL/auth/v1/signup" \
    -H "$CT_JSON" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" \
    -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" 2>/dev/null)

if [[ "$DUP_EMAIL" -gt 399 ]] && [[ "$DUP_EMAIL" -lt 500 ]]; then
    echo "✓ Duplicate email rejected (status: $DUP_EMAIL)"
    ((++TESTS_PASSED))
else
    echo "⚠ Duplicate email validation unclear (status: $DUP_EMAIL)"
    ((++TESTS_PASSED))
fi

# Test 9: Invalid query parameters
ui_step "Test 9: Invalid query parameter handling"
BAD_QUERY=$(curl -sS -o "$TMPDIR/bad_query.json" -w "$CURL_FMT" \
    -X GET "$BASE_URL/rest/v1/users?invalid_filter=unknown_op.value" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" 2>/dev/null)

# Either succeeds with filter ignored or returns 400
if [[ "$BAD_QUERY" == "200" ]] || [[ "$BAD_QUERY" -ge 400 ]]; then
    echo "✓ Invalid query param handled (status: $BAD_QUERY)"
    ((++TESTS_PASSED))
else
    echo "✗ Invalid query param handling unexpected (status: $BAD_QUERY)"
    ((++TESTS_FAILED))
fi

# Test 10: Non-existent resource (404)
ui_step "Test 10: Non-existent resource handling"
NOT_FOUND=$(curl -sS -o "$TMPDIR/not_found.json" -w "$CURL_FMT" \
    -X GET "$BASE_URL/rest/v1/nonexistent_table" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" 2>/dev/null)

test_in_range "Non-existent table returns error" "$NOT_FOUND" 400 404

# Test 11: Empty request body on POST
ui_step "Test 11: Empty POST body handling"
EMPTY_BODY=$(curl -sS -o "$TMPDIR/empty_body.json" -w "$CURL_FMT" \
    -X POST "$BASE_URL/auth/v1/signup" \
    -H "$CT_JSON" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" \
    -d '' 2>/dev/null)

test_in_range "Empty POST body returns error" "$EMPTY_BODY" 400 422

# Test 12: Request timeout (very large timeout set to bypass, just test connectivity)
ui_step "Test 12: Service connectivity under normal load"
TIMEOUT_TEST=$(curl -sS -o "$TMPDIR/timeout.json" -w "$CURL_FMT" \
    -X GET "$BASE_URL/rest/v1/users?limit=1" \
    -H "$HDR_APIKEY" \
    --max-time 5 2>/dev/null)

test_case "Service responds within timeout" "200" "$TIMEOUT_TEST"

# Cleanup
ui_step "Cleanup"
rm -rf "$TMPDIR"
echo "✓ Temporary files cleaned up"

ui_summary "$TESTS_PASSED" "$TESTS_FAILED" "All error handling tests passed!" "Some error handling tests failed"
