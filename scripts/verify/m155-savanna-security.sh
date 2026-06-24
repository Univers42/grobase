#!/usr/bin/env bash
# ============================================================
# m155 — Savanna Zoo: every Grobase service works, securely
#
# A whole-stack security gate for the vendor/savanna-zoo re-platform. It
# exercises each Grobase service the app depends on and proves the security
# property each one is responsible for — no vacuous passes:
#
#   (A) KONG      gateway auth + routing: no apikey → 401, unknown route → 404,
#                 valid apikey → 200 (the front door actually gates)
#   (B) GOTRUE    visitor self-signup, login, wrong-password → 400, /user echo,
#                 JWT carries role=visitor, logout
#   (C) RLS       per-user owner-scoping on tickets: visitor A sees ONLY their
#                 own booking, visitor B sees 0 of A's (the cross-user leak
#                 check), admin sees all, anon sees 0, zookeeper staff-write
#                 is RLS-blocked
#   (D) TRIGGERS  A's booking auto-mints a ZOO-YYYYMMDD QR + bumps visitor_stats
#                 (SECURITY DEFINER, so a non-admin booking succeeds)
#   (E) REALTIME  WS subscribe pg/animals/updated, admin write → live EVENT with
#                 the full row
#   (F) STORAGE   /storage/v1 routes via Kong + demands a verified identity:
#                 no Bearer → 401, admin Bearer → 200
#   (G) MONGO     the Visit Journal: query-router insert/list on the mongo mount,
#                 owner-scoped per GoTrue user (B cannot read A's documents)
#
# Requires: a running stack + `bash vendor/savanna-zoo/infra/init.sh` (postgres,
# RLS, 004 owner-scoping, GoTrue users) + `bash scripts/seed/savanna-tenant.sh`
# (mongo mount). Idempotent: gate-created rows/docs are cleaned up at the end.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PG="${PG_CONTAINER:-mini-baas-postgres}"
ANON="$(grep -E '^ANON_KEY=' "$ROOT/.env" | cut -d= -f2)"
KPORT="$(docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://' || echo 8000)"
GW="http://localhost:${KPORT:-8000}"
PASS="${ZOO_PASSWORD:-zoo-admin-2024}"
NET="$(docker inspect mini-baas-kong --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null | head -1)"

# mongo mount coordinates (from the savanna tenant provisioning)
MONGO_DBID=""; APP_KEY=""
[ -f "$ROOT/.savanna-tenant.env" ] && { . "$ROOT/.savanna-tenant.env"; MONGO_DBID="$SAVANNA_MONGO_DB_ID"; APP_KEY="$SAVANNA_API_KEY"; }

A_EMAIL="sec-alice@savanna-zoo.com"
B_EMAIL="sec-bob@savanna-zoo.com"
SEC_PASS="Visitor#2026"
MARK="m155-sec"

ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
sect() { printf '\n\033[1m%s\033[0m\n' "$*"; }

jget() { python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('$1',''))"; }
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

printf '\n\033[1mm155 — Savanna Zoo · all Grobase services, securely\033[0m  (%s)\n' "$GW"

# ── (A) Kong gateway ─────────────────────────────────────────
sect "(A) Kong — gateway auth + routing"
C_NOKEY=$(curl -s -o /dev/null -w '%{http_code}' "$GW/rest/v1/animals?limit=1")
[ "$C_NOKEY" = "401" ] || fail "no-apikey request should be 401 (Kong key-auth) — got $C_NOKEY"
ok "no apikey → 401 (key-auth enforced at the gateway)"
C_404=$(curl -s -o /dev/null -w '%{http_code}' "$GW/this-route-does-not-exist" -H "apikey: $ANON")
[ "$C_404" = "404" ] || fail "unknown route should be 404 — got $C_404"
ok "unknown route → 404"
C_OK=$(curl -s -o /dev/null -w '%{http_code}' "$GW/rest/v1/animals?limit=1" -H "apikey: $ANON")
[ "$C_OK" = "200" ] || fail "valid apikey → expected 200, got $C_OK"
ok "valid apikey → 200 (routes to PostgREST)"

# ── (B) GoTrue ───────────────────────────────────────────────
sect "(B) GoTrue — auth lifecycle"
sc=$(signup "$A_EMAIL" "$SEC_PASS" visitor); [ "$sc" = "200" ] || [ "$sc" = "422" ] || fail "visitor signup A → $sc"
signup "$B_EMAIL" "$SEC_PASS" visitor >/dev/null
ok "visitor self-signup ($A_EMAIL) → $sc"
ATOK=$(login "$A_EMAIL" "$SEC_PASS"); [ -n "$ATOK" ] || fail "visitor A login failed"
BTOK=$(login "$B_EMAIL" "$SEC_PASS"); [ -n "$BTOK" ] || fail "visitor B login failed"
ok "login → access_token issued"
C_BAD=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$GW/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON" -H 'Content-Type: application/json' -d "{\"email\":\"$A_EMAIL\",\"password\":\"wrong-pw\"}")
[ "$C_BAD" = "400" ] || fail "wrong password should be 400 — got $C_BAD"
ok "wrong password → 400"
WHO=$(curl -s "$GW/auth/v1/user" -H "apikey: $ANON" -H "Authorization: Bearer $ATOK" | jget email)
[ "$WHO" = "$A_EMAIL" ] || fail "/auth/v1/user echoed '$WHO' (expected $A_EMAIL)"
ok "/auth/v1/user echoes the signed-in identity"
ROLE=$(printf '%s' "$ATOK" | cut -d. -f2 | python3 -c "
import sys,base64,json
s=sys.stdin.read().strip(); s+='='*(-len(s)%4)
print(json.loads(base64.urlsafe_b64decode(s)).get('user_metadata',{}).get('role',''))")
[ "$ROLE" = "visitor" ] || fail "JWT user_metadata.role expected 'visitor', got '$ROLE'"
ok "JWT carries user_metadata.role=visitor (UI only; the RLS bypass reads app_metadata)"
C_OUT=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$GW/auth/v1/logout" -H "apikey: $ANON" -H "Authorization: Bearer $ATOK")
[ "$C_OUT" = "204" ] || [ "$C_OUT" = "200" ] || fail "logout → $C_OUT"
ok "logout → $C_OUT"
ATOK=$(login "$A_EMAIL" "$SEC_PASS")  # fresh token after logout

# ── (C) RLS owner-scoping (PostgREST) ────────────────────────
sect "(C) RLS — per-user ticket isolation"
SOPHIE=$(login sophie.laurent@savanna-zoo.com "$PASS"); [ -n "$SOPHIE" ] || fail "admin login failed"
MARCUS=$(login marcus.osei@savanna-zoo.com "$PASS"); [ -n "$MARCUS" ] || fail "zookeeper login failed"
# Clean slate: drop any tickets the test visitors already own (prior runs / a
# concurrent pentest), so "B sees 0 before A books" is a true isolation check.
sub_of() { printf '%s' "$1" | cut -d. -f2 | python3 -c "import sys,base64,json;s=sys.stdin.read().strip();s+='='*(-len(s)%4);print(json.loads(base64.urlsafe_b64decode(s)).get('sub',''))"; }
A_SUB=$(sub_of "$ATOK"); B_SUB=$(sub_of "$BTOK")
docker exec "$PG" psql -U postgres -d postgres -tAc \
  "DELETE FROM public.tickets WHERE user_id IN ('$A_SUB','$B_SUB') OR visitor_name='$MARK';" >/dev/null 2>&1 || true
AN=$(curl -s "$GW/rest/v1/animals?select=id" -H "apikey: $ANON" | jlen)
[ "$AN" -ge 12 ] || fail "anon should read public animals (got $AN)"
TZ=$(curl -s "$GW/rest/v1/tickets?select=id" -H "apikey: $ANON" | jlen)
[ "$TZ" = "0" ] || fail "anon must NOT read tickets — got $TZ"
ok "anon: animals=$AN (public), tickets=$TZ (private)"

TTID=$(curl -s "$GW/rest/v1/ticket_types?select=id&limit=1" -H "apikey: $ANON" | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")
BOOK=$(curl -s -X POST "$GW/rest/v1/tickets" -H "apikey: $ANON" -H "Authorization: Bearer $ATOK" \
  -H 'Content-Type: application/json' -H 'Prefer: return=representation' \
  -d "{\"ticket_type_id\":\"$TTID\",\"visitor_name\":\"$MARK\",\"visitor_email\":\"$A_EMAIL\",\"visit_date\":\"2026-12-24\",\"quantity\":2,\"total_eur\":\"49.80\",\"status\":\"valid\"}")
QR=$(echo "$BOOK" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d[0].get('qr_code','') if isinstance(d,list) and d else '')")
[ -n "$QR" ] || fail "visitor A booking failed (the 42501 regression): $(echo "$BOOK" | head -c 200)"
ok "visitor A books a ticket → 201 (no 42501), qr=$QR"

A_SEES=$(curl -s "$GW/rest/v1/tickets?select=id" -H "apikey: $ANON" -H "Authorization: Bearer $ATOK" | jlen)
B_SEES=$(curl -s "$GW/rest/v1/tickets?select=id" -H "apikey: $ANON" -H "Authorization: Bearer $BTOK" | jlen)
ADMIN_SEES=$(curl -s "$GW/rest/v1/tickets?select=id" -H "apikey: $ANON" -H "Authorization: Bearer $SOPHIE" | jlen)
[ "$A_SEES" -ge 1 ] || fail "visitor A cannot see their own ticket ($A_SEES)"
[ "$B_SEES" = "0" ] || fail "LEAK: visitor B can see tickets ($B_SEES) — owner-scoping broken"
[ "$ADMIN_SEES" -gt "$A_SEES" ] || fail "admin should see all tickets ($ADMIN_SEES vs A=$A_SEES)"
ok "A sees own ($A_SEES) · B sees 0 of A's · admin sees all ($ADMIN_SEES)"

SID=$(curl -s "$GW/rest/v1/staff?select=id&limit=1" -H "apikey: $ANON" -H "Authorization: Bearer $MARCUS" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")
DENIED=$(curl -s -X PATCH "$GW/rest/v1/staff?id=eq.$SID" -H "apikey: $ANON" -H "Authorization: Bearer $MARCUS" \
  -H 'Content-Type: application/json' -H 'Prefer: return=representation' -d '{"phone":"HACKED"}' | jlen)
[ "$DENIED" = "0" ] || fail "zookeeper staff-write should be RLS-blocked (0 rows) — got $DENIED"
ok "zookeeper staff-write → 0 rows (RLS-blocked)"

# ── (C2) Privilege escalation closed ─────────────────────────
sect "(C2) Auth hardening — forged role is inert"
signup "attacker@evil.com" "Pwn#2026" admin >/dev/null
EVIL=$(login "attacker@evil.com" "Pwn#2026"); [ -n "$EVIL" ] || fail "attacker login failed"
EROLE=$(printf '%s' "$EVIL" | cut -d. -f2 | python3 -c "
import sys,base64,json;s=sys.stdin.read().strip();s+='='*(-len(s)%4)
print(json.loads(base64.urlsafe_b64decode(s)).get('user_metadata',{}).get('role',''))")
[ "$EROLE" = "admin" ] || fail "attacker should carry the forged user_metadata.role=admin (got '$EROLE')"
EVIL_TIX=$(curl -s "$GW/rest/v1/tickets?select=id" -H "apikey: $ANON" -H "Authorization: Bearer $EVIL" | jlen)
[ "$EVIL_TIX" = "0" ] || fail "ESCALATION: forged role read $EVIL_TIX tickets — role must come from app_metadata"
SID0=$(curl -s "$GW/rest/v1/staff?select=id&limit=1" -H "apikey: $ANON" -H "Authorization: Bearer $SOPHIE" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")
EVIL_W=$(curl -s -X PATCH "$GW/rest/v1/staff?id=eq.$SID0" -H "apikey: $ANON" -H "Authorization: Bearer $EVIL" \
  -H 'Content-Type: application/json' -H 'Prefer: return=representation' -d '{"phone":"PWNED"}' | jlen)
[ "$EVIL_W" = "0" ] || fail "ESCALATION: forged role wrote $EVIL_W staff rows"
ok "self-signup role=admin (user_metadata) → 0 tickets, 0 staff writes (role trusted from app_metadata)"

# ── (D) Triggers ─────────────────────────────────────────────
sect "(D) Triggers — QR + visitor_stats (SECURITY DEFINER)"
echo "$QR" | grep -qE '^ZOO-20261224-' || fail "QR trigger did not fire (qr=$QR)"
VS=$(docker exec "$PG" psql -U postgres -d postgres -tAc \
  "SELECT total_visitors FROM public.visitor_stats WHERE stat_date='2026-12-24';" | tr -d ' ')
[ "${VS:-0}" -ge 2 ] || fail "visitor_stats trigger did not aggregate a visitor booking (got '$VS')"
ok "QR=$QR · visitor_stats(2026-12-24)=$VS (aggregated under a visitor, not admin)"

# ── (E) Realtime ─────────────────────────────────────────────
sect "(E) Realtime — live WS event on a write"
AID=$(curl -s "$GW/rest/v1/animals?select=id,total_feedings&limit=1" -H "apikey: $ANON" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")
RT=$(docker run --rm --network "$NET" -e TOK="$SOPHIE" -e KEY="$ANON" -e AID="$AID" node:22-alpine node -e '
const tok=process.env.TOK,key=process.env.KEY,aid=process.env.AID;
const url=`ws://kong:8000/realtime/v1/ws?apikey=${encodeURIComponent(key)}&access_token=${encodeURIComponent(tok)}`;
const ws=new WebSocket(url); let got=false;
const t=setTimeout(()=>{console.log("TIMEOUT");process.exit(1)},12000);
ws.onopen=()=>ws.send(JSON.stringify({type:"AUTH",token:tok}));
ws.onmessage=async(e)=>{const m=JSON.parse(e.data);
  if(m.type==="AUTH_OK")ws.send(JSON.stringify({type:"SUBSCRIBE",sub_id:"s",topic:"pg/animals/updated"}));
  if(m.type==="SUBSCRIBED"){
    await fetch(`http://kong:8000/rest/v1/animals?id=eq.${aid}`,{method:"PATCH",
      headers:{apikey:key,Authorization:`Bearer ${tok}`,"Content-Type":"application/json","Prefer":"return=minimal"},
      body:JSON.stringify({total_feedings: Math.floor(Date.now()/1000)%100000})});
  }
  if((m.type==="EVENT"||m.type==="ROW_CHANGED")&&!got){
    const row=m.event?.payload?.data??m.event?.payload??m.payload??{};
    if(row.id===aid){got=true;clearTimeout(t);console.log("EVENT_OK");process.exit(0);}
  }
};
ws.onerror=()=>{console.log("WS_ERR");process.exit(1)};' 2>&1 | tail -1)
[ "$RT" = "EVENT_OK" ] || fail "no realtime EVENT for the animal write (got '$RT'); is mini-baas-realtime alive?"
ok "WS subscribe + admin write → live EVENT with the full row (public table)"

# ── (E2) Realtime PII leak closed — a visitor must NOT receive ticket broadcasts ──
LEAK=$(docker run --rm --network "$NET" -e BOB="$BTOK" -e SOPHIE="$SOPHIE" -e KEY="$ANON" -e TTID="$TTID" node:22-alpine node -e '
const bob=process.env.BOB,sophie=process.env.SOPHIE,key=process.env.KEY,ttid=process.env.TTID;
const ws=new WebSocket(`ws://kong:8000/realtime/v1/ws?apikey=${encodeURIComponent(key)}&access_token=${encodeURIComponent(bob)}`);
let leaked=false; const t=setTimeout(()=>{console.log(leaked?"LEAK":"CLOSED");process.exit(0)},7000);
ws.onopen=()=>ws.send(JSON.stringify({type:"AUTH",token:bob}));
ws.onmessage=async(e)=>{const m=JSON.parse(e.data);
  if(m.type==="AUTH_OK")ws.send(JSON.stringify({type:"SUBSCRIBE",sub_id:"t",topic:"pg/tickets/inserted"}));
  if(m.type==="SUBSCRIBED")await fetch("http://kong:8000/rest/v1/tickets",{method:"POST",headers:{apikey:key,Authorization:`Bearer ${sophie}`,"Content-Type":"application/json","Prefer":"return=minimal"},
    body:JSON.stringify({ticket_type_id:ttid,visitor_name:"m155-leakcheck",visitor_email:"leak@secret.example",visit_date:"2026-12-24",quantity:1,total_eur:"24.90",status:"valid"})});
  if(m.type==="EVENT"){const r=m.event?.payload?.data??{};if(r.visitor_email)leaked=true;}
};
ws.onerror=()=>{};' 2>&1 | tail -1)
[ "$LEAK" = "CLOSED" ] || fail "REALTIME PII LEAK: a visitor received another user's ticket over WS (got '$LEAK')"
ok "visitor subscribed to pg/tickets/inserted receives NOTHING (PII not broadcast)"
docker exec "$PG" psql -U postgres -d postgres -tAc "DELETE FROM public.tickets WHERE visitor_name='m155-leakcheck';" >/dev/null 2>&1 || true

# ── (F) Storage ──────────────────────────────────────────────
sect "(F) Storage — routed + identity-gated"
S_NO=$(curl -s -o /dev/null -w '%{http_code}' "$GW/storage/v1/bucket" -H "apikey: $ANON")
[ "$S_NO" = "401" ] || fail "storage without a verified identity should be 401 — got $S_NO"
S_OK=$(curl -s -o /dev/null -w '%{http_code}' "$GW/storage/v1/bucket" -H "apikey: $ANON" -H "Authorization: Bearer $SOPHIE")
[ "$S_OK" = "200" ] || fail "storage with admin identity should be 200 — got $S_OK"
ok "no Bearer → 401 · admin Bearer → 200 (storage-router live behind Kong)"

# ── (G) MongoDB (Visit Journal via query-router) ─────────────
sect "(G) MongoDB — owner-scoped Visit Journal"
if [ -z "$MONGO_DBID" ] || [ -z "$APP_KEY" ]; then
  fail "mongo mount not provisioned — run scripts/seed/savanna-tenant.sh first"
fi
mq() { # body bearer -> raw json
  curl -s -X POST "$GW/query/v1/$MONGO_DBID/tables/observations" \
    -H "apikey: $ANON" -H "X-Baas-Api-Key: $APP_KEY" -H "Authorization: Bearer $2" \
    -H 'Content-Type: application/json' -d "$1"
}
INS=$(mq "{\"op\":\"insert\",\"data\":{\"animal\":\"$MARK lion\",\"zone\":\"savannah\",\"note\":\"gate doc\",\"rating\":5,\"tags\":[\"gate\"],\"mark\":\"$MARK\"}}" "$ATOK")
echo "$INS" | python3 -c "import sys,json;d=json.load(sys.stdin);sys.exit(0 if d.get('rowCount',len(d.get('rows',[])))>=1 else 1)" \
  || fail "mongo insert (query-router) failed: $(echo "$INS" | head -c 200)"
ok "query-router insert into MongoDB mount → ok"
A_DOCS=$(mq '{"op":"list","limit":100}' "$ATOK" | python3 -c "import sys,json;d=json.load(sys.stdin);print(sum(1 for r in d.get('rows',[]) if r.get('mark')=='$MARK'))")
[ "$A_DOCS" -ge 1 ] || fail "visitor A cannot read back their own journal doc ($A_DOCS)"
B_DOCS=$(mq '{"op":"list","limit":100}' "$BTOK" | python3 -c "import sys,json;d=json.load(sys.stdin);print(sum(1 for r in d.get('rows',[]) if r.get('mark')=='$MARK'))")
[ "$B_DOCS" = "0" ] || fail "LEAK: visitor B can read A's MongoDB journal docs ($B_DOCS) — owner-scoping broken"
ok "A reads own journal ($A_DOCS) · B sees 0 of A's (Mongo owner-scoped per user)"
mq "{\"op\":\"delete\",\"filter\":{\"mark\":{\"\$eq\":\"$MARK\"}}}" "$ATOK" >/dev/null 2>&1 || true

# ── cleanup gate-created rows ────────────────────────────────
docker exec "$PG" psql -U postgres -d postgres -tAc \
  "DELETE FROM public.tickets WHERE visitor_name='$MARK'; DELETE FROM public.visitor_stats WHERE stat_date='2026-12-24';" >/dev/null 2>&1 || true

printf '\n\033[1;32mm155 PASS — Kong · GoTrue · RLS · triggers · realtime · storage · MongoDB all green\033[0m\n'
