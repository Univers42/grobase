#!/usr/bin/env bash
# ============================================================
# m161 — Surfind Spain DEEP expansion on Grobase
#
# Proves the deep surf-TRACKING layer on top of the vendor/surfind-spain
# re-platform works on the live stack — beach intel, articles/guides,
# live surf reports, beach ratings (trigger-recomputed) and a private
# MongoDB bitácora — each with its security property held. No vacuous passes:
#
#   (A) BEACH INTEL : beaches carry break_type/wave_quality/cover_image (not
#                     null on the seeded ones) and beaches count >= 28
#   (B) ARTICLES    : >= 20 published articles readable by anon, incl. at least
#                     one per-beach 'guia-*' guide
#   (C) SURF REPORTS: a logged-in visitor A POSTs a report (201, user_id stamped);
#                     anon READs it (public live feed); visitor B cannot DELETE A's
#   (D) RATINGS     : A rates a beach 5★ → the trigger recomputes
#                     beaches.rating_avg/rating_count for that beach (asserted via psql)
#   (E) MONGO       : the Bitácora — A inserts a session via the mongo mount, lists
#                     it (>=1), visitor B lists → 0 (owner isolation per GoTrue user)
#
# Requires a running stack + `bash vendor/surfind-spain/infra/init.sh` (deep
# schema, RLS, GoTrue users) + `bash scripts/seed/surfind-tenant.sh` (mongo mount).
# Idempotent: gate-created rows/docs are cleaned up at the end.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PG="${PG_CONTAINER:-mini-baas-postgres}"
ANON="$(grep -E '^ANON_KEY=' "$ROOT/.env" | cut -d= -f2)"
KPORT="$(docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://' || echo 8000)"
GW="http://localhost:${KPORT:-8000}"

# mongo mount coordinates (from the surfind tenant provisioning)
MONGO_DBID=""; APP_KEY=""
[ -f "$ROOT/.surfind-tenant.env" ] && { . "$ROOT/.surfind-tenant.env"; MONGO_DBID="$SURFIND_MONGO_DB_ID"; APP_KEY="$SURFIND_API_KEY"; }

A_EMAIL="deep-a@surfind.es"
B_EMAIL="deep-b@surfind.es"
VIS_PASS="surf-1234"
MARK="m161-deep"

ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
sect() { printf '\n\033[1m%s\033[0m\n' "$*"; }

jget() { python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('$1','') if isinstance(d,dict) else '')"; }
jlen() { python3 -c "import sys,json;d=json.load(sys.stdin);print(len(d) if isinstance(d,list) else -1)"; }

login() { # email password -> access_token
  curl -s -X POST "$GW/auth/v1/token?grant_type=password" -H "apikey: $ANON" \
    -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"$2\"}" | jget access_token
}
signup() { # email password -> http code (200 new / 422 exists)
  curl -s -o /dev/null -w '%{http_code}' -X POST "$GW/auth/v1/signup" -H "apikey: $ANON" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$1\",\"password\":\"$2\",\"data\":{\"full_name\":\"$1\",\"role\":\"user\"}}"
}
sub_of() { printf '%s' "$1" | cut -d. -f2 | python3 -c "import sys,base64,json;s=sys.stdin.read().strip();s+='='*(-len(s)%4);print(json.loads(base64.urlsafe_b64decode(s)).get('sub',''))"; }

printf '\n\033[1mm161 — Surfind Spain DEEP · intel, guías, partes en vivo, ratings, bitácora\033[0m  (%s)\n' "$GW"

# ── (A) beach intel ──────────────────────────────────────────
sect "(A) BEACH INTEL — break_type/wave_quality/cover_image poblados"
B=$(docker exec "$PG" psql -U postgres -d postgres -tAc "SELECT count(*) FROM public.beaches;" | tr -d ' ')
[ "$B" -ge 28 ] || fail "expected >= 28 beaches (got $B)"
INTEL=$(docker exec "$PG" psql -U postgres -d postgres -tAc \
  "SELECT count(*) FROM public.beaches WHERE break_type IS NOT NULL AND wave_quality IS NOT NULL AND cover_image IS NOT NULL;" | tr -d ' ')
[ "${INTEL:-0}" -ge 1 ] || fail "no beach carries break_type+wave_quality+cover_image (intel not seeded)"
ok "beaches=$B · with break_type+wave_quality+cover_image=$INTEL"

# anon reads the enriched intel columns over PostgREST
PI=$(curl -s "$GW/rest/v1/beaches?select=id,break_type,wave_quality,cover_image&break_type=not.is.null&limit=50" -H "apikey: $ANON" | jlen)
[ "$PI" -ge 1 ] || fail "anon must read enriched beach intel over PostgREST (got $PI)"
ok "anon reads enriched beach intel ($PI beaches with break_type)"

# ── (B) articles / guides ────────────────────────────────────
sect "(B) ARTÍCULOS — >=20 publicados, incl. guías por playa"
ART=$(curl -s "$GW/rest/v1/articles?published=eq.true&select=id,slug" -H "apikey: $ANON" | jlen)
[ "$ART" -ge 20 ] || fail "anon must read >= 20 published articles (got $ART)"
GUIA=$(curl -s "$GW/rest/v1/articles?published=eq.true&slug=like.guia-*&select=slug" -H "apikey: $ANON" | jlen)
[ "$GUIA" -ge 1 ] || fail "expected >= 1 per-beach 'guia-*' guide (got $GUIA)"
ok "anon articles=$ART · guías por playa (guia-*)=$GUIA"

# ── (C) auth + surf reports ──────────────────────────────────
sect "(C) PARTES EN VIVO — feed público, autoría protegida"
sa=$(signup "$A_EMAIL" "$VIS_PASS"); [ "$sa" = "200" ] || [ "$sa" = "422" ] || fail "visitor A signup → $sa"
sb=$(signup "$B_EMAIL" "$VIS_PASS"); [ "$sb" = "200" ] || [ "$sb" = "422" ] || fail "visitor B signup → $sb"
ok "self-signup A=$sa · B=$sb"
ATOK=$(login "$A_EMAIL" "$VIS_PASS"); [ -n "$ATOK" ] || fail "visitor A login failed"
BTOK=$(login "$B_EMAIL" "$VIS_PASS"); [ -n "$BTOK" ] || fail "visitor B login failed"
A_SUB=$(sub_of "$ATOK"); B_SUB=$(sub_of "$BTOK")
ok "login → tokens issued (A · B)"

docker exec "$PG" psql -U postgres -d postgres -tAc \
  "DELETE FROM public.surf_reports WHERE comment='$MARK report'; DELETE FROM public.beach_ratings WHERE user_id IN ('$A_SUB','$B_SUB');" >/dev/null 2>&1 || true

BID=$(curl -s "$GW/rest/v1/beaches?select=id&limit=1" -H "apikey: $ANON" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")
[ -n "$BID" ] || fail "no beach id to report on"

RPT=$(curl -s -X POST "$GW/rest/v1/surf_reports" -H "apikey: $ANON" -H "Authorization: Bearer $ATOK" \
  -H 'Content-Type: application/json' -H 'Prefer: return=representation' \
  -d "{\"beach_id\":$BID,\"author_name\":\"$A_EMAIL\",\"wave_height_m\":1.8,\"period_s\":11,\"wind\":\"offshore\",\"crowd\":\"medio\",\"quality\":4,\"comment\":\"$MARK report\"}")
RPT_OK=$(echo "$RPT" | python3 -c "import sys,json;d=json.load(sys.stdin);print(1 if isinstance(d,list) and d else 0)")
[ "$RPT_OK" = "1" ] || fail "visitor A surf_report POST failed (expected 201): $(echo "$RPT" | head -c 200)"
RPT_UID=$(echo "$RPT" | python3 -c "import sys,json;print(json.load(sys.stdin)[0].get('user_id',''))")
RPT_ID=$(echo "$RPT" | python3 -c "import sys,json;print(json.load(sys.stdin)[0].get('id',''))")
[ "$RPT_UID" = "$A_SUB" ] || fail "surf_report user_id stamp '$RPT_UID' != A's sub '$A_SUB'"
ok "A posts surf_report on beach $BID → 201, user_id stamped = A"

ANON_READS=$(curl -s "$GW/rest/v1/surf_reports?id=eq.$RPT_ID&select=id" -H "apikey: $ANON" | jlen)
[ "$ANON_READS" -ge 1 ] || fail "anon must READ A's surf_report (public live feed) — got $ANON_READS"
ok "anon reads A's surf_report ($ANON_READS) — public live feed"

B_DEL=$(curl -s -X DELETE "$GW/rest/v1/surf_reports?id=eq.$RPT_ID" -H "apikey: $ANON" -H "Authorization: Bearer $BTOK" \
  -H 'Prefer: return=representation' | jlen)
[ "$B_DEL" = "0" ] || fail "B must NOT delete A's surf_report (RLS) — got $B_DEL rows"
ok "B delete of A's report → 0 rows (RLS-blocked, autoría protegida)"

# ── (D) beach ratings (trigger recompute) ────────────────────
sect "(D) RATINGS — A vota 5★, el trigger recalcula rating_avg/count"
RATE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$GW/rest/v1/beach_ratings" -H "apikey: $ANON" \
  -H "Authorization: Bearer $ATOK" -H 'Content-Type: application/json' -H 'Prefer: return=minimal' \
  -d "{\"beach_id\":$BID,\"stars\":5}")
[ "$RATE" = "201" ] || fail "visitor A rating POST should be 201 — got $RATE"
AVG=$(docker exec "$PG" psql -U postgres -d postgres -tAc \
  "SELECT rating_avg FROM public.beaches WHERE id=$BID;" | tr -d ' ')
CNT=$(docker exec "$PG" psql -U postgres -d postgres -tAc \
  "SELECT rating_count FROM public.beaches WHERE id=$BID;" | tr -d ' ')
[ "${CNT:-0}" -ge 1 ] || fail "trigger did not bump beaches.rating_count for beach $BID (got '$CNT')"
echo "$AVG" | python3 -c "import sys;v=float(sys.stdin.read().strip() or 0);sys.exit(0 if v>0 else 1)" \
  || fail "trigger did not set beaches.rating_avg (>0) for beach $BID (got '$AVG')"
ok "A rates beach $BID 5★ → trigger recomputed rating_avg=$AVG rating_count=$CNT"

# ── (E) MongoDB bitácora (owner-scoped) ──────────────────────
sect "(E) BITÁCORA — surf_sessions privadas por surfista (Mongo owner-scoped)"
if [ -z "$MONGO_DBID" ] || [ -z "$APP_KEY" ]; then
  fail "mongo mount not provisioned — run scripts/seed/surfind-tenant.sh first"
fi
mq() { # body bearer -> raw json
  curl -s -X POST "$GW/query/v1/$MONGO_DBID/tables/surf_sessions" \
    -H "apikey: $ANON" -H "X-Baas-Api-Key: $APP_KEY" -H "Authorization: Bearer $2" \
    -H 'Content-Type: application/json' -d "$1"
}
INS=$(mq "{\"op\":\"insert\",\"data\":{\"beach_name\":\"$MARK Mundaka\",\"date\":\"2026-06-15\",\"duration_min\":80,\"waves\":\"huecas\",\"board\":\"5'10\",\"swell_m\":2.0,\"wind\":\"offshore\",\"water_temp_c\":\"18\",\"rating\":5,\"tags\":[\"gate\"],\"notes\":\"gate session\",\"mark\":\"$MARK\"}}" "$ATOK")
echo "$INS" | python3 -c "import sys,json;d=json.load(sys.stdin);sys.exit(0 if d.get('rowCount',len(d.get('rows',[])))>=1 else 1)" \
  || fail "mongo insert (query-router) failed: $(echo "$INS" | head -c 200)"
ok "query-router insert into MongoDB surf_sessions mount → ok"
A_DOCS=$(mq '{"op":"list","limit":100}' "$ATOK" | python3 -c "import sys,json;d=json.load(sys.stdin);print(sum(1 for r in d.get('rows',[]) if r.get('mark')=='$MARK'))")
[ "$A_DOCS" -ge 1 ] || fail "visitor A cannot read back their own bitácora doc ($A_DOCS)"
B_DOCS=$(mq '{"op":"list","limit":100}' "$BTOK" | python3 -c "import sys,json;d=json.load(sys.stdin);print(sum(1 for r in d.get('rows',[]) if r.get('mark')=='$MARK'))")
[ "$B_DOCS" = "0" ] || fail "LEAK: visitor B can read A's bitácora docs ($B_DOCS) — owner-scoping broken"
ok "A reads own bitácora ($A_DOCS) · B sees 0 of A's (Mongo owner-scoped per user)"

# ── cleanup gate-created rows/docs ───────────────────────────
mq "{\"op\":\"delete\",\"filter\":{\"mark\":{\"\$eq\":\"$MARK\"}}}" "$ATOK" >/dev/null 2>&1 || true
docker exec "$PG" psql -U postgres -d postgres -tAc \
  "DELETE FROM public.surf_reports WHERE comment='$MARK report'; DELETE FROM public.beach_ratings WHERE user_id IN ('$A_SUB','$B_SUB');" >/dev/null 2>&1 || true

printf '\n\033[1;32mm161 PASS — Surfind Spain DEEP en Grobase (intel · guías · partes en vivo · ratings · bitácora)\033[0m\n'
