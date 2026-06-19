#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m146-movieverse.sh                                 :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/18 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/18 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M146 — MovieVerse-on-Grobase data model + catalog gate (migrations 066/067).
# Proves the re-platformed MovieVerse backend behaves end-to-end against the LIVE
# stack — no app server, only Grobase (GoTrue + PostgREST + the Go TMDB proxy):
#
#   (A) CATALOG    : GET /tmdb/v1/health and /tmdb/v1/discover/movie succeed with
#                    ONLY the anon apikey and NO JWT — public browsing works
#                    (this is what the per-user-JWT edge-function model could not do).
#   (B) PUBLIC RPC : POST /rest/v1/rpc/like_count returns a global count over the
#                    owner-scoped public.likes WITHOUT exposing whose likes (067).
#   (C) RLS PROOF  : two real GoTrue users. User A inserts a like + a review on a
#                    test media id. User B CANNOT see A's like (owner-scope, 066),
#                    but the review IS visible to anon (reviews are world-readable),
#                    and like_count counts A's like. The B-cannot-see-A read is the
#                    LOAD-BEARING assertion — a gate that only shows A reading A's
#                    own rows would be VACUOUS.
#
# Live gate (like m102): needs a running stack. Resolves the Kong port at runtime
# and the anon key from .env. Test rows use a unique media id and are removed by A
# at the end; the two signup users are harmless leftovers (unique emails per run).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
pass() { printf '%s  PASS%s %s\n' "$GRN" "$RST" "$1"; }
fail() { printf '%s  FAIL%s %s\n' "$RED" "$RST" "$1"; FAILED=1; }
info() { printf '%s  ··%s   %s\n' "$YEL" "$RST" "$1"; }
FAILED=0

# ── resolve gateway + anon key ───────────────────────────────────────────────
KPORT="$(docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://')"
KPORT="${KPORT:-8000}"
GW="http://localhost:${KPORT}"
ANON="$(grep -E '^KONG_PUBLIC_API_KEY=' .env 2>/dev/null | cut -d= -f2-)"

if [ -z "$ANON" ] || ! curl -fsS -o /dev/null --max-time 5 "$GW/tmdb/v1/health" -H "apikey: $ANON" 2>/dev/null; then
  printf '%sSKIP%s m146: stack not reachable at %s (bring it up: make up + docker compose --profile movieverse up -d)\n' "$YEL" "$RST" "$GW"
  exit 0
fi
info "gateway $GW"

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
TM="$RANDOM$RANDOM"
MEDIA="$((900000 + (RANDOM % 90000)))"

# ── (A) catalog: anon apikey, no JWT ─────────────────────────────────────────
[ "$(code "$GW/tmdb/v1/health" -H "apikey: $ANON")" = 200 ] \
  && pass "tmdb /health reachable with anon key (no JWT)" || fail "tmdb /health"
[ "$(code "$GW/tmdb/v1/discover/movie?page=1" -H "apikey: $ANON")" = 200 ] \
  && pass "tmdb /discover/movie reachable (anon, degrades to [] without TMDB key)" || fail "tmdb /discover/movie"

# ── (B) public like_count RPC ────────────────────────────────────────────────
LC0="$(curl -s -X POST "$GW/rest/v1/rpc/like_count" -H "apikey: $ANON" -H 'Content-Type: application/json' \
  -d "{\"p_media_id\":$MEDIA,\"p_media_type\":\"MOVIE\"}")"
[ "$LC0" = 0 ] && pass "like_count RPC returns 0 for fresh media id" || fail "like_count baseline ($LC0)"

# ── (C) RLS proof: two real users ────────────────────────────────────────────
signup() { # $1=tag -> echoes "<access_token> <user_id>"
  local body
  body="$(curl -s -X POST "$GW/auth/v1/signup" -H "apikey: $ANON" -H 'Content-Type: application/json' \
    -d "{\"email\":\"mvtest-$1-$TM@example.com\",\"password\":\"Passw0rd!23\",\"data\":{\"username\":\"mv_$1_$TM\"}}")"
  printf '%s %s' \
    "$(printf '%s' "$body" | jq -r '.access_token // empty')" \
    "$(printf '%s' "$body" | jq -r '.user.id // .id // empty')"
}
read -r ATOK AID <<<"$(signup a)"
read -r BTOK BID <<<"$(signup b)"
if [ -z "$ATOK" ] || [ -z "$AID" ] || [ -z "$BTOK" ] || [ -z "$BID" ]; then
  fail "signup did not return tokens (autoconfirm off?)"; printf '\n'; exit 1
fi
pass "two users signed up (A=$AID B=$BID)"

ins_like="$(code -X POST "$GW/rest/v1/likes" -H "apikey: $ANON" -H "Authorization: Bearer $ATOK" \
  -H 'Content-Type: application/json' -H 'Prefer: return=minimal' \
  -d "{\"user_id\":\"$AID\",\"media_id\":$MEDIA,\"media_type\":\"MOVIE\"}")"
[ "$ins_like" = 201 ] && pass "A inserts a like (201)" || fail "A insert like ($ins_like)"

B_SEES="$(curl -s "$GW/rest/v1/likes?media_id=eq.$MEDIA&select=id" -H "apikey: $ANON" -H "Authorization: Bearer $BTOK" | jq 'length')"
[ "$B_SEES" = 0 ] && pass "RLS: B cannot see A's like (owner-scope)" || fail "RLS leak: B sees $B_SEES of A's likes"

LC1="$(curl -s -X POST "$GW/rest/v1/rpc/like_count" -H "apikey: $ANON" -H 'Content-Type: application/json' \
  -d "{\"p_media_id\":$MEDIA,\"p_media_type\":\"MOVIE\"}")"
[ "$LC1" = 1 ] && pass "like_count RPC counts A's like globally (1)" || fail "like_count after insert ($LC1)"

ins_rev="$(code -X POST "$GW/rest/v1/reviews" -H "apikey: $ANON" -H "Authorization: Bearer $ATOK" \
  -H 'Content-Type: application/json' -H 'Prefer: return=minimal' \
  -d "{\"user_id\":\"$AID\",\"media_id\":$MEDIA,\"media_type\":\"MOVIE\",\"title\":\"gate\",\"rating\":8,\"comment\":\"m146\"}")"
[ "$ins_rev" = 201 ] && pass "A inserts a review (201)" || fail "A insert review ($ins_rev)"

ANON_REV="$(curl -s "$GW/rest/v1/reviews?media_id=eq.$MEDIA&select=id" -H "apikey: $ANON" | jq 'length')"
[ "$ANON_REV" = 1 ] && pass "reviews are world-readable (anon sees A's review)" || fail "review not public ($ANON_REV)"

# ── cleanup test rows (A owns them) ──────────────────────────────────────────
curl -s -o /dev/null -X DELETE "$GW/rest/v1/likes?media_id=eq.$MEDIA"   -H "apikey: $ANON" -H "Authorization: Bearer $ATOK" || true
curl -s -o /dev/null -X DELETE "$GW/rest/v1/reviews?media_id=eq.$MEDIA" -H "apikey: $ANON" -H "Authorization: Bearer $ATOK" || true
info "cleaned test rows for media $MEDIA"

printf '\n'
if [ "$FAILED" = 0 ]; then printf '%sm146 PASS%s — MovieVerse data model + catalog verified live\n' "$GRN" "$RST"; exit 0
else printf '%sm146 FAIL%s\n' "$RED" "$RST"; exit 1; fi
