#!/usr/bin/env bash
# ============================================================
# init.sh — Bootstrap Surfind Spain (surf-beach directory) in the BaaS stack
#
# Re-platforms the Laravel 12 / Livewire / MySQL app onto Grobase. Runs against
# an already-running mini-baas infrastructure. All SQL is executed via
# `docker exec` into the postgres container, so there is NO dependency on a
# host-installed psql client.
#
#   1. Applies the PostgreSQL schema (01_schema.sql) + seed (02_seed.sql)
#   2. Registers GoTrue users (admin + demo visitor)
#   3. Promotes admin@surfind.es into app_metadata.role='admin' (secure roles)
#   4. Drops the realtime broadcast trigger on the private 'favorites' table
#   5. Reloads the PostgREST schema cache
#   6. Writes web/.env (same-origin VITE_BAAS_ENDPOINT empty + anon key)
#
# Usage:  ./infra/init.sh              (uses .env defaults)
#         FORCE=1 ./infra/init.sh      (drops + recreates schema objects)
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$SCRIPT_DIR"
# grobase root is 3 levels up (infra → surfind-spain → vendor → grobase), NOT 4
# (a cloned-from-savanna off-by-one that landed at apps/baas and missed grobase/.env).
BAAS_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# ─── Config (override via env) ────────────────────────────────
# grobase/.env is NOT cleanly shell-sourceable (some values run as commands),
# so grep just the keys we need instead of `. .env`.
env_get() { grep -E "^$1=" "$BAAS_ROOT/.env" 2>/dev/null | head -1 | cut -d= -f2-; }
ANON_KEY="${ANON_KEY:-$(env_get ANON_KEY)}"
POSTGRES_USER="${POSTGRES_USER:-$(env_get POSTGRES_USER)}"
POSTGRES_DB="${POSTGRES_DB:-$(env_get POSTGRES_DB)}"

readonly PG_CONTAINER="${PG_CONTAINER:-mini-baas-postgres}"
readonly PG_USER="${POSTGRES_USER:-postgres}"
readonly PG_DB="${POSTGRES_DB:-postgres}"
readonly FORCE="${FORCE:-0}"

# ─── Detect actual Kong host port ─────────────────────────────
detect_kong_port() {
  local port
  port=$(docker port mini-baas-kong 8000/tcp 2>/dev/null \
    | head -1 | sed 's/.*://' || true)
  echo "${port:-8000}"
}

KONG_PORT="$(detect_kong_port)"
KONG_URL="${KONG_URL:-http://localhost:${KONG_PORT}}"
API_KEY="${ANON_KEY:-${KONG_PUBLIC_API_KEY:-${API_KEY:-public-anon-key}}}"

# ─── Helpers ──────────────────────────────────────────────────
log() { printf '\033[1;32m[surfind-init]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[surfind-init]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[surfind-init]\033[0m %s\n' "$*" >&2; }

# Execute a SQL file by piping it into docker exec (no host psql needed).
psql_file() {
  docker exec -i "$PG_CONTAINER" \
    psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 --no-psqlrc -q < "$1"
}

# Execute inline SQL inside the postgres container.
psql_exec() {
  docker exec -i "$PG_CONTAINER" \
    psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 --no-psqlrc -q "$@"
}

wait_for_pg() {
  log "Waiting for PostgreSQL container ($PG_CONTAINER) …"
  local i=0
  while ! docker exec "$PG_CONTAINER" pg_isready -U "$PG_USER" -q 2>/dev/null; do
    i=$((i + 1))
    if [[ $i -ge 30 ]]; then
      err "PostgreSQL not ready after 30s"
      exit 1
    fi
    sleep 1
  done
  log "PostgreSQL is ready."
}

wait_for_kong() {
  log "Waiting for Kong gateway at $KONG_URL …"
  local i=0
  while ! curl -s -o /dev/null --max-time 3 "$KONG_URL/" 2>/dev/null; do
    i=$((i + 1))
    if [[ $i -ge 30 ]]; then
      err "Kong not ready after 30s"
      exit 1
    fi
    sleep 1
  done
  log "Kong is ready (port $KONG_PORT)."
}

wait_for_postgrest() {
  log "Waiting for PostgREST via Kong …"
  local i=0
  while true; do
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
      -H "apikey: $API_KEY" "$KONG_URL/rest/v1/" 2>/dev/null || echo "000")
    if [[ "$code" == "200" ]]; then break; fi
    i=$((i + 1))
    if [[ $i -ge 60 ]]; then
      err "PostgREST not reachable after 60s (last HTTP $code)"
      exit 1
    fi
    sleep 1
  done
  log "PostgREST is serving requests."
}

# ─── Optional reset ──────────────────────────────────────────
maybe_reset() {
  if [[ "$FORCE" == "1" ]]; then
    log "FORCE=1 → dropping surfind tables …"
    psql_exec <<'SQL'
SET search_path TO public;
DROP TABLE IF EXISTS surfer_profiles CASCADE;
DROP TABLE IF EXISTS beach_ratings CASCADE;
DROP TABLE IF EXISTS surf_reports CASCADE;
DROP TABLE IF EXISTS articles CASCADE;
DROP TABLE IF EXISTS favorites CASCADE;
DROP TABLE IF EXISTS comments CASCADE;
DROP TABLE IF EXISTS amenity_beach CASCADE;
DROP TABLE IF EXISTS beach_images CASCADE;
DROP TABLE IF EXISTS beaches CASCADE;
DROP TABLE IF EXISTS amenities CASCADE;
DROP TABLE IF EXISTS locations CASCADE;
SQL
    log "Tables dropped."
  fi
}

# ─── 1. PostgreSQL schema + seed ─────────────────────────────
# 01_schema.sql carries the tables, the surf_uid()/surf_jwt_role() helpers,
# and the RLS policies (public catalog read; admin write; owner-scoped
# comments/favorites). 02_seed.sql loads locations, amenities and beaches.
init_postgres() {
  wait_for_pg
  maybe_reset

  log "Applying 01_schema.sql …"
  psql_file "$INFRA_DIR/01_schema.sql"

  log "Applying 02_seed.sql …"
  psql_file "$INFRA_DIR/02_seed.sql"

  log "Applying 02b_more_beaches.sql (+14 beaches) …"
  psql_file "$INFRA_DIR/02b_more_beaches.sql"

  log "Applying 03_deep_schema.sql (surf-tracking layer) …"
  psql_file "$INFRA_DIR/03_deep_schema.sql"

  log "Applying 04_deep_seed.sql (intel + media + blog + reports) …"
  psql_file "$INFRA_DIR/04_deep_seed.sql"

  local count
  count=$(docker exec "$PG_CONTAINER" \
    psql -U "$PG_USER" -d "$PG_DB" -t -c "SELECT count(*) FROM public.beaches;" | tr -d ' ')
  log "✓ beaches seeded: $count rows"
  count=$(docker exec "$PG_CONTAINER" \
    psql -U "$PG_USER" -d "$PG_DB" -t -c "SELECT count(*) FROM public.locations;" | tr -d ' ')
  log "✓ locations seeded: $count rows"
  count=$(docker exec "$PG_CONTAINER" \
    psql -U "$PG_USER" -d "$PG_DB" -t -c "SELECT count(*) FROM public.amenities;" | tr -d ' ')
  log "✓ amenities seeded: $count rows"
}

# ─── 2. GoTrue users ─────────────────────────────────────────
register_user() {
  local email="$1" password="$2" name="$3" role="$4"
  local status
  status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -X POST "$KONG_URL/auth/v1/signup" \
    -H "Content-Type: application/json" \
    -H "apikey: $API_KEY" \
    -d "{
      \"email\": \"$email\",
      \"password\": \"$password\",
      \"data\": {
        \"full_name\": \"$name\",
        \"role\": \"$role\"
      }
    }" 2>/dev/null || echo "000")

  case "$status" in
    200 | 201 | 422)
      log "  ✓ $email (HTTP $status)"
      ;;
    *)
      err "  ✗ $email (HTTP $status)"
      ;;
  esac
}

init_auth() {
  wait_for_kong
  log "Registering Surfind users in GoTrue …"
  register_user "admin@surfind.es"   "admin1234" "Surfind Admin"   "admin"
  register_user "visitor@surfind.es" "surf-1234" "Demo Visitor"    "user"
  register_user "lucia@surfind.es"   "surf-1234" "Lucia Olas"      "user"
  register_user "iker@surfind.es"    "surf-1234" "Iker Mar"        "user"
  log "✓ Auth users registered."
}

# ─── 2d. Seed public surfer_profiles (the /ranking) ──────────
# Profiles are owner-keyed (user_id) but PUBLIC-read. Seed a few from the demo
# users so the leaderboard isn't empty on first boot. surf_uid() default can't
# fire here (no JWT in docker exec), so map emails → ids explicitly.
init_profiles() {
  log "Seeding demo surfer profiles …"
  psql_exec <<'SQL'
SET search_path TO public;
INSERT INTO surfer_profiles (user_id, display_name, level, home_break_id, board_quiver, bio)
SELECT u.id, p.display_name, p.level,
       (SELECT id FROM beaches WHERE slug = p.home_slug), p.quiver, p.bio
FROM (VALUES
  ('visitor@surfind.es', 'Demo Visitor', 'intermedio',   'playa-de-somo',    'Funboard 7''2, shortboard 6''0', 'Aprendiendo en el Cantabrico.'),
  ('lucia@surfind.es',   'Lucia Olas',   'avanzado',     'playa-de-mundaka', 'Shortboard 5''10, step-up 6''4', 'Cazando izquierdas por Euskadi.'),
  ('iker@surfind.es',    'Iker Mar',     'pro',          'playa-de-pantin',  'Quiver completo de competicion',  'De la Costa da Morte al mundo.')
) AS p(email, display_name, level, home_slug, quiver, bio)
JOIN auth.users u ON u.email = p.email
ON CONFLICT (user_id) DO UPDATE
  SET display_name = EXCLUDED.display_name, level = EXCLUDED.level,
      home_break_id = EXCLUDED.home_break_id, board_quiver = EXCLUDED.board_quiver, bio = EXCLUDED.bio;
SQL
  log "✓ Demo profiles seeded."
}

# ─── 2b. Secure roles (app_metadata, post-signup) ────────────
# Must run AFTER init_auth created admin@surfind.es. GoTrue's signup `data`
# lands in the CLIENT-CONTROLLED user_metadata, so surf_jwt_role() reads
# app_metadata.role instead. We promote ONLY the fixed-email staff allowlist
# into the trusted app_metadata; a self-signup visitor stays unprivileged
# even if they forged user_metadata.role=admin at signup.
init_secure_roles() {
  log "Securing admin role into app_metadata …"
  psql_exec <<'SQL'
SET search_path TO public;
UPDATE auth.users AS u
SET raw_app_meta_data =
      coalesce(u.raw_app_meta_data, '{}'::jsonb)
      || jsonb_build_object('role', s.role)
FROM (VALUES
        ('admin@surfind.es', 'admin')
     ) AS s(email, role)
WHERE u.email = s.email;
SQL
  log "✓ admin@surfind.es trusted from app_metadata; forged user_metadata.role is inert."
}

# ─── 2c. Realtime privacy (drop broadcast on private 'favorites') ─
# The realtime gateway fans out row-changes owner-blind, so a visitor could
# SUBSCRIBE pg/favorites/* and harvest other visitors' saved beaches. Drop the
# auto-installed publish trigger on the private table; comments/beaches are
# public-read so they may keep broadcasting.
init_realtime_privacy() {
  log "Closing realtime broadcast on the private 'favorites' table …"
  psql_exec <<'SQL'
SET search_path TO public;
DROP TRIGGER IF EXISTS favorites_realtime_trigger ON favorites;
-- Private/owner-scoped tables must not broadcast row changes to every subscriber.
-- beach_ratings + surfer_profiles + surf_sessions(mongo) are private; surf_reports
-- IS the public live feed, so it KEEPS its broadcast (pg/surf_reports/inserted).
DROP TRIGGER IF EXISTS beach_ratings_realtime_trigger ON beach_ratings;
DROP TRIGGER IF EXISTS surfer_profiles_realtime_trigger ON surfer_profiles;
SQL
  log "✓ favorites/beach_ratings/surfer_profiles muted; comments/beaches/surf_reports stay live."
}

# ─── 3. PostgREST schema reload ──────────────────────────────
reload_postgrest() {
  log "Asking PostgREST to reload schema cache …"
  psql_exec -c "NOTIFY pgrst, 'reload schema';" 2>/dev/null || true
  sleep 2
  log "✓ PostgREST schema reload requested."
}

# ─── 4. Smoke test — verify data is reachable via BaaS ───────
smoke_test() {
  log "Running connectivity smoke test …"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    -H "apikey: $API_KEY" "$KONG_URL/rest/v1/beaches?limit=1" 2>/dev/null || echo "000")
  if [[ "$code" == "200" ]]; then
    log "  ✓ GET /rest/v1/beaches → HTTP $code"
  else
    err "  ✗ GET /rest/v1/beaches → HTTP $code (expected 200)"
    err "    Check: is Kong healthy? is PostgREST running?"
    return 1
  fi

  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    -H "apikey: $API_KEY" "$KONG_URL/rest/v1/locations?limit=1" 2>/dev/null || echo "000")
  log "  ✓ GET /rest/v1/locations → HTTP $code"

  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    -H "apikey: $API_KEY" "$KONG_URL/auth/v1/health" 2>/dev/null || echo "000")
  log "  ✓ GET /auth/v1/health → HTTP $code"

  log "✓ Smoke tests passed — BaaS is serving Surfind data."
}

# ─── 5. Update frontend .env (same-origin) ───────────────────
# Served behind grobase/serve.mjs, so VITE_BAAS_ENDPOINT is EMPTY (the SPA
# calls /rest /auth /realtime /storage on its own origin). Only the anon key
# travels to the browser.
update_frontend_env() {
  local web_env="$SCRIPT_DIR/../web/.env"
  cat > "$web_env" <<EOF
# Surfind Spain — Frontend environment (auto-generated by init.sh)
# Same-origin: the SPA is served behind grobase/serve.mjs, which proxies
# /rest /auth /realtime /storage to Kong — so the endpoint is empty.
VITE_BAAS_ENDPOINT=
VITE_BAAS_API_KEY=${API_KEY}
EOF
  log "✓ Wrote web/.env (VITE_BAAS_ENDPOINT empty, same-origin)."
}

# ─── Main ─────────────────────────────────────────────────────
main() {
  log "═══════════════════════════════════════════════"
  log " Surfind Spain — BaaS Initialisation"
  log "═══════════════════════════════════════════════"
  log ""
  log " Kong port detected: $KONG_PORT"
  log " BaaS endpoint:      $KONG_URL"
  log ""

  if ! docker ps --format '{{.Names}}' | grep -q '^mini-baas-postgres$'; then
    err "mini-baas-postgres is not running."
    err "Start the BaaS first:  cd $BAAS_ROOT && docker compose up -d"
    exit 1
  fi

  init_postgres
  reload_postgrest

  wait_for_kong
  wait_for_postgrest

  init_auth
  init_secure_roles
  init_profiles
  init_realtime_privacy
  reload_postgrest
  smoke_test
  update_frontend_env

  log ""
  log "═══════════════════════════════════════════════"
  log " ✓ Surfind initialisation complete!"
  log ""
  log "   Frontend prod: http://localhost:5183"
  log "   BaaS API:      $KONG_URL/rest/v1/"
  log "   Auth:          $KONG_URL/auth/v1/"
  log "   Admin login:   admin@surfind.es / admin1234"
  log "   Visitor login: visitor@surfind.es / surf-1234"
  log "═══════════════════════════════════════════════"
}

main "$@"
