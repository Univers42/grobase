# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    phase9-storage-operations-test.sh                  :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/bin/bash

# Phase 9: Storage Service (MinIO) Operations
# Validates gateway controls on /storage/v1 plus real object operations using MinIO client.

BASE_URL="${BASE_URL:-http://localhost:8000}"
TIMEOUT="${TIMEOUT:-15}"
APIKEY="${APIKEY:-public-anon-key}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://127.0.0.1:9000}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-${MINIO_ROOT_USER:-}}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-${MINIO_ROOT_PASSWORD:-}}"
MC_IMAGE="${MC_IMAGE:-minio/mc:latest}"
TMPDIR="${TMPDIR:-$(mktemp -d /tmp/phase9_storage.XXXXXX)}"

mkdir -p "$TMPDIR"

if { [[ -z "$MINIO_ACCESS_KEY" ]] || [[ -z "$MINIO_SECRET_KEY" ]]; } && command -v docker >/dev/null 2>&1; then
        detected_env=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' mini-baas-minio 2>/dev/null || true)
        if [[ -z "$MINIO_ACCESS_KEY" ]]; then
            MINIO_ACCESS_KEY=$(printf '%s\n' "$detected_env" | awk -F= '/^MINIO_ROOT_USER=/{print $2; exit}')
        fi
        if [[ -z "$MINIO_SECRET_KEY" ]]; then
            MINIO_SECRET_KEY=$(printf '%s\n' "$detected_env" | awk -F= '/^MINIO_ROOT_PASSWORD=/{print $2; exit}')
        fi
fi

MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-minioadmin}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-minioadmin}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
readonly CURL_FMT='%{http_code}'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./test-ui.sh
source "$SCRIPT_DIR/test-ui.sh"

BUCKET_NAME="phase9-bucket-$(date +%s)"
OBJECT_KEY="phase9-object.txt"
LARGE_FILE="$TMPDIR/payload_11mb.bin"
OBJECT_PAYLOAD="Phase9 storage test payload at $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

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

mc_cmd() {
    local cmd="$1"
    docker run -i --rm --network container:mini-baas-minio --entrypoint /bin/sh -e HOME=/tmp "$MC_IMAGE" \
    -ec "mc alias set local '$MINIO_ENDPOINT' '$MINIO_ACCESS_KEY' '$MINIO_SECRET_KEY' >/dev/null && $cmd"
    return 0
}

cleanup_resources() {
    mc_cmd "mc rm --force local/$BUCKET_NAME/$OBJECT_KEY >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
    mc_cmd "mc rb --force local/$BUCKET_NAME >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
    return 0
}

trap cleanup_resources EXIT

ui_banner "Phase 9 Test Suite" "Storage Service (MinIO) Operations"
ui_kv "Gateway URL" "$BASE_URL"
ui_kv "MinIO endpoint" "$MINIO_ENDPOINT"
ui_kv "Bucket" "$BUCKET_NAME"
ui_hr

ui_step "Test 1: /storage/v1 rejects missing API key"
MISSING_APIKEY_CODE=$(curl -sS -o "$TMPDIR/missing-apikey.out" -w "$CURL_FMT" \
    -X GET "$BASE_URL/storage/v1/" \
    --max-time "$TIMEOUT" 2>/dev/null || echo '000')
assert_code_one_of "Missing API key rejected" "$MISSING_APIKEY_CODE" "401"

ui_step "Test 2: /storage/v1 accepts valid API key"
VALID_APIKEY_CODE=$(curl -sS -o "$TMPDIR/valid-apikey.out" -w "$CURL_FMT" \
    -X GET "$BASE_URL/storage/v1/minio/health/live" \
    -H "apikey: $APIKEY" \
    --max-time "$TIMEOUT" 2>/dev/null || echo '000')
assert_code_one_of "Valid API key reaches storage upstream" "$VALID_APIKEY_CODE" "200"

ui_step "Test 3: Create bucket with MinIO client"
if mc_cmd "mc mb --ignore-existing local/$BUCKET_NAME" >/dev/null 2>&1; then
    pass "Bucket created"
else
    fail "Bucket created" "mc mb failed"
fi

ui_step "Test 4: Upload object"
if printf '%s\n' "$OBJECT_PAYLOAD" | mc_cmd "mc pipe local/$BUCKET_NAME/$OBJECT_KEY >/dev/null" >/dev/null 2>&1; then
    pass "Object uploaded"
else
    fail "Object uploaded" "mc pipe upload failed"
fi

ui_step "Test 5: List bucket and check object"
LIST_OUT="$TMPDIR/list.out"
if mc_cmd "mc ls local/$BUCKET_NAME" >"$LIST_OUT" 2>/dev/null; then
    pass "Bucket listed"
else
    fail "Bucket listed" "mc ls failed"
fi

if grep -q "$OBJECT_KEY" "$LIST_OUT"; then
    pass "Uploaded object appears in bucket listing"
else
    fail "Uploaded object appears in bucket listing" "object key missing from list"
fi

ui_step "Test 6: Download object and verify integrity"
EXPECTED_SIZE=$(printf '%s\n' "$OBJECT_PAYLOAD" | wc -c | tr -d ' ')
DOWNLOADED_SIZE=$(mc_cmd "mc cat local/$BUCKET_NAME/$OBJECT_KEY | wc -c | tr -d ' '" 2>/dev/null || true)
if [[ -n "$DOWNLOADED_SIZE" ]]; then
    pass "Object downloaded"
else
    fail "Object downloaded" "mc cat failed"
fi

if [[ "$DOWNLOADED_SIZE" == "$EXPECTED_SIZE" ]]; then
    pass "Downloaded content matches uploaded content"
else
    fail "Downloaded content matches uploaded content" "size mismatch (expected $EXPECTED_SIZE, got $DOWNLOADED_SIZE)"
fi

ui_step "Test 7: Delete object"
if mc_cmd "mc rm --force local/$BUCKET_NAME/$OBJECT_KEY" >/dev/null 2>&1; then
    pass "Object deleted"
else
    fail "Object deleted" "mc rm failed"
fi

ui_step "Test 8: Delete bucket"
if mc_cmd "mc rb --force local/$BUCKET_NAME" >/dev/null 2>&1; then
    pass "Bucket deleted"
else
    fail "Bucket deleted" "mc rb failed"
fi

ui_step "Test 9: Gateway payload limit still enforced for storage route"
if [[ ! -f "$LARGE_FILE" ]]; then
    dd if=/dev/zero of="$LARGE_FILE" bs=1M count=11 status=none
fi

LARGE_CODE=$(curl -sS -o "$TMPDIR/large-payload.out" -w "$CURL_FMT" \
    -X POST "$BASE_URL/storage/v1/phase9-size-check" \
    -H "apikey: $APIKEY" \
    -H 'Content-Type: application/octet-stream' \
    --data-binary "@$LARGE_FILE" \
    --max-time "$TIMEOUT" 2>/dev/null || echo '000')
assert_code_one_of "Storage payload >10MB rejected" "$LARGE_CODE" "413"

ui_step "Cleanup"
rm -rf "$TMPDIR" >/dev/null 2>&1 || true
echo "✓ Temporary files cleaned up"

ui_summary "$TESTS_PASSED" "$TESTS_FAILED" "Phase 9 storage tests passed!" "Phase 9 storage tests failed"

if [[ $TESTS_FAILED -eq 0 ]]; then
    exit 0
else
    exit 1
fi
