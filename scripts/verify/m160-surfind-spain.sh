#!/usr/bin/env bash
# ============================================================
# m160 — Surfind Spain on Grobase (PostgREST + GoTrue + RLS)
#
# Proves the vendor/surfind-spain re-platform (Laravel/Livewire/MySQL Spanish
# surf-beach directory → Grobase) works on the live stack, and that each
# security property holds — no vacuous passes:
#
#   (A) DATA      : the catalog is seeded in public (beaches/locations/amenities)
#   (B) PUBLIC    : anon reads the published catalog (beaches/locations/amenities)
#                   but NOT the private, owner-scoped favorites
#   (C) OWNER     : two visitors A and B — A favorites + comments, A sees own,
#                   B sees 0 of A's favorites, B can READ A's published comment
#                   but cannot DELETE it; admin reads all + can delete
#   (D) ESCALATION: a self-signup visitor forging user_metadata.role=admin
#                   CANNOT write a beach — role is trusted from app_metadata only
#
# Requires a running stack + a prior `bash vendor/surfind-spain/infra/init.sh`
# (postgres schema, RLS, GoTrue users). Idempotent: gate-created rows
# (comments/favorites) are cleaned up at the end.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PG="${PG_CONTAINER:-mini-baas-postgres}"
ANON="$(grep -E '^ANON_KEY=' "$ROOT/.env" | cut -d= -f2)"
KPORT="$(docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://' || echo 8000)"
GW="http://localhost:${KPORT:-8000}"

A_EMAIL="sec-a@surfind.es"
B_EMAIL="sec-b@surfind.es"
VIS_PASS="surf-1234"
ADMIN_EMAIL="admin@surfind.es"
ADMIN_PASS="admin1234"
MARK="m160-surf"

ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
sect() { printf '\n\033[1m%s\033[0m\n' "$*"; }

jget() { python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('$1','') if isinstance(d,dict) else '')"; }
jlen() { python3 -c "import sys,json;d=json.load(sys.stdin);print(len(d) if isinstance(d,list) else -1)"; }

login() { # email password -> access_token
  curl -s -X POST "$GW/auth/v1/token?grant_type=password" -H "apikey: $ANON" \
    -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"$2\"}" | jget access_token
}
signup() { # email password role -> http code (200 new / 422 exists)
  curl -s -o /dev/null -w '%{http_code}' -X POST "$GW/auth/v1/signup" -H "apikey: $ANON" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$1\",\"password\":\"$2\",\"data\":{\"full_name\":\"$1\",\"role\":\"$3\"}}"
}
sub_of() { printf '%s' "$1" | cut -d. -f2 | python3 -c "import sys,base64,json;s=sys.stdin.read().strip();s+='='*(-len(s)%4);print(json.loads(base64.urlsafe_b64decode(s)).get('sub',''))"; }

printf '\n\033[1mm160 — Surfind Spain on Grobase · catalog público, scoping privado\033[0m  (%s)\n' "$GW"

# ── (A) data seeded ──────────────────────────────────────────
sect "(A) DATA — el catálogo está sembrado en public"
B=$(docker exec "$PG" psql -U postgres -d postgres -tAc "SELECT count(*) FROM public.beaches;" | tr -d ' ')
L=$(docker exec "$PG" psql -U postgres -d postgres -tAc "SELECT count(*) FROM public.locations;" | tr -d ' ')
AM=$(docker exec "$PG" psql -U postgres -d postgres -tAc "SELECT count(*) FROM public.amenities;" | tr -d ' ')
[ "$B" -ge 16 ] && [ "$L" -ge 24 ] && [ "$AM" -ge 8 ] || fail "data not seeded (beaches=$B locations=$L amenities=$AM)"
ok "data seeded: beaches=$B · locations=$L · amenities=$AM"

# ── (B) public catalog read vs private favorites ─────────────
sect "(B) PUBLIC READ — catálogo abierto, favoritos privados"
PB=$(curl -s "$GW/rest/v1/beaches?status=eq.published&select=id" -H "apikey: $ANON" | jlen)
[ "$PB" -ge 16 ] || fail "anon must read published beaches (got $PB)"
PL=$(curl -s "$GW/rest/v1/locations?select=id" -H "apikey: $ANON" | jlen)
[ "$PL" -ge 24 ] || fail "anon must read locations (got $PL)"
PA=$(curl -s "$GW/rest/v1/amenities?select=id" -H "apikey: $ANON" | jlen)
[ "$PA" -ge 8 ] || fail "anon must read amenities (got $PA)"
ok "anon catalog: beaches=$PB · locations=$PL · amenities=$PA"
PF=$(curl -s "$GW/rest/v1/favorites?select=user_id" -H "apikey: $ANON" | jlen)
[ "$PF" = "0" ] || fail "anon must NOT read favorites (private) — got $PF"
ok "anon favorites=$PF (private, owner-scoped)"

# ── (C) auth + owner-scoping ─────────────────────────────────
sect "(C) AUTH + OWNER-SCOPING — A y B aislados"
sa=$(signup "$A_EMAIL" "$VIS_PASS" user); [ "$sa" = "200" ] || [ "$sa" = "422" ] || fail "visitor A signup → $sa"
sb=$(signup "$B_EMAIL" "$VIS_PASS" user); [ "$sb" = "200" ] || [ "$sb" = "422" ] || fail "visitor B signup → $sb"
ok "self-signup A=$sa · B=$sb"
ATOK=$(login "$A_EMAIL" "$VIS_PASS"); [ -n "$ATOK" ] || fail "visitor A login failed"
BTOK=$(login "$B_EMAIL" "$VIS_PASS"); [ -n "$BTOK" ] || fail "visitor B login failed"
ADMTOK=$(login "$ADMIN_EMAIL" "$ADMIN_PASS"); [ -n "$ADMTOK" ] || fail "admin login failed"
ok "login → tokens issued (A · B · admin)"

A_SUB=$(sub_of "$ATOK"); B_SUB=$(sub_of "$BTOK")
docker exec "$PG" psql -U postgres -d postgres -tAc \
  "DELETE FROM public.favorites WHERE user_id IN ('$A_SUB','$B_SUB'); DELETE FROM public.comments WHERE content='$MARK comment';" >/dev/null 2>&1 || true

BID=$(curl -s "$GW/rest/v1/beaches?status=eq.published&select=id&limit=1" -H "apikey: $ANON" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")
[ -n "$BID" ] || fail "no published beach id to favorite"

FAV=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$GW/rest/v1/favorites" -H "apikey: $ANON" \
  -H "Authorization: Bearer $ATOK" -H 'Content-Type: application/json' -H 'Prefer: return=minimal' \
  -d "{\"beach_id\":$BID}")
[ "$FAV" = "201" ] || fail "visitor A favorite POST should be 201 — got $FAV"
ok "A favorites beach $BID → 201"

A_FAVS=$(curl -s "$GW/rest/v1/favorites?select=beach_id" -H "apikey: $ANON" -H "Authorization: Bearer $ATOK" | jlen)
B_FAVS=$(curl -s "$GW/rest/v1/favorites?select=beach_id" -H "apikey: $ANON" -H "Authorization: Bearer $BTOK" | jlen)
[ "$A_FAVS" -ge 1 ] || fail "visitor A cannot see their own favorite ($A_FAVS)"
[ "$B_FAVS" = "0" ] || fail "LEAK: visitor B sees A's favorites ($B_FAVS) — owner-scoping broken"
ok "A sees own favorites ($A_FAVS) · B sees 0 of A's"

CMT=$(curl -s -X POST "$GW/rest/v1/comments" -H "apikey: $ANON" -H "Authorization: Bearer $ATOK" \
  -H 'Content-Type: application/json' -H 'Prefer: return=representation' \
  -d "{\"beach_id\":$BID,\"content\":\"$MARK comment\"}")
CMT_CODE=$(echo "$CMT" | python3 -c "import sys,json;d=json.load(sys.stdin);print(1 if isinstance(d,list) and d else 0)")
[ "$CMT_CODE" = "1" ] || fail "visitor A comment POST failed (expected 201): $(echo "$CMT" | head -c 200)"
CMT_UID=$(echo "$CMT" | python3 -c "import sys,json;print(json.load(sys.stdin)[0].get('user_id',''))")
CMT_ID=$(echo "$CMT" | python3 -c "import sys,json;print(json.load(sys.stdin)[0].get('id',''))")
[ "$CMT_UID" = "$A_SUB" ] || fail "comment user_id stamp '$CMT_UID' != A's sub '$A_SUB'"
ok "A comments on beach $BID → 201, user_id stamped = A"

B_READS=$(curl -s "$GW/rest/v1/comments?id=eq.$CMT_ID&select=id" -H "apikey: $ANON" -H "Authorization: Bearer $BTOK" | jlen)
[ "$B_READS" -ge 1 ] || fail "visitor B should READ A's published comment ($B_READS)"
B_DEL=$(curl -s -X DELETE "$GW/rest/v1/comments?id=eq.$CMT_ID" -H "apikey: $ANON" -H "Authorization: Bearer $BTOK" \
  -H 'Prefer: return=representation' | jlen)
[ "$B_DEL" = "0" ] || fail "B must NOT delete A's comment (RLS) — got $B_DEL rows"
ok "B reads A's published comment ($B_READS) · B delete → 0 rows (RLS-blocked)"

ADMIN_CMTS=$(curl -s "$GW/rest/v1/comments?select=id" -H "apikey: $ANON" -H "Authorization: Bearer $ADMTOK" | jlen)
[ "$ADMIN_CMTS" -ge 1 ] || fail "admin should read all comments ($ADMIN_CMTS)"
ADMIN_DEL=$(curl -s -X DELETE "$GW/rest/v1/comments?id=eq.$CMT_ID" -H "apikey: $ANON" -H "Authorization: Bearer $ADMTOK" \
  -H 'Prefer: return=representation' | jlen)
[ "$ADMIN_DEL" -ge 1 ] || fail "admin should delete a comment (got $ADMIN_DEL rows)"
ok "admin reads all comments ($ADMIN_CMTS) · admin delete → $ADMIN_DEL row"

# ── (D) privilege escalation closed ──────────────────────────
sect "(D) ESCALATION CLOSED — rol forjado es inerte"
signup "$MARK-attacker@surfind.es" "$VIS_PASS" admin >/dev/null
EVIL=$(login "$MARK-attacker@surfind.es" "$VIS_PASS"); [ -n "$EVIL" ] || fail "attacker login failed"
EROLE=$(printf '%s' "$EVIL" | cut -d. -f2 | python3 -c "
import sys,base64,json;s=sys.stdin.read().strip();s+='='*(-len(s)%4)
print(json.loads(base64.urlsafe_b64decode(s)).get('user_metadata',{}).get('role',''))")
[ "$EROLE" = "admin" ] || fail "attacker should carry forged user_metadata.role=admin (got '$EROLE')"
LID=$(curl -s "$GW/rest/v1/locations?select=id&limit=1" -H "apikey: $ANON" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")
# A blocked write is either a 4xx RLS rejection (42501) or an empty 2xx — both
# mean "no beach created". Assert it is NOT a successful create AND no row landed.
EVIL_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$GW/rest/v1/beaches" -H "apikey: $ANON" -H "Authorization: Bearer $EVIL" \
  -H 'Content-Type: application/json' -H 'Prefer: return=representation' \
  -d "{\"name\":\"$MARK pwn\",\"slug\":\"$MARK-pwn\",\"location_id\":$LID,\"difficulty\":\"beginner\",\"status\":\"published\"}")
[ "$EVIL_CODE" != "201" ] || fail "ESCALATION: forged role created a beach (HTTP 201) — role must come from app_metadata"
EVIL_ROWS=$(docker exec "$PG" psql -U postgres -d postgres -tAc "SELECT count(*) FROM public.beaches WHERE slug='$MARK-pwn';" | tr -d ' ')
[ "${EVIL_ROWS:-0}" = "0" ] || fail "ESCALATION: forged role persisted $EVIL_ROWS beach(es)"
ok "self-signup role=admin → beach write rejected (HTTP $EVIL_CODE, 0 rows persisted) — role trusted from app_metadata"

# ── cleanup gate-created rows ────────────────────────────────
docker exec "$PG" psql -U postgres -d postgres -tAc \
  "DELETE FROM public.favorites WHERE user_id IN ('$A_SUB','$B_SUB'); DELETE FROM public.comments WHERE content='$MARK comment'; DELETE FROM public.beaches WHERE slug='$MARK-pwn';" >/dev/null 2>&1 || true

printf '\n\033[1;32mm160 PASS — Surfind Spain corre en Grobase (data · public read · owner-scoping · escalation cerrada)\033[0m\n'
