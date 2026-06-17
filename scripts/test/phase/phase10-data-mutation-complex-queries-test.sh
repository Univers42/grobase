# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    phase10-data-mutation-complex-queries-test.        :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/bin/bash

# Phase 10: Data Mutation & Complex Queries
# Tests advanced PostgREST operations through Kong:
# - Batch insert, upsert, update, delete
# - Pagination, ordering, filtering
# - Count headers and complex query parameters

BASE_URL="${BASE_URL:-http://localhost:8000}"
TIMEOUT="${TIMEOUT:-12}"
APIKEY="${APIKEY:-public-anon-key}"
TMPDIR="${TMPDIR:-$(mktemp -d /tmp/phase10_data_ops.XXXXXX)}"

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
readonly HDR_PREFER='Prefer: return=representation'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./test-ui.sh
source "$SCRIPT_DIR/test-ui.sh"

PASS_EMAIL="phase10_$(date +%s)@example.com"
PASS_PASSWORD='Phase10Pass123!'

JWT=""
AUTH_USER_ID=""
MUTATION_USER_ID="00000000-0000-0000-0000-000000000010"
MUTATION_EMAIL="phase10_mutation_$(date +%s)@example.com"

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

cleanup() {
    rm -rf "$TMPDIR" >/dev/null 2>&1 || true
    return 0
}

trap cleanup EXIT

ui_banner "Phase 10 Test Suite" "Data Mutations & Complex Queries"
ui_kv "Base URL" "$BASE_URL"
ui_kv "API key" "$APIKEY"
ui_hr

ui_step "Setup: Create auth user and obtain JWT"
SIGNUP_CODE=$(curl -sS -o "$TMPDIR/signup.json" -w "$CURL_FMT" \
  -X POST "$BASE_URL/auth/v1/signup" \
  -H "$CT_JSON" \
  -H "$HDR_APIKEY" \
  --max-time "$TIMEOUT" \
  -d "{\"email\":\"$PASS_EMAIL\",\"password\":\"$PASS_PASSWORD\"}" 2>/dev/null || echo '000')
assert_code_one_of "Signup succeeds" "$SIGNUP_CODE" "200"

LOGIN_CODE=$(curl -sS -o "$TMPDIR/login.json" -w "$CURL_FMT" \
  -X POST "$BASE_URL/auth/v1/token?grant_type=password" \
  -H "$CT_JSON" \
  -H "$HDR_APIKEY" \
  --max-time "$TIMEOUT" \
  -d "{\"email\":\"$PASS_EMAIL\",\"password\":\"$PASS_PASSWORD\"}" 2>/dev/null || echo '000')
assert_code_one_of "Login succeeds" "$LOGIN_CODE" "200"

JWT=$(jq -r '.access_token // empty' "$TMPDIR/login.json" 2>/dev/null)
AUTH_USER_ID=$(jq -r '.user.id // .id // empty' "$TMPDIR/signup.json" 2>/dev/null)

if [[ -n "$JWT" ]] && [[ -n "$AUTH_USER_ID" ]]; then
    pass "JWT and user id extracted"
else
    fail "JWT and user id extracted" "missing token or user id"
fi

ui_step "Test 1: Batch INSERT on /rest/v1/users"
BATCH_INSERT_CODE=$(curl -sS -o "$TMPDIR/batch_insert.json" -w "$CURL_FMT" \
  -X POST "$BASE_URL/rest/v1/users" \
  -H "$CT_JSON" \
  -H "$HDR_PREFER" \
  -H "Authorization: Bearer $JWT" \
  -H "$HDR_APIKEY" \
  --max-time "$TIMEOUT" \
  -d "[
    {\"id\":\"$MUTATION_USER_ID\",\"email\":\"$MUTATION_EMAIL\",\"name\":\"Phase10 Mutation\"},
    {\"id\":\"$AUTH_USER_ID\",\"email\":\"$PASS_EMAIL\",\"name\":\"Phase10 Auth User\"}
  ]" 2>/dev/null || echo '000')
assert_code_one_of "Batch insert returns allowed status" "$BATCH_INSERT_CODE" "201" "200" "403" "409"

ui_step "Test 2: Upsert on conflict (email)"
UPSERT_CODE=$(curl -sS -o "$TMPDIR/upsert.json" -w "$CURL_FMT" \
  -X POST "$BASE_URL/rest/v1/users?on_conflict=email" \
  -H "$CT_JSON" \
  -H 'Prefer: resolution=merge-duplicates,return=representation' \
  -H "Authorization: Bearer $JWT" \
  -H "$HDR_APIKEY" \
  --max-time "$TIMEOUT" \
  -d "{\"id\":\"$AUTH_USER_ID\",\"email\":\"$PASS_EMAIL\",\"name\":\"Phase10 Upsert Name\"}" 2>/dev/null || echo '000')
assert_code_one_of "Upsert returns allowed status" "$UPSERT_CODE" "201" "200" "403" "409"

ui_step "Test 3: PATCH update by filter"
PATCH_CODE=$(curl -sS -o "$TMPDIR/patch.json" -w "$CURL_FMT" \
  -X PATCH "$BASE_URL/rest/v1/users?id=eq.$AUTH_USER_ID" \
  -H "$CT_JSON" \
  -H "$HDR_PREFER" \
  -H "Authorization: Bearer $JWT" \
  -H "$HDR_APIKEY" \
  --max-time "$TIMEOUT" \
  -d '{"name":"Phase10 Patched"}' 2>/dev/null || echo '000')
assert_code_one_of "PATCH returns allowed status" "$PATCH_CODE" "200" "204" "403"

ui_step "Test 4: GET with select + filter"
FILTER_CODE=$(curl -sS -o "$TMPDIR/filter.json" -w "$CURL_FMT" \
  -X GET "$BASE_URL/rest/v1/users?select=id,email,name,created_at&email=eq.$PASS_EMAIL" \
  -H "Authorization: Bearer $JWT" \
  -H "$HDR_APIKEY" \
  --max-time "$TIMEOUT" 2>/dev/null || echo '000')
assert_code_one_of "Filtered query status" "$FILTER_CODE" "200"

FILTER_IS_ARRAY=$(jq -r 'if type=="array" then "yes" else "no" end' "$TMPDIR/filter.json" 2>/dev/null || echo "no")
if [[ "$FILTER_IS_ARRAY" == "yes" ]]; then
    pass "Filtered query returns JSON array"
else
    fail "Filtered query returns JSON array" "unexpected body format"
fi

ui_step "Test 5: Pagination with limit + offset"
PAGINATION_CODE=$(curl -sS -o "$TMPDIR/pagination.json" -w "$CURL_FMT" \
  -X GET "$BASE_URL/rest/v1/users?select=id,email&order=created_at.desc&limit=2&offset=0" \
  -H "Authorization: Bearer $JWT" \
  -H "$HDR_APIKEY" \
  --max-time "$TIMEOUT" 2>/dev/null || echo '000')
assert_code_one_of "Pagination query status" "$PAGINATION_CODE" "200"

PAGE_SIZE=$(jq 'if type=="array" then length else -1 end' "$TMPDIR/pagination.json" 2>/dev/null || echo "-1")
if [[ "$PAGE_SIZE" -ge 0 ]] && [[ "$PAGE_SIZE" -le 2 ]]; then
    pass "Pagination result size respects limit"
else
    fail "Pagination result size respects limit" "unexpected length $PAGE_SIZE"
fi

ui_step "Test 6: Complex OR filter"
OR_CODE=$(curl -sS -o "$TMPDIR/or_filter.json" -w "$CURL_FMT" \
  -X GET "$BASE_URL/rest/v1/users?select=id,email&or=(email.eq.$PASS_EMAIL,email.eq.$MUTATION_EMAIL)&limit=5" \
  -H "Authorization: Bearer $JWT" \
  -H "$HDR_APIKEY" \
  --max-time "$TIMEOUT" 2>/dev/null || echo '000')
assert_code_one_of "OR filter query status" "$OR_CODE" "200"

OR_IS_ARRAY=$(jq -r 'if type=="array" then "yes" else "no" end' "$TMPDIR/or_filter.json" 2>/dev/null || echo "no")
if [[ "$OR_IS_ARRAY" == "yes" ]]; then
    pass "OR filter returns JSON array"
else
    fail "OR filter returns JSON array" "unexpected body format"
fi

ui_step "Test 7: HEAD request with exact count"
HEAD_HEADERS="$TMPDIR/head.headers"
HEAD_CODE=$(curl -sS -D "$HEAD_HEADERS" -o /dev/null -w "$CURL_FMT" \
  -X HEAD "$BASE_URL/rest/v1/users?select=id" \
  -H 'Prefer: count=exact' \
  -H "Authorization: Bearer $JWT" \
  -H "$HDR_APIKEY" \
  --max-time "$TIMEOUT" 2>/dev/null || echo '000')
HEAD_CODE="$(printf '%s' "$HEAD_CODE" | tr -cd '0-9' | cut -c1-3)"
assert_code_one_of "HEAD query status" "$HEAD_CODE" "200" "206"

if grep -qi '^content-range:' "$HEAD_HEADERS"; then
    pass "HEAD response includes Content-Range"
else
    fail "HEAD response includes Content-Range" "header missing"
fi

ui_step "Test 8: Invalid cast/filter validation"
INVALID_FILTER_CODE=$(curl -sS -o "$TMPDIR/invalid_filter.json" -w "$CURL_FMT" \
  -X GET "$BASE_URL/rest/v1/users?id=eq.not-a-uuid" \
  -H "Authorization: Bearer $JWT" \
  -H "$HDR_APIKEY" \
  --max-time "$TIMEOUT" 2>/dev/null || echo '000')
assert_code_one_of "Invalid UUID filter is rejected" "$INVALID_FILTER_CODE" "400" "406"

ui_step "Test 9: DELETE by filter"
DELETE_CODE=$(curl -sS -o "$TMPDIR/delete.json" -w "$CURL_FMT" \
  -X DELETE "$BASE_URL/rest/v1/users?email=eq.$MUTATION_EMAIL" \
  -H "$HDR_PREFER" \
  -H "Authorization: Bearer $JWT" \
  -H "$HDR_APIKEY" \
  --max-time "$TIMEOUT" 2>/dev/null || echo '000')
assert_code_one_of "DELETE returns allowed status" "$DELETE_CODE" "200" "204" "403"

ui_step "Cleanup"
echo "✓ Temporary files cleaned up"

ui_summary "$TESTS_PASSED" "$TESTS_FAILED" "Phase 10 advanced data tests passed!" "Phase 10 advanced data tests failed"

if [[ $TESTS_FAILED -eq 0 ]]; then
    exit 0
else
    exit 1
fi
