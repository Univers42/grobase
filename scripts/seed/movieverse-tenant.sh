#!/usr/bin/env bash
# movieverse-tenant.sh — seed MovieVerse demo accounts on the LIVE Grobase stack
# (GoTrue + PostgREST + RLS, migrations 066/067). MovieVerse uses the platform
# backend directly (no per-tenant mount): users are real GoTrue accounts, their
# likes/reviews are owner-scoped PostgREST rows. Idempotent — re-running converges
# (signup falls back to login; likes/reviews UNIQUE-upsert). Emits the frontend
# config.js + a state file, and prints the logins. Never prints tokens/keys.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

C='\033[0;36m'; G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; W='\033[1m'; Z='\033[0m'
info() { printf "${C}[movieverse] %s${Z}\n" "$*"; }
warn() { printf "${Y}[movieverse] WARN: %s${Z}\n" "$*" >&2; }
fail() { printf "${R}[movieverse] FAIL: %s${Z}\n" "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || fail "jq is required"
KPORT="$(docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://')"
KPORT="${KPORT:-8000}"
GW="http://127.0.0.1:${KPORT}"
ANON="$(grep -E '^KONG_PUBLIC_API_KEY=' .env 2>/dev/null | cut -d= -f2-)"
SVC="$(grep -E '^KONG_SERVICE_API_KEY=' .env 2>/dev/null | cut -d= -f2-)"
[ -n "$ANON" ] || fail "KONG_PUBLIC_API_KEY missing from .env"
curl -fsS -o /dev/null --max-time 5 "$GW/rest/v1/movieverse_profiles?limit=1" -H "apikey: $ANON" \
  || fail "stack not reachable at $GW (run: make up + docker compose --profile movieverse up -d)"
info "gateway $GW"

PASSWORD="MovieVerse#2026"
STATE=".movieverse-baas.env"

# signup_or_login USERNAME EMAIL -> echoes "<access_token> <user_id>" (token never printed)
signup_or_login() {
  local username="$1" email="$2" body tok id
  body="$(curl -s -X POST "$GW/auth/v1/signup" -H "apikey: $ANON" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg e "$email" --arg p "$PASSWORD" --arg u "$username" \
          '{email:$e,password:$p,data:{username:$u}}')")"
  tok="$(printf '%s' "$body" | jq -r '.access_token // empty')"
  id="$(printf '%s' "$body" | jq -r '.user.id // .id // empty')"
  if [ -z "$tok" ] || [ -z "$id" ]; then
    body="$(curl -s -X POST "$GW/auth/v1/token?grant_type=password" -H "apikey: $ANON" \
      -H 'Content-Type: application/json' -d "$(jq -nc --arg e "$email" --arg p "$PASSWORD" '{email:$e,password:$p}')")"
    tok="$(printf '%s' "$body" | jq -r '.access_token // empty')"
    id="$(printf '%s' "$body" | jq -r '.user.id // empty')"
  fi
  [ -n "$tok" ] && [ -n "$id" ] || fail "could not provision $email (autoconfirm off?)"
  printf '%s %s' "$tok" "$id"
}

# like MEDIA_ID TYPE TITLE POSTER VOTE — idempotent owner-scoped like (UNIQUE upsert)
like() {
  curl -s -o /dev/null -X POST "$GW/rest/v1/likes" -H "apikey: $ANON" -H "Authorization: Bearer $TOK" \
    -H 'Content-Type: application/json' -H 'Prefer: resolution=merge-duplicates,return=minimal' \
    -d "$(jq -nc --arg u "$USERID" --argjson m "$1" --arg t "$2" --arg ti "$3" --arg po "$4" --argjson v "$5" \
          '{user_id:$u,media_id:$m,media_type:$t,title:$ti,poster_path:$po,vote_average:$v}')"
}
# review MEDIA_ID TYPE TITLE POSTER RATING COMMENT — idempotent owner-scoped review
review() {
  curl -s -o /dev/null -X POST "$GW/rest/v1/reviews" -H "apikey: $ANON" -H "Authorization: Bearer $TOK" \
    -H 'Content-Type: application/json' -H 'Prefer: resolution=merge-duplicates,return=minimal' \
    -d "$(jq -nc --arg u "$USERID" --argjson m "$1" --arg t "$2" --arg ti "$3" --arg po "$4" --argjson ra "$5" --arg co "$6" \
          '{user_id:$u,media_id:$m,media_type:$t,title:$ti,poster_path:$po,rating:$ra,comment:$co}')"
}

# promote_moderator USER_ID — set app_metadata.role (drives auth.is_moderator) + profile role
promote_moderator() {
  [ -n "$SVC" ] || { warn "no service key — skipping moderator promote"; return 0; }
  curl -s -o /dev/null -X PUT "$GW/auth/v1/admin/users/$1" -H "apikey: $SVC" -H "Authorization: Bearer $SVC" \
    -H 'Content-Type: application/json' -d '{"app_metadata":{"role":"MODERATOR"}}'
  curl -s -o /dev/null -X PATCH "$GW/rest/v1/movieverse_profiles?id=eq.$1" -H "apikey: $SVC" \
    -H "Authorization: Bearer $SVC" -H 'Content-Type: application/json' -H 'Prefer: return=minimal' \
    -d '{"role":"MODERATOR"}'
}

# ── known TMDB titles for seed content (real ids/posters; no TMDB key needed) ──
M_MATRIX='603';      P_MATRIX='/f89U3ADr1oiB1s9GkdPOEpXUk5H.jpg'
M_INCEP='27205';     P_INCEP='/oYuLEt3zVCKq57qu2F8dT7NIa6f.jpg'
M_INTER='157336';    P_INTER='/gEU2QniE6E77NI6lCU6MxlNBvIx.jpg'
M_DARK='155';        P_DARK='/qJ2tW6WMUDux911r6m7haRef0WH.jpg'

declare -a EMAILS=() USERNAMES=()
seed_user() {  # username email is_mod likes…
  local username="$1" email="$2" mod="$3"; shift 3
  read -r TOK USERID <<<"$(signup_or_login "$username" "$email")"
  info "user $email → ${USERID:0:8}… ($username${mod:+, moderator})"
  EMAILS+=("$email"); USERNAMES+=("$username")
  if [ "$mod" = mod ]; then promote_moderator "$USERID"; fi
}

# neo — cinephile with likes + reviews
seed_user neo neo@movieverse.local ''
like     "$M_MATRIX" MOVIE 'The Matrix'   "$P_MATRIX" 8.2
like     "$M_INCEP"  MOVIE 'Inception'    "$P_INCEP"  8.4
review   "$M_MATRIX" MOVIE 'The Matrix'   "$P_MATRIX" 10 'There is no spoon. A perfect film.'
review   "$M_INCEP"  MOVIE 'Inception'    "$P_INCEP"   9 'Dreams within dreams — endlessly rewatchable.'

# trinity — likes + a review
seed_user trinity trinity@movieverse.local ''
like     "$M_DARK"   MOVIE 'The Dark Knight' "$P_DARK" 8.5
like     "$M_INTER"  MOVIE 'Interstellar'    "$P_INTER" 8.4
review   "$M_INTER"  MOVIE 'Interstellar'    "$P_INTER" 9 'Do not go gentle. Visually stunning.'

# morpheus — the MODERATOR (can triage reports / moderate)
seed_user morpheus morpheus@movieverse.local mod
like     "$M_MATRIX" MOVIE 'The Matrix'   "$P_MATRIX" 8.2
review   "$M_MATRIX" MOVIE 'The Matrix'   "$P_MATRIX" 10 'Free your mind.'

# cypher — fresh standard account
seed_user cypher cypher@movieverse.local ''

# ── emit frontend config (same-origin: url="" → nginx proxies /auth /rest /tmdb) ──
mkdir -p vendor/MovieVerse/dist/js
cat > vendor/MovieVerse/dist/js/config.js <<EOF
// generated by scripts/seed/movieverse-tenant.sh — DO NOT COMMIT (env-specific)
window.__GROBASE__ = {
  url: "",
  anonKey: "${ANON}",
  tmdbBase: "/tmdb/v1"
};
EOF
info "wrote vendor/MovieVerse/dist/js/config.js"

# ── state file for `make movieverse-creds` ───────────────────────────────────
{
  printf '# generated by scripts/seed/movieverse-tenant.sh — %s\n' "$(date -u +%FT%TZ)"
  printf 'MV_PASSWORD=%s\n' "$PASSWORD"
  for e in "${EMAILS[@]}"; do printf 'MV_USER=%s\n' "$e"; done
} > "$STATE"

printf "${G}${W}MovieVerse logins${Z} (password: ${W}%s${Z})\n" "$PASSWORD"
printf "  %-28s %s\n" "neo@movieverse.local"      "cinephile — likes + reviews"
printf "  %-28s %s\n" "trinity@movieverse.local"  "likes + a review"
printf "  %-28s %s\n" "morpheus@movieverse.local" "MODERATOR — can moderate"
printf "  %-28s %s\n" "cypher@movieverse.local"   "fresh account"
printf "${G}[movieverse] DONE${Z}\n"
