# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    phase14-mongo-mvp-test.sh                          :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/bin/bash

# Phase 14 MVP Test: Mongo API behind Kong
# Validates key-auth, JWT-protected CRUD, and per-user data isolation.

BASE_URL="${BASE_URL:-http://localhost:8000}"
TIMEOUT="${TIMEOUT:-10}"
APIKEY="${APIKEY:-public-anon-key}"
TMPDIR="/tmp/phase14_mongo_mvp"

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

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${RED}[FAIL]${NC} Missing command: $cmd" >&2
        exit 1
    fi
    return 0
}

signup_and_login() {
    local tag="$1"
    local email="phase14_${tag}_$(date +%s)_$RANDOM@example.com"
    local password='TestPass123!'

    local signup_file="$TMPDIR/signup_${tag}.json"
    local login_file="$TMPDIR/login_${tag}.json"

    local signup_http
    signup_http=$(curl -sS -o "$signup_file" -w "$CURL_FMT" \
        -X POST "$BASE_URL/auth/v1/signup" \
        -H "$CT_JSON" \
        -H "$HDR_APIKEY" \
        --max-time "$TIMEOUT" \
        -d "{\"email\":\"$email\",\"password\":\"$password\"}" 2>/dev/null || echo "000")

    if [[ "$signup_http" != "200" ]]; then
        echo ""
        return
    fi

    sleep 0.5  # Rate limit spacing

    local login_http
    login_http=$(curl -sS -o "$login_file" -w "$CURL_FMT" \
        -X POST "$BASE_URL/auth/v1/token?grant_type=password" \
        -H "$CT_JSON" \
        -H "$HDR_APIKEY" \
        --max-time "$TIMEOUT" \
        -d "{\"email\":\"$email\",\"password\":\"$password\"}" 2>/dev/null || echo "000")

    if [[ "$login_http" != "200" ]]; then
        echo ""
        return
    fi

    jq -r '.access_token // empty' "$login_file" 2>/dev/null || true
    return 0
}

ui_banner "Phase 14 MVP Test Suite" "Mongo API via Kong gateway"
ui_kv "Base URL" "$BASE_URL"
ui_kv "API key" "$APIKEY"
ui_hr

require_cmd jq

ui_step "Test 1: key-auth on /mongo/v1/health"

MONGO_HEALTH_NO_KEY=$(curl -sS -o "$TMPDIR/mongo_health_nokey.json" -w "$CURL_FMT" \
    -X GET "$BASE_URL/mongo/v1/health" \
    --max-time "$TIMEOUT" 2>/dev/null || echo "000")
assert_code "Missing apikey rejected on /mongo/v1/health" "401" "$MONGO_HEALTH_NO_KEY"

MONGO_HEALTH_BAD_KEY=$(curl -sS -o "$TMPDIR/mongo_health_badkey.json" -w "$CURL_FMT" \
    -X GET "$BASE_URL/mongo/v1/health" \
    -H 'apikey: invalid-key' \
    --max-time "$TIMEOUT" 2>/dev/null || echo "000")
assert_code "Invalid apikey rejected on /mongo/v1/health" "401" "$MONGO_HEALTH_BAD_KEY"

MONGO_HEALTH_OK=$(curl -sS -o "$TMPDIR/mongo_health_ok.json" -w "$CURL_FMT" \
    -X GET "$BASE_URL/mongo/v1/health" \
    -H "$HDR_APIKEY" \
    --max-time "$TIMEOUT" 2>/dev/null || echo "000")
assert_code "Valid apikey accepted on /mongo/v1/health" "200" "$MONGO_HEALTH_OK"

ui_step "Test 2: create two users and JWT tokens"

TOKEN_A="$(signup_and_login usera)"
sleep 1  # Wait between user signups to avoid rate limiting
TOKEN_B="$(signup_and_login userb)"

if [[ -n "$TOKEN_A" ]]; then
    pass "User A login produced JWT"
else
    fail "User A login produced JWT" "token missing"
fi

if [[ -n "$TOKEN_B" ]]; then
    pass "User B login produced JWT"
else
    fail "User B login produced JWT" "token missing"
fi

DOC_ID=""

ui_step "Test 3: Mongo CRUD for User A"
if [[ -n "$TOKEN_A" ]]; then
    CREATE_HTTP=$(curl -sS -o "$TMPDIR/mongo_create_a.json" -w "$CURL_FMT" \
        -X POST "$BASE_URL/mongo/v1/collections/tasks/documents" \
        -H "$CT_JSON" \
        -H "$HDR_APIKEY" \
        -H "Authorization: Bearer $TOKEN_A" \
        --max-time "$TIMEOUT" \
        -d '{"data":{"title":"phase14 task","status":"open"}}' 2>/dev/null || echo "000")
    assert_code "Create Mongo document as User A" "201" "$CREATE_HTTP"

    DOC_ID="$(jq -r '.id // empty' "$TMPDIR/mongo_create_a.json" 2>/dev/null || true)"
    if [[ -n "$DOC_ID" ]]; then
        pass "Created document has id"
    else
        fail "Created document has id" "missing data.id"
    fi

    LIST_HTTP=$(curl -sS -o "$TMPDIR/mongo_list_a.json" -w "$CURL_FMT" \
        -X GET "$BASE_URL/mongo/v1/collections/tasks/documents?limit=10&offset=0" \
        -H "$HDR_APIKEY" \
        -H "Authorization: Bearer $TOKEN_A" \
        --max-time "$TIMEOUT" 2>/dev/null || echo "000")
    assert_code "List Mongo documents as User A" "200" "$LIST_HTTP"

    if jq -e --arg id "$DOC_ID" '.data[]? | select(.id == $id)' "$TMPDIR/mongo_list_a.json" >/dev/null 2>&1; then
        pass "User A list includes created document"
    else
        fail "User A list includes created document" "id $DOC_ID not found"
    fi

    GET_HTTP=$(curl -sS -o "$TMPDIR/mongo_get_a.json" -w "$CURL_FMT" \
        -X GET "$BASE_URL/mongo/v1/collections/tasks/documents/$DOC_ID" \
        -H "$HDR_APIKEY" \
        -H "Authorization: Bearer $TOKEN_A" \
        --max-time "$TIMEOUT" 2>/dev/null || echo "000")
    assert_code "Get Mongo document by id as User A" "200" "$GET_HTTP"

    PATCH_HTTP=$(curl -sS -o "$TMPDIR/mongo_patch_a.json" -w "$CURL_FMT" \
        -X PATCH "$BASE_URL/mongo/v1/collections/tasks/documents/$DOC_ID" \
        -H "$CT_JSON" \
        -H "$HDR_APIKEY" \
        -H "Authorization: Bearer $TOKEN_A" \
        --max-time "$TIMEOUT" \
        -d '{"patch":{"status":"done"}}' 2>/dev/null || echo "000")
    assert_code "Patch Mongo document as User A" "200" "$PATCH_HTTP"

    PATCHED_STATUS="$(jq -r '.status // empty' "$TMPDIR/mongo_patch_a.json" 2>/dev/null || true)"
    if [[ "$PATCHED_STATUS" == "done" ]]; then
        pass "Patched document status updated"
    else
        fail "Patched document status updated" "expected done, got ${PATCHED_STATUS:-empty}"
    fi
else
    fail "Mongo CRUD for User A" "skipped because token was not created"
fi

ui_step "Test 4: user isolation for Mongo documents"
if [[ -n "$TOKEN_B" ]] && [[ -n "$DOC_ID" ]]; then
    B_GET_HTTP=$(curl -sS -o "$TMPDIR/mongo_get_b.json" -w "$CURL_FMT" \
        -X GET "$BASE_URL/mongo/v1/collections/tasks/documents/$DOC_ID" \
        -H "$HDR_APIKEY" \
        -H "Authorization: Bearer $TOKEN_B" \
        --max-time "$TIMEOUT" 2>/dev/null || echo "000")
    assert_code "User B cannot read User A document" "404" "$B_GET_HTTP"

    B_PATCH_HTTP=$(curl -sS -o "$TMPDIR/mongo_patch_b.json" -w "$CURL_FMT" \
        -X PATCH "$BASE_URL/mongo/v1/collections/tasks/documents/$DOC_ID" \
        -H "$CT_JSON" \
        -H "$HDR_APIKEY" \
        -H "Authorization: Bearer $TOKEN_B" \
        --max-time "$TIMEOUT" \
        -d '{"patch":{"status":"stolen"}}' 2>/dev/null || echo "000")
    assert_code "User B cannot patch User A document" "404" "$B_PATCH_HTTP"

    B_DELETE_HTTP=$(curl -sS -o "$TMPDIR/mongo_delete_b.json" -w "$CURL_FMT" \
        -X DELETE "$BASE_URL/mongo/v1/collections/tasks/documents/$DOC_ID" \
        -H "$HDR_APIKEY" \
        -H "Authorization: Bearer $TOKEN_B" \
        --max-time "$TIMEOUT" 2>/dev/null || echo "000")
    assert_code "User B cannot delete User A document" "404" "$B_DELETE_HTTP"
else
    fail "Mongo user isolation checks" "skipped because token/doc id missing"
fi

ui_step "Test 5: delete User A document"
if [[ -n "$TOKEN_A" ]] && [[ -n "$DOC_ID" ]]; then
    A_DELETE_HTTP=$(curl -sS -o "$TMPDIR/mongo_delete_a.json" -w "$CURL_FMT" \
        -X DELETE "$BASE_URL/mongo/v1/collections/tasks/documents/$DOC_ID" \
        -H "$HDR_APIKEY" \
        -H "Authorization: Bearer $TOKEN_A" \
        --max-time "$TIMEOUT" 2>/dev/null || echo "000")
    assert_code "User A deletes own document" "200" "$A_DELETE_HTTP"

    DELETED_FLAG="$(jq -r '.deleted // empty' "$TMPDIR/mongo_delete_a.json" 2>/dev/null || true)"
    if [[ "$DELETED_FLAG" == "true" ]]; then
        pass "Delete response confirms deleted=true"
    else
        fail "Delete response confirms deleted=true" "got ${DELETED_FLAG:-empty}"
    fi
else
    fail "Delete User A document" "skipped because token/doc id missing"
fi

ui_summary "$TESTS_PASSED" "$TESTS_FAILED" "Phase 14 Mongo MVP flow validated." "Phase 14 Mongo MVP has failures."

if [[ $TESTS_FAILED -eq 0 ]]; then
    exit 0
else
    exit 1
fi
