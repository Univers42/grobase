#!/usr/bin/env bash
# ============================================================
# m154 — Savanna Park Zoo on Grobase (PostgREST + GoTrue + RLS + realtime)
#
# Proves the vendor/savanna-zoo re-platform works on the live Grobase stack:
#   (A) DATA      : zoo tables seeded in public (animals/staff/tickets…)
#   (B) RLS ROLES : anon reads public catalog but NOT admin-only tickets;
#                   admin (Sophie) reads tickets; zookeeper (Marcus) is denied
#                   a staff write (admin-only) → 0 rows affected
#   (C) TRIGGERS  : ticket insert auto-generates a ZOO-YYYYMMDD QR code AND
#                   bumps visitor_stats for the visit date
#   (D) REALTIME  : the auto-installed pg LISTEN/NOTIFY trigger is present on
#                   animals (so a PostgREST write publishes pg/animals/updated)
#
# Requires a running stack + a prior `bash vendor/savanna-zoo/infra/init.sh`.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PG="${PG_CONTAINER:-mini-baas-postgres}"
ANON="$(grep -E '^ANON_KEY=' "$ROOT/.env" | cut -d= -f2)"
KPORT="$(docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://' || echo 8000)"
GW="http://localhost:${KPORT:-8000}"
PASS="${ZOO_PASSWORD:-zoo-admin-2024}"
ok() { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

login() { # $1=email -> echoes access_token
  curl -s -X POST "$GW/auth/v1/token?grant_type=password" -H "apikey: $ANON" \
    -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"$PASS\"}" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))"
}
jlen() { python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else -1)"; }

printf '\n\033[1mm154 — Savanna Park Zoo on Grobase\033[0m  (%s)\n' "$GW"

# ── (A) data seeded ──────────────────────────────────────────
A=$(docker exec "$PG" psql -U postgres -d postgres -tAc "SELECT count(*) FROM public.animals;" | tr -d ' ')
S=$(docker exec "$PG" psql -U postgres -d postgres -tAc "SELECT count(*) FROM public.staff;" | tr -d ' ')
T=$(docker exec "$PG" psql -U postgres -d postgres -tAc "SELECT count(*) FROM public.tickets;" | tr -d ' ')
[ "$A" -ge 12 ] && [ "$S" -ge 5 ] && [ "$T" -ge 200 ] || fail "data not seeded (animals=$A staff=$S tickets=$T)"
ok "data seeded: animals=$A staff=$S tickets=$T"

# ── (B) RLS role isolation ───────────────────────────────────
ANON_ANIMALS=$(curl -s "$GW/rest/v1/animals?select=id" -H "apikey: $ANON" | jlen)
[ "$ANON_ANIMALS" -ge 12 ] || fail "anon cannot read public animals ($ANON_ANIMALS)"
ANON_TICKETS=$(curl -s "$GW/rest/v1/tickets?select=id" -H "apikey: $ANON" | jlen)
[ "$ANON_TICKETS" = "0" ] || fail "anon should NOT see tickets (RLS) — got $ANON_TICKETS"
ok "RLS: anon reads animals ($ANON_ANIMALS), tickets hidden ($ANON_TICKETS)"

ATOK="$(login sophie.laurent@savanna-zoo.com)"; [ -n "$ATOK" ] || fail "admin login failed"
ADMIN_TICKETS=$(curl -s "$GW/rest/v1/tickets?select=id&limit=5" -H "apikey: $ANON" -H "Authorization: Bearer $ATOK" | jlen)
[ "$ADMIN_TICKETS" -ge 1 ] || fail "admin cannot read tickets ($ADMIN_TICKETS)"
ok "RLS: admin (Sophie) reads tickets ($ADMIN_TICKETS)"

MTOK="$(login marcus.osei@savanna-zoo.com)"; [ -n "$MTOK" ] || fail "zookeeper login failed"
SID=$(curl -s "$GW/rest/v1/staff?select=id&limit=1" -H "apikey: $ANON" -H "Authorization: Bearer $MTOK" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")
DENIED=$(curl -s -X PATCH "$GW/rest/v1/staff?id=eq.$SID" -H "apikey: $ANON" -H "Authorization: Bearer $MTOK" \
  -H 'Content-Type: application/json' -H 'Prefer: return=representation' -d '{"phone":"BLOCKED"}' | jlen)
[ "$DENIED" = "0" ] || fail "zookeeper staff-write should be RLS-blocked (0 rows) — got $DENIED"
ok "RLS: zookeeper (Marcus) staff-write blocked ($DENIED rows)"

# ── (C) triggers: QR + visitor_stats ─────────────────────────
TTID=$(curl -s "$GW/rest/v1/ticket_types?select=id&limit=1" -H "apikey: $ANON" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")
NEW=$(curl -s -X POST "$GW/rest/v1/tickets" -H "apikey: $ANON" -H "Authorization: Bearer $ATOK" \
  -H 'Content-Type: application/json' -H 'Prefer: return=representation' \
  -d "{\"ticket_type_id\":\"$TTID\",\"visitor_name\":\"m154 gate\",\"visitor_email\":\"g@t.co\",\"visit_date\":\"2026-09-09\",\"quantity\":3,\"total_eur\":\"74.70\",\"status\":\"valid\"}")
QR=$(echo "$NEW" | python3 -c "import sys,json;print(json.load(sys.stdin)[0].get('qr_code',''))")
echo "$QR" | grep -qE '^ZOO-20260909-' || fail "QR trigger did not fire (qr=$QR)"
VS=$(docker exec "$PG" psql -U postgres -d postgres -tAc "SELECT total_visitors FROM public.visitor_stats WHERE stat_date='2026-09-09';" | tr -d ' ')
[ "${VS:-0}" -ge 3 ] || fail "visitor_stats trigger did not aggregate (got '$VS')"
ok "triggers: QR=$QR · visitor_stats(2026-09-09)=$VS"
docker exec "$PG" psql -U postgres -d postgres -tAc "DELETE FROM public.tickets WHERE visitor_name='m154 gate'; DELETE FROM public.visitor_stats WHERE stat_date='2026-09-09';" >/dev/null

# ── (D) realtime plumbing ────────────────────────────────────
RT=$(docker exec "$PG" psql -U postgres -d postgres -tAc "SELECT count(*) FROM pg_trigger WHERE tgrelid='public.animals'::regclass AND tgname='animals_realtime_trigger';" | tr -d ' ')
[ "$RT" = "1" ] || fail "animals_realtime_trigger missing — PostgREST writes won't publish realtime"
ok "realtime: animals_realtime_trigger installed (pg/animals/* publishes on write)"

printf '\n\033[1;32mm154 PASS — savanna-zoo runs on Grobase (data · RLS roles · triggers · realtime)\033[0m\n'
