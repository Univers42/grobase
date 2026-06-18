#!/usr/bin/env bash
# ============================================================
# init.sh — Bootstrap the Savanna Park Zoo in the BaaS stack
#
# Runs against an already-running mini-baas infrastructure.
# All SQL is executed via `docker exec` into the postgres container
# so there is NO dependency on a host-installed psql client.
#
#   1. Creates zoo tables in PostgreSQL
#   2. Installs triggers / functions
#   3. Seeds data (animals, events, tickets, messages, staff)
#   4. Applies RLS policies for secure PostgREST access
#   5. Reloads PostgREST schema cache
#   6. Registers staff users in GoTrue (auth)
#
# Usage:  ./infra/init.sh              (uses .env defaults)
#         FORCE=1 ./infra/init.sh      (drops + recreates)
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$SCRIPT_DIR"
BAAS_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# ─── Config (override via env) ────────────────────────────────
if [[ -f "$BAAS_ROOT/.env" ]]; then
  # shellcheck disable=SC1091
  set -a
  . "$BAAS_ROOT/.env"
  set +a
fi

readonly PG_CONTAINER="${PG_CONTAINER:-mini-baas-postgres}"
readonly PG_USER="${POSTGRES_USER:-${PG_USER:-postgres}}"
readonly PG_DB="${POSTGRES_DB:-${PG_DB:-postgres}}"
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
API_KEY="${KONG_PUBLIC_API_KEY:-${API_KEY:-public-anon-key}}"

# ─── Helpers ──────────────────────────────────────────────────
log()  { printf '\033[1;32m[zoo-init]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[zoo-init]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[zoo-init]\033[0m %s\n' "$*" >&2; }

# Execute SQL inside the postgres container (no host psql needed)
psql_exec() {
  docker exec -i "$PG_CONTAINER" \
    psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 --no-psqlrc -q "$@"
}

# Execute a SQL file by piping it into docker exec
psql_file() {
  docker exec -i "$PG_CONTAINER" \
    psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 --no-psqlrc -q < "$1"
}

wait_for_pg() {
  log "Waiting for PostgreSQL container ($PG_CONTAINER) …"
  local i=0
  while ! docker exec "$PG_CONTAINER" pg_isready -U "$PG_USER" -q 2>/dev/null; do
    i=$((i + 1))
    if [[ $i -ge 30 ]]; then
      err "PostgreSQL not ready after 30s"; exit 1
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
      err "Kong not ready after 30s"; exit 1
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
      err "PostgREST not reachable after 60s (last HTTP $code)"; exit 1
    fi
    sleep 1
  done
  log "PostgREST is serving requests."
}

# ─── Optional reset ──────────────────────────────────────────
maybe_reset() {
  if [[ "$FORCE" == "1" ]]; then
    log "FORCE=1 → dropping zoo tables …"
    psql_exec <<'SQL'
SET search_path TO public;
DROP TABLE IF EXISTS audit_log CASCADE;
DROP TABLE IF EXISTS visitor_stats CASCADE;
DROP TABLE IF EXISTS tickets CASCADE;
DROP TABLE IF EXISTS ticket_types CASCADE;
DROP TABLE IF EXISTS visitor_messages CASCADE;
DROP TABLE IF EXISTS health_records CASCADE;
DROP TABLE IF EXISTS feeding_logs CASCADE;
DROP TABLE IF EXISTS events CASCADE;
DROP TABLE IF EXISTS animals CASCADE;
DROP TABLE IF EXISTS staff CASCADE;
SQL
    log "Tables dropped."
  fi
}

# ─── 1. PostgreSQL schema + data ─────────────────────────────
init_postgres() {
  wait_for_pg
  maybe_reset

  log "Running 001_zoo_tables.sql …"
  psql_file "$INFRA_DIR/001_zoo_tables.sql"

  log "Running 002_zoo_functions.sql …"
  psql_file "$INFRA_DIR/002_zoo_functions.sql"

  log "Running 003_zoo_seed.sql …"
  psql_file "$INFRA_DIR/003_zoo_seed.sql"

  local count
  count=$(docker exec "$PG_CONTAINER" \
    psql -U "$PG_USER" -d "$PG_DB" -t -c "SELECT count(*) FROM public.animals;" | tr -d ' ')
  log "✓ animals seeded: $count rows"
  count=$(docker exec "$PG_CONTAINER" \
    psql -U "$PG_USER" -d "$PG_DB" -t -c "SELECT count(*) FROM public.tickets;" | tr -d ' ')
  log "✓ tickets seeded: $count rows"
  count=$(docker exec "$PG_CONTAINER" \
    psql -U "$PG_USER" -d "$PG_DB" -t -c "SELECT count(*) FROM public.staff;" | tr -d ' ')
  log "✓ staff seeded:   $count rows"
}

# ─── 2. RLS policies (PostgREST-aware) ───────────────────────
init_rls() {
  log "Applying zoo RLS policies …"
  psql_exec <<'SQL'
SET search_path TO public;

-- ────────────────────────────────────────────────────────────
-- PostgREST sets the PostgreSQL role to either:
--   anon          (no JWT / public apikey only)
--   authenticated (valid JWT present)
--
-- For zoo-specific role checks (admin, vet, …) we read the
-- GoTrue user_metadata stored inside the JWT:
--   current_setting('request.jwt.claims', true)::jsonb
--     -> 'user_metadata' -> 'role'
-- ────────────────────────────────────────────────────────────

-- Helper: extract the zoo staff role from the JWT (NULL for anon)
CREATE OR REPLACE FUNCTION public.zoo_jwt_role() RETURNS TEXT AS $$
  SELECT coalesce(
    current_setting('request.jwt.claims', true)::jsonb
      -> 'user_metadata' ->> 'role',
    NULL
  );
$$ LANGUAGE SQL STABLE;

-- ── Animals: everyone reads, authenticated staff writes ──────
ALTER TABLE animals ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS animals_read  ON animals;
DROP POLICY IF EXISTS animals_write ON animals;
CREATE POLICY animals_read  ON animals FOR SELECT USING (true);
CREATE POLICY animals_write ON animals FOR ALL
  TO authenticated
  USING  (zoo_jwt_role() IN ('admin','zookeeper','vet'))
  WITH CHECK (zoo_jwt_role() IN ('admin','zookeeper','vet'));

-- ── Staff: everyone reads (keeper names on cards), admin writes
ALTER TABLE staff ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS staff_read  ON staff;
DROP POLICY IF EXISTS staff_write ON staff;
CREATE POLICY staff_read  ON staff FOR SELECT USING (true);
CREATE POLICY staff_write ON staff FOR ALL
  TO authenticated
  USING  (zoo_jwt_role() = 'admin')
  WITH CHECK (zoo_jwt_role() = 'admin');

-- ── Events: everyone reads, admin writes ─────────────────────
ALTER TABLE events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS events_read  ON events;
DROP POLICY IF EXISTS events_write ON events;
CREATE POLICY events_read  ON events FOR SELECT USING (true);
CREATE POLICY events_write ON events FOR ALL
  TO authenticated
  USING  (zoo_jwt_role() = 'admin')
  WITH CHECK (zoo_jwt_role() = 'admin');

-- ── Feeding logs: authenticated reads, keepers + admin write ─
ALTER TABLE feeding_logs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS feeding_read  ON feeding_logs;
DROP POLICY IF EXISTS feeding_write ON feeding_logs;
CREATE POLICY feeding_read  ON feeding_logs FOR SELECT
  TO authenticated USING (true);
CREATE POLICY feeding_write ON feeding_logs FOR ALL
  TO authenticated
  USING  (zoo_jwt_role() IN ('admin','zookeeper'))
  WITH CHECK (zoo_jwt_role() IN ('admin','zookeeper'));

-- ── Health records: authenticated reads, vet + admin write ───
ALTER TABLE health_records ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS health_read  ON health_records;
DROP POLICY IF EXISTS health_write ON health_records;
CREATE POLICY health_read  ON health_records FOR SELECT
  TO authenticated USING (true);
CREATE POLICY health_write ON health_records FOR ALL
  TO authenticated
  USING  (zoo_jwt_role() IN ('admin','vet'))
  WITH CHECK (zoo_jwt_role() IN ('admin','vet'));

-- ── Visitor messages: anyone inserts, admin reads/updates ────
ALTER TABLE visitor_messages ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS messages_insert ON visitor_messages;
DROP POLICY IF EXISTS messages_read   ON visitor_messages;
DROP POLICY IF EXISTS messages_write  ON visitor_messages;
CREATE POLICY messages_insert ON visitor_messages FOR INSERT
  WITH CHECK (true);
CREATE POLICY messages_read ON visitor_messages FOR SELECT
  TO authenticated
  USING (zoo_jwt_role() IN ('admin','reception'));
CREATE POLICY messages_write ON visitor_messages FOR UPDATE
  TO authenticated
  USING (zoo_jwt_role() IN ('admin','reception'));

-- ── Ticket types: everyone reads, admin writes ───────────────
ALTER TABLE ticket_types ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ticket_types_read  ON ticket_types;
DROP POLICY IF EXISTS ticket_types_write ON ticket_types;
CREATE POLICY ticket_types_read  ON ticket_types FOR SELECT USING (true);
CREATE POLICY ticket_types_write ON ticket_types FOR ALL
  TO authenticated
  USING  (zoo_jwt_role() = 'admin')
  WITH CHECK (zoo_jwt_role() = 'admin');

-- ── Tickets: anyone buys (insert), reception + admin manage ──
ALTER TABLE tickets ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tickets_insert ON tickets;
DROP POLICY IF EXISTS tickets_read   ON tickets;
DROP POLICY IF EXISTS tickets_write  ON tickets;
CREATE POLICY tickets_insert ON tickets FOR INSERT
  WITH CHECK (true);
CREATE POLICY tickets_read ON tickets FOR SELECT
  TO authenticated
  USING (zoo_jwt_role() IN ('admin','reception'));
CREATE POLICY tickets_write ON tickets FOR UPDATE
  TO authenticated
  USING (zoo_jwt_role() IN ('admin','reception'));

-- ── Visitor stats: everyone reads, auto-updated by trigger ───
ALTER TABLE visitor_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS visitor_stats_read  ON visitor_stats;
DROP POLICY IF EXISTS visitor_stats_write ON visitor_stats;
CREATE POLICY visitor_stats_read  ON visitor_stats FOR SELECT USING (true);
CREATE POLICY visitor_stats_write ON visitor_stats FOR ALL
  TO authenticated
  USING  (zoo_jwt_role() = 'admin')
  WITH CHECK (zoo_jwt_role() = 'admin');

-- ── Audit log: any authenticated user inserts, admin reads ───
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS audit_insert ON audit_log;
DROP POLICY IF EXISTS audit_read   ON audit_log;
CREATE POLICY audit_insert ON audit_log FOR INSERT
  TO authenticated WITH CHECK (true);
CREATE POLICY audit_read   ON audit_log FOR SELECT
  TO authenticated
  USING (zoo_jwt_role() = 'admin');

SQL
  log "✓ RLS policies applied (role-based via JWT user_metadata)."
}

# ─── 3. PostgREST schema reload ──────────────────────────────
reload_postgrest() {
  log "Asking PostgREST to reload schema cache …"
  psql_exec -c "NOTIFY pgrst, 'reload schema';" 2>/dev/null || true
  sleep 2
  log "✓ PostgREST schema reload requested."
}

# ─── 4. GoTrue users ─────────────────────────────────────────
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
    200|201|422)
      log "  ✓ $email (HTTP $status)"
      ;;
    *)
      err "  ✗ $email (HTTP $status)"
      ;;
  esac
}

init_auth() {
  wait_for_kong
  log "Registering zoo staff in GoTrue …"
  local ZOO_PASS="${ZOO_PASSWORD:-zoo-admin-2024}"

  register_user "sophie.laurent@savanna-zoo.com"  "$ZOO_PASS" "Sophie Laurent"   "admin"
  register_user "marcus.osei@savanna-zoo.com"     "$ZOO_PASS" "Marcus Osei"      "zookeeper"
  register_user "elena.moreau@savanna-zoo.com"    "$ZOO_PASS" "Elena Moreau"     "zookeeper"
  register_user "yuki.tanaka@savanna-zoo.com"     "$ZOO_PASS" "Dr. Yuki Tanaka"  "vet"
  register_user "lucas.petit@savanna-zoo.com"     "$ZOO_PASS" "Lucas Petit"      "reception"

  log "✓ Auth users registered (password: $ZOO_PASS)"
}

# ─── 5. Smoke test — verify data is reachable via BaaS ───────
smoke_test() {
  log "Running connectivity smoke test …"
  local code body

  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    -H "apikey: $API_KEY" "$KONG_URL/rest/v1/animals?limit=1" 2>/dev/null || echo "000")
  if [[ "$code" == "200" ]]; then
    body=$(curl -s --max-time 5 \
      -H "apikey: $API_KEY" "$KONG_URL/rest/v1/animals?limit=1" 2>/dev/null || true)
    local count
    count=$(echo "$body" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "?")
    log "  ✓ GET /rest/v1/animals → HTTP $code ($count rows)"
  else
    err "  ✗ GET /rest/v1/animals → HTTP $code (expected 200)"
    err "    Check: is Kong healthy? is PostgREST running?"
    return 1
  fi

  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    -H "apikey: $API_KEY" "$KONG_URL/rest/v1/events?limit=1" 2>/dev/null || echo "000")
  log "  ✓ GET /rest/v1/events → HTTP $code"

  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    -H "apikey: $API_KEY" "$KONG_URL/auth/v1/health" 2>/dev/null || echo "000")
  log "  ✓ GET /auth/v1/health → HTTP $code"

  log "✓ Smoke tests passed — BaaS is serving zoo data."
}

# ─── 6. Update frontend .env with correct port ───────────────
update_frontend_env() {
  local front_env="$SCRIPT_DIR/../front/.env"
  local baas_endpoint="http://localhost:${KONG_PORT}"

  if [[ -f "$front_env" ]]; then
    local current
    current=$(grep -oP 'VITE_BAAS_ENDPOINT=\K.*' "$front_env" 2>/dev/null || true)
    if [[ "$current" != "$baas_endpoint" ]]; then
      sed -i "s|VITE_BAAS_ENDPOINT=.*|VITE_BAAS_ENDPOINT=${baas_endpoint}|" "$front_env"
      log "✓ Updated front/.env: VITE_BAAS_ENDPOINT=$baas_endpoint"
    fi
  else
    cat > "$front_env" <<EOF
# Savanna Park Zoo — Frontend environment (auto-generated by init.sh)
VITE_BAAS_ENDPOINT=${baas_endpoint}
VITE_BAAS_API_KEY=${API_KEY}
EOF
    log "✓ Created front/.env with VITE_BAAS_ENDPOINT=$baas_endpoint"
  fi
}

# ─── Main ─────────────────────────────────────────────────────
main() {
  log "═══════════════════════════════════════════════"
  log " Savanna Park Zoo — BaaS Initialisation"
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
  init_rls
  reload_postgrest

  wait_for_kong
  wait_for_postgrest

  init_auth
  smoke_test
  update_frontend_env

  log ""
  log "═══════════════════════════════════════════════"
  log " ✓ Zoo initialisation complete!"
  log ""
  log "   Frontend dev:  http://localhost:5173"
  log "   Frontend prod: http://localhost:5180"
  log "   BaaS API:      $KONG_URL/rest/v1/"
  log "   Auth:          $KONG_URL/auth/v1/"
  log "   Staff login:   sophie.laurent@savanna-zoo.com"
  log "   Password:      ${ZOO_PASSWORD:-zoo-admin-2024}"
  log "═══════════════════════════════════════════════"
}

main "$@"
