# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    phase2-smoke-test.sh                               :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/bin/bash

# Phase 2 Smoke Test: Kong gateway security controls
# Validates key-auth enforcement, CORS, and storage request-size-limiting

BASE_URL="${BASE_URL:-http://localhost:8000}"
TIMEOUT="${TIMEOUT:-10}"
PUBLIC_APIKEY="${PUBLIC_APIKEY:-public-anon-key}"
INVALID_APIKEY="${INVALID_APIKEY:-invalid-key}"
RUN_RATE_LIMIT_TEST="${RUN_RATE_LIMIT_TEST:-false}"
RATE_LIMIT_BURST="${RATE_LIMIT_BURST:-70}"
TEST_ORIGIN="${TEST_ORIGIN:-http://localhost:3000}"
TMPDIR="/tmp/phase2_smoke"

mkdir -p "$TMPDIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
readonly CURL_FMT='%{http_code}'
readonly HDR_APIKEY="apikey: $PUBLIC_APIKEY"

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

assert_code() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$name"
    else
        fail "$name" "expected $expected, got $actual"
    fi
    return 0
}

assert_one_of() {
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

    fail "$name" "expected one of: ${allowed[*]}, got $actual"
    return 0
}

ui_banner "Phase 2 Smoke Test Suite" "Kong gateway security controls"
ui_kv "Base URL" "$BASE_URL"
ui_kv "Public API key" "$PUBLIC_APIKEY"
ui_kv "Rate limit stress test" "$RUN_RATE_LIMIT_TEST"
ui_kv "CORS test origin" "$TEST_ORIGIN"
ui_hr

ui_step "Test 1: key-auth on /auth/v1"

# 1) key-auth on auth route
MISSING_AUTH_CODE=$(curl -sS -o "$TMPDIR/no_apikey_auth.json" -w "$CURL_FMT" \
  -X GET "$BASE_URL/auth/v1/health" \
  --max-time "$TIMEOUT" 2>/dev/null || echo "000")
assert_code "Missing apikey rejected on /auth/v1" "401" "$MISSING_AUTH_CODE"

INVALID_AUTH_CODE=$(curl -sS -o "$TMPDIR/invalid_apikey_auth.json" -w "$CURL_FMT" \
  -X GET "$BASE_URL/auth/v1/health" \
  -H "apikey: $INVALID_APIKEY" \
  --max-time "$TIMEOUT" 2>/dev/null || echo "000")
assert_code "Invalid apikey rejected on /auth/v1" "401" "$INVALID_AUTH_CODE"

VALID_AUTH_CODE=$(curl -sS -o "$TMPDIR/valid_apikey_auth.json" -w "$CURL_FMT" \
  -X GET "$BASE_URL/auth/v1/health" \
  -H "$HDR_APIKEY" \
  --max-time "$TIMEOUT" 2>/dev/null || echo "000")
assert_code "Valid apikey accepted on /auth/v1" "200" "$VALID_AUTH_CODE"

# 2) key-auth on rest route
ui_step "Test 2: key-auth on /rest/v1"
MISSING_REST_CODE=$(curl -sS -o "$TMPDIR/no_apikey_rest.json" -w "$CURL_FMT" \
  -X GET "$BASE_URL/rest/v1/" \
  --max-time "$TIMEOUT" 2>/dev/null || echo "000")
assert_code "Missing apikey rejected on /rest/v1" "401" "$MISSING_REST_CODE"

VALID_REST_CODE=$(curl -sS -o "$TMPDIR/valid_apikey_rest.json" -w "$CURL_FMT" \
  -X GET "$BASE_URL/rest/v1/" \
  -H "$HDR_APIKEY" \
  --max-time "$TIMEOUT" 2>/dev/null || echo "000")
assert_one_of "Valid apikey reaches /rest/v1 upstream" "$VALID_REST_CODE" "200" "401"

# 3) key-auth on storage route
ui_step "Test 3: key-auth and payload limits on /storage/v1"
MISSING_STORAGE_CODE=$(curl -sS -o "$TMPDIR/no_apikey_storage.json" -w "$CURL_FMT" \
  -X GET "$BASE_URL/storage/v1/" \
  --max-time "$TIMEOUT" 2>/dev/null || echo "000")
assert_code "Missing apikey rejected on /storage/v1" "401" "$MISSING_STORAGE_CODE"

# 4) request-size-limiting behavior on storage route
LARGE_PAYLOAD="$TMPDIR/payload_11mb.bin"
SMALL_PAYLOAD="$TMPDIR/payload_1kb.bin"

if [[ ! -f "$LARGE_PAYLOAD" ]]; then
    dd if=/dev/zero of="$LARGE_PAYLOAD" bs=1M count=11 status=none
fi

if [[ ! -f "$SMALL_PAYLOAD" ]]; then
    dd if=/dev/zero of="$SMALL_PAYLOAD" bs=1K count=1 status=none
fi

SIZE_BLOCKED_CODE=$(curl -sS -o "$TMPDIR/storage_size_limit.json" -w "$CURL_FMT" \
  -X POST "$BASE_URL/storage/v1/phase2-size-check" \
  -H "$HDR_APIKEY" \
  -H 'Content-Type: application/octet-stream' \
  --data-binary "@$LARGE_PAYLOAD" \
  --max-time "$TIMEOUT" 2>/dev/null || echo "000")
assert_code "Storage payload >10MB rejected with 413" "413" "$SIZE_BLOCKED_CODE"

SIZE_ALLOWED_CODE=$(curl -sS -o "$TMPDIR/storage_small_payload.json" -w "$CURL_FMT" \
  -X POST "$BASE_URL/storage/v1/phase2-size-check" \
  -H "$HDR_APIKEY" \
  -H 'Content-Type: application/octet-stream' \
  --data-binary "@$SMALL_PAYLOAD" \
  --max-time "$TIMEOUT" 2>/dev/null || echo "000")

if [[ "$SIZE_ALLOWED_CODE" == "413" ]] || [[ "$SIZE_ALLOWED_CODE" == "401" ]]; then
    fail "Storage small payload passes gateway limits" "unexpected code $SIZE_ALLOWED_CODE"
else
    pass "Storage small payload passes gateway limits"
fi

# 5) CORS preflight should include origin header through Kong plugin
ui_step "Test 4: CORS preflight headers"
CORS_HEADERS=$(curl -sS -D - -o /dev/null \
  -X OPTIONS "$BASE_URL/rest/v1/" \
    -H "Origin: $TEST_ORIGIN" \
  -H 'Access-Control-Request-Method: GET' \
  -H "$HDR_APIKEY" \
  --max-time "$TIMEOUT" 2>/dev/null || true)

if echo "$CORS_HEADERS" | grep -qi '^access-control-allow-origin:'; then
    pass "CORS preflight returns access-control-allow-origin"
else
    fail "CORS preflight returns access-control-allow-origin" "header missing"
fi

# 6) Optional stress test for route rate-limiting
ui_step "Test 5: Optional rate-limit burst"
if [[ "$RUN_RATE_LIMIT_TEST" == "true" ]]; then
    echo -e "${YELLOW}[INFO]${NC} Running rate-limit burst test with $RATE_LIMIT_BURST requests..."
    HIT_429=false

    for i in $(seq 1 "$RATE_LIMIT_BURST"); do
        code=$(curl -sS -o /dev/null -w "$CURL_FMT" \
          -X GET "$BASE_URL/auth/v1/health" \
          -H "$HDR_APIKEY" \
          --max-time "$TIMEOUT" 2>/dev/null || echo "000")

        if [[ "$code" == "429" ]]; then
            HIT_429=true
            break
        fi
    done

    if [[ "$HIT_429" == "true" ]]; then
        pass "Rate limit triggers 429 under burst traffic"
    else
        fail "Rate limit triggers 429 under burst traffic" "no 429 seen in $RATE_LIMIT_BURST requests"
    fi
else
    echo -e "${YELLOW}[SKIP]${NC} Rate-limit burst test skipped (set RUN_RATE_LIMIT_TEST=true to enable)"
fi

ui_summary "$TESTS_PASSED" "$TESTS_FAILED" "Phase 2 gateway controls validated." "Phase 2 gateway controls have failures."

if [[ $TESTS_FAILED -eq 0 ]]; then
    exit 0
else
    exit 1
fi
