# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    postgres-mvp-flow.sh                               :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/bin/bash

# PostgreSQL MVP Flow Script
# Demonstrates end-to-end auth + PostgREST CRUD + isolation behavior through Kong.

BASE_URL="${BASE_URL:-http://localhost:8000}"
TIMEOUT="${TIMEOUT:-12}"
APIKEY="${APIKEY:-public-anon-key}"
TMPDIR="${TMPDIR:-$(mktemp -d /tmp/postgres_mvp_flow.XXXXXX)}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

readonly CT_JSON='Content-Type: application/json'
readonly HDR_APIKEY="apikey: $APIKEY"
readonly HDR_PREFER='Prefer: return=representation'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./test-ui.sh
source "$SCRIPT_DIR/test-ui.sh"

cleanup() {
  rm -rf "$TMPDIR" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo -e "${RED}[FAIL]${NC} Required command not found: $cmd" >&2
    exit 1
  fi
  return 0
}

fail_and_exit() {
  local message="$1"
  echo -e "${RED}[FAIL]${NC} $message" >&2
  exit 1
  return 0
}

pass() {
  local message="$1"
  echo -e "${GREEN}[PASS]${NC} $message"
  return 0
}

request_code() {
  local output_file="$1"
  shift
  curl -sS -o "$output_file" -w '%{http_code}' --max-time "$TIMEOUT" "$@" 2>/dev/null || echo "000"
  return 0
}

ensure_postgres_mvp_policies() {
  local sql
  read -r -d '' sql <<'SQL' || true
CREATE OR REPLACE FUNCTION auth.uid() RETURNS UUID AS $$
  SELECT (current_setting('request.jwt.claims', true)::jsonb->>'sub')::uuid;
$$ LANGUAGE SQL STABLE;

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.posts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS users_insert_own ON public.users;
CREATE POLICY users_insert_own ON public.users
  FOR INSERT WITH CHECK (auth.uid()::text = id::text);

DROP POLICY IF EXISTS users_update_own ON public.users;
CREATE POLICY users_update_own ON public.users
  FOR UPDATE USING (auth.uid()::text = id::text)
  WITH CHECK (auth.uid()::text = id::text);

DROP POLICY IF EXISTS users_delete_own ON public.users;
CREATE POLICY users_delete_own ON public.users
  FOR DELETE USING (auth.uid()::text = id::text);

DROP POLICY IF EXISTS posts_insert_own ON public.posts;
CREATE POLICY posts_insert_own ON public.posts
  FOR INSERT WITH CHECK (auth.uid()::text = user_id::text);

DROP POLICY IF EXISTS posts_update_own ON public.posts;
CREATE POLICY posts_update_own ON public.posts
  FOR UPDATE USING (auth.uid()::text = user_id::text)
  WITH CHECK (auth.uid()::text = user_id::text);

DROP POLICY IF EXISTS posts_delete_own ON public.posts;
CREATE POLICY posts_delete_own ON public.posts
  FOR DELETE USING (auth.uid()::text = user_id::text);
SQL

  if ! command -v docker >/dev/null 2>&1; then
    fail_and_exit "docker is required to apply PostgreSQL MVP policies"
  fi

  if ! docker ps --format '{{.Names}}' | grep -qx 'mini-baas-postgres'; then
    fail_and_exit "mini-baas-postgres container is not running"
  fi

  echo "$sql" | docker exec -i mini-baas-postgres psql -U postgres -d postgres >/dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    fail_and_exit "Failed to apply PostgreSQL MVP policies"
  fi

  pass "PostgreSQL MVP RLS write policies ensured"
  return 0
}

signup_and_login() {
  local label="$1"
  local email="$2"
  local password="$3"

  local signup_file="$TMPDIR/signup_${label}.json"
  local login_file="$TMPDIR/login_${label}.json"

  local signup_code
  signup_code=$(request_code "$signup_file" \
    -X POST "$BASE_URL/auth/v1/signup" \
    -H "$CT_JSON" \
    -H "$HDR_APIKEY" \
    -d "{\"email\":\"$email\",\"password\":\"$password\"}")

  [[ "$signup_code" == "200" ]] || fail_and_exit "Signup failed for $label (status $signup_code)"

  local user_id
  user_id=$(jq -r '.id // .user.id // empty' "$signup_file" 2>/dev/null || true)
  [[ -n "$user_id" ]] || fail_and_exit "Signup response missing user id for $label"

  local login_code
  login_code=$(request_code "$login_file" \
    -X POST "$BASE_URL/auth/v1/token?grant_type=password" \
    -H "$CT_JSON" \
    -H "$HDR_APIKEY" \
    -d "{\"email\":\"$email\",\"password\":\"$password\"}")

  [[ "$login_code" == "200" ]] || fail_and_exit "Login failed for $label (status $login_code)"

  local token
  token=$(jq -r '.access_token // empty' "$login_file" 2>/dev/null || true)
  [[ -n "$token" ]] || fail_and_exit "Login response missing access token for $label"

  printf '%s|%s\n' "$user_id" "$token"
  return 0
}

upsert_user_row() {
  local user_id="$1"
  local email="$2"
  local token="$3"
  local label="$4"

  local out="$TMPDIR/upsert_${label}.json"
  local code
  code=$(request_code "$out" \
    -X POST "$BASE_URL/rest/v1/users?on_conflict=email" \
    -H "$CT_JSON" \
    -H 'Prefer: resolution=merge-duplicates,return=representation' \
    -H "Authorization: Bearer $token" \
    -H "$HDR_APIKEY" \
    -d "{\"id\":\"$user_id\",\"email\":\"$email\",\"name\":\"$label\"}")

  case "$code" in
    200|201)
      pass "Upsert user row for $label"
      ;;
    *)
      fail_and_exit "Upsert user row failed for $label (status $code)"
      ;;
  esac
  return 0
}

ui_banner "PostgreSQL MVP Flow" "Auth + PostgREST CRUD + isolation"
ui_kv "Base URL" "$BASE_URL"
ui_kv "API key" "$APIKEY"
ui_hr

require_cmd jq

TS=$(date +%s)
EMAIL_A="mvp_pg_a_${TS}@example.com"
EMAIL_B="mvp_pg_b_${TS}@example.com"
PASSWORD='MvpPostgres123!'

ui_step "Step 1: Create two users and login"
A_PAIR=$(signup_and_login "user_a" "$EMAIL_A" "$PASSWORD")
B_PAIR=$(signup_and_login "user_b" "$EMAIL_B" "$PASSWORD")

USER_A_ID="${A_PAIR%%|*}"
TOKEN_A="${A_PAIR##*|}"
USER_B_ID="${B_PAIR%%|*}"
TOKEN_B="${B_PAIR##*|}"

pass "User A authenticated"
pass "User B authenticated"

ui_step "Step 2: Ensure PostgreSQL policies for MVP writes"
ensure_postgres_mvp_policies

ui_step "Step 3: Ensure public.users rows exist"
upsert_user_row "$USER_A_ID" "$EMAIL_A" "$TOKEN_A" "User A"
upsert_user_row "$USER_B_ID" "$EMAIL_B" "$TOKEN_B" "User B"

ui_step "Step 4: User A creates private post"
CREATE_OUT="$TMPDIR/create_post_a.json"
CREATE_CODE=$(request_code "$CREATE_OUT" \
  -X POST "$BASE_URL/rest/v1/posts" \
  -H "$CT_JSON" \
  -H "$HDR_PREFER" \
  -H "Authorization: Bearer $TOKEN_A" \
  -H "$HDR_APIKEY" \
  -d "{\"user_id\":\"$USER_A_ID\",\"title\":\"MVP Post\",\"content\":\"Created from postgres-mvp-flow\",\"is_public\":false}")

case "$CREATE_CODE" in
  200|201)
    pass "User A created private post"
    ;;
  *)
    fail_and_exit "Create private post failed (status $CREATE_CODE)"
    ;;
esac

POST_ID=$(jq -r '.[0].id // empty' "$CREATE_OUT" 2>/dev/null || true)
[[ -n "$POST_ID" ]] || fail_and_exit "Create post response missing id"

ui_step "Step 5: User A reads and updates own post"
A_GET_OUT="$TMPDIR/a_get_post.json"
A_GET_CODE=$(request_code "$A_GET_OUT" \
  -X GET "$BASE_URL/rest/v1/posts?id=eq.$POST_ID&select=id,user_id,title,is_public" \
  -H "Authorization: Bearer $TOKEN_A" \
  -H "$HDR_APIKEY")
[[ "$A_GET_CODE" == "200" ]] || fail_and_exit "User A read own post failed (status $A_GET_CODE)"

A_COUNT=$(jq -r 'length' "$A_GET_OUT" 2>/dev/null || echo "0")
[[ "$A_COUNT" == "1" ]] || fail_and_exit "Expected User A to see 1 row, got $A_COUNT"
pass "User A can read own private post"

A_PATCH_OUT="$TMPDIR/a_patch_post.json"
A_PATCH_CODE=$(request_code "$A_PATCH_OUT" \
  -X PATCH "$BASE_URL/rest/v1/posts?id=eq.$POST_ID" \
  -H "$CT_JSON" \
  -H "$HDR_PREFER" \
  -H "Authorization: Bearer $TOKEN_A" \
  -H "$HDR_APIKEY" \
  -d '{"title":"MVP Post Updated"}')

case "$A_PATCH_CODE" in
  200|204)
    pass "User A updated own post"
    ;;
  *)
    fail_and_exit "User A patch failed (status $A_PATCH_CODE)"
    ;;
esac

ui_step "Step 6: User B cannot read User A private post"
B_GET_OUT="$TMPDIR/b_get_post.json"
B_GET_CODE=$(request_code "$B_GET_OUT" \
  -X GET "$BASE_URL/rest/v1/posts?id=eq.$POST_ID&select=id,user_id,title,is_public" \
  -H "Authorization: Bearer $TOKEN_B" \
  -H "$HDR_APIKEY")
[[ "$B_GET_CODE" == "200" ]] || fail_and_exit "User B read query failed (status $B_GET_CODE)"

B_COUNT=$(jq -r 'length' "$B_GET_OUT" 2>/dev/null || echo "-1")
[[ "$B_COUNT" == "0" ]] || fail_and_exit "Isolation failed: User B should see 0 rows, got $B_COUNT"
pass "Isolation validated: User B cannot see User A private post"

ui_step "Step 7: Invalid JWT is rejected"
INVALID_OUT="$TMPDIR/invalid_jwt.json"
INVALID_CODE=$(request_code "$INVALID_OUT" \
  -X GET "$BASE_URL/rest/v1/users?limit=1" \
  -H 'Authorization: Bearer invalid.jwt.token' \
  -H "$HDR_APIKEY")

case "$INVALID_CODE" in
  401|403)
    pass "Invalid JWT is rejected"
    ;;
  *)
    fail_and_exit "Invalid JWT expected 401/403, got $INVALID_CODE"
    ;;
esac

ui_step "Step 8: User A deletes own post"
DELETE_OUT="$TMPDIR/delete_post_a.json"
DELETE_CODE=$(request_code "$DELETE_OUT" \
  -X DELETE "$BASE_URL/rest/v1/posts?id=eq.$POST_ID" \
  -H "$HDR_PREFER" \
  -H "Authorization: Bearer $TOKEN_A" \
  -H "$HDR_APIKEY")

case "$DELETE_CODE" in
  200|204)
    pass "User A deleted own post"
    ;;
  *)
    fail_and_exit "Delete failed (status $DELETE_CODE)"
    ;;
esac

VERIFY_OUT="$TMPDIR/verify_deleted.json"
VERIFY_CODE=$(request_code "$VERIFY_OUT" \
  -X GET "$BASE_URL/rest/v1/posts?id=eq.$POST_ID&select=id" \
  -H "Authorization: Bearer $TOKEN_A" \
  -H "$HDR_APIKEY")
[[ "$VERIFY_CODE" == "200" ]] || fail_and_exit "Delete verification query failed (status $VERIFY_CODE)"

VERIFY_COUNT=$(jq -r 'length' "$VERIFY_OUT" 2>/dev/null || echo "-1")
[[ "$VERIFY_COUNT" == "0" ]] || fail_and_exit "Expected deleted post count 0, got $VERIFY_COUNT"
pass "Deleted post is no longer visible"

echo -e "${GREEN}✓ PostgreSQL MVP flow completed successfully${NC}"
