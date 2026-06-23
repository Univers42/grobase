#!/usr/bin/env bash
# ============================================================
# m173 — Red Tetris on Grobase (auth + persistence + realtime multiplayer)
#
# Proves the vendor/red-tetris re-platform (42 multiplayer Tetris, whose only
# backend WAS an in-memory Socket.IO server) runs ENTIRELY on Grobase — no game
# server — and that every property holds with NO vacuous pass:
#
#   (A) PROVISION : tenant + PG mount + 8 demo users + world-readable league data
#   (B) AUTH      : GoTrue login for two distinct players (alice, bob)
#   (C) PERSIST   : a posted game updates the player's stats + ELO via the trigger
#   (D) LIVE      : a games insert emits a realtime row_changed (live leaderboard)
#   (E) ISOLATION : games are owner-scoped (app-key cross-owner read = 0 rows)
#                   while the leaderboard/ratings ARE world-readable (shared)
#   (F) MULTIPLAYER: two realtime peers on tetris/room/* — presence fans both
#                    members out AND a BROADCAST from B reaches A (the game loop)
#   (G) CLASSEMENT : league tiers + ratings are readable and the tier is derived
#   (H) SERVICES  : the maximal edition's planes are actually up (realtime, mongo,
#                    redis, functions, analytics, observability)
#
# Requires: a running `tetris` edition + a prior `bash scripts/seed/red-tetris-tenant.sh`.
# Idempotent: gate-posted games are harmless score rows; nothing is deleted.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CFG="$ROOT/vendor/red-tetris/public/baas-config.js"
KPORT="$(docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://' || echo 8000)"
GW="http://localhost:${KPORT:-8000}"
NODE_IMG="node:22-alpine"
PASS="Tetris#2026"

ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
sect() { printf '\n\033[1m%s\033[0m\n' "$*"; }

[ -f "$CFG" ] || fail "no baas-config.js — run: bash scripts/seed/red-tetris-tenant.sh"
cfg() { grep -oE "$1"': *"[^"]*"' "$CFG" | head -1 | sed -E 's/.*"([^"]*)"/\1/'; }
ANON="$(cfg anonKey)"; APIKEY="$(cfg apiKey)"; PGDB="$(cfg pgDbId)"
RT="$(cfg realtimeToken)"; MONGO="$(cfg mongoDbId)"; REDIS="$(cfg redisDbId)"
[ -n "$ANON" ] && [ -n "$PGDB" ] && [ -n "$RT" ] || fail "baas-config.js missing fields"

jpy() { python3 -c "$1"; }
login() {
  curl -s -X POST "$GW/auth/v1/token?grant_type=password" -H "apikey: $ANON" \
    -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"$PASS\"}"
}
q() { # dbId table jsonbody [bearer]  → response
  local hdr=(-H "apikey: $ANON" -H "X-Baas-Api-Key: $APIKEY" -H 'Content-Type: application/json')
  [ -n "${4:-}" ] && hdr+=(-H "Authorization: Bearer $4")
  curl -s -X POST "$GW/query/v1/$1/tables/$2" "${hdr[@]}" -d "$3"
}

# ── (A) PROVISION ────────────────────────────────────────────────────────────
sect "(A) provision — tenant, mount, demo users, league data"
ucount="$(docker exec mini-baas-postgres psql -U postgres -tA -c \
  "select count(*) from auth.users where email like '%@tetris.local';" 2>/dev/null | tr -d ' ')"
[ "${ucount:-0}" -ge 8 ] && ok "demo users seeded ($ucount)" || fail "expected ≥8 demo users, got ${ucount:-0}"
tiers="$(q "$PGDB" league_tiers '{"op":"list","limit":20}' | jpy 'import sys,json;print(len(json.load(sys.stdin).get("rows",[])))')"
[ "${tiers:-0}" -ge 5 ] && ok "league tiers world-readable ($tiers)" || fail "league_tiers not readable ($tiers)"

# ── (B) AUTH ─────────────────────────────────────────────────────────────────
sect "(B) auth — two distinct players"
GA="$(login alice@tetris.local)"; GB="$(login bob@tetris.local)"
TA="$(printf '%s' "$GA" | jpy 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')"
TB="$(printf '%s' "$GB" | jpy 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')"
SA="$(printf '%s' "$GA" | jpy 'import sys,json;print(json.load(sys.stdin).get("user",{}).get("id",""))')"
SB="$(printf '%s' "$GB" | jpy 'import sys,json;print(json.load(sys.stdin).get("user",{}).get("id",""))')"
[ -n "$TA" ] && [ -n "$TB" ] && [ "$SA" != "$SB" ] && ok "alice + bob logged in (distinct subs)" || fail "login failed"

# ── (C) PERSIST + (D) LIVE row_changed ───────────────────────────────────────
sect "(C/D) persist a game → stats/ELO update + live CDC"
before="$(q "$PGDB" player_stats "{\"op\":\"list\",\"filter\":{\"player_id\":\"$SA\"},\"limit\":1}" \
  | jpy 'import sys,json;r=json.load(sys.stdin).get("rows",[]);print(r[0]["total_games"] if r else 0)')"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cdc.mjs" <<'EOF'
const ws=new WebSocket(process.env.WSURL); let got=false;
const to=setTimeout(()=>{console.log(got?'CDC_OK':'CDC_FAIL');process.exit(got?0:1);},9000);
ws.addEventListener('open',()=>ws.send(JSON.stringify({type:'AUTH',token:process.env.TOK})));
ws.addEventListener('message',e=>{let m;try{m=JSON.parse(e.data.toString())}catch{return}
  if(m.type==='AUTH_OK')ws.send(JSON.stringify({type:'SUBSCRIBE',sub_id:'c',topic:process.env.TOPIC}));
  if(m.type==='EVENT'&&m.event&&m.event.event_type==='row_changed'){got=true;clearTimeout(to);console.log('CDC_OK');process.exit(0);}});
EOF
( docker run --rm --network host -e WSURL="ws://127.0.0.1:${KPORT}/realtime/v1/ws" -e TOK="$RT" \
    -e TOPIC="table:${PGDB}:games" -v "$TMP":/t:ro "$NODE_IMG" node /t/cdc.mjs > "$TMP/cdc.out" 2>/dev/null ) &
CDCPID=$!
sleep 2
q "$PGDB" games "{\"op\":\"insert\",\"data\":{\"player_id\":\"$SA\",\"mode\":\"solo\",\"score\":6543,\"lines\":21,\"won\":false}}" "$TA" >/dev/null
wait $CDCPID || true
grep -q CDC_OK "$TMP/cdc.out" && ok "games insert emitted realtime row_changed (live leaderboard)" || fail "no row_changed on games CDC topic"
after="$(q "$PGDB" player_stats "{\"op\":\"list\",\"filter\":{\"player_id\":\"$SA\"},\"limit\":1}" \
  | jpy 'import sys,json;r=json.load(sys.stdin).get("rows",[]);print(r[0]["total_games"] if r else 0)')"
[ "${after:-0}" -gt "${before:-0}" ] && ok "apply_game_result trigger updated stats ($before→$after games)" || fail "stats not updated by trigger"

# ── (E) ISOLATION vs shared ──────────────────────────────────────────────────
sect "(E) isolation — games owner-scoped, leaderboard world-readable"
aliceLeak="$(q "$PGDB" games '{"op":"list","limit":200}' \
  | jpy "import sys,json;rows=json.load(sys.stdin).get('rows',[]);print(sum(1 for r in rows if r.get('owner_id')=='user:$SA'))")"
[ "${aliceLeak:-1}" -eq 0 ] && ok "alice's user-owned games are hidden from the app key (read_scoped)" || fail "alice's games leaked to app key ($aliceLeak rows)"
lb="$(q "$PGDB" games_leaderboard '{"op":"list","limit":50}' | jpy 'import sys,json;print(len(json.load(sys.stdin).get("rows",[])))')"
[ "${lb:-0}" -ge 2 ] && ok "leaderboard is world-readable ($lb players)" || fail "leaderboard not shared ($lb)"

# ── (F) MULTIPLAYER — presence + broadcast across two peers ──────────────────
sect "(F) multiplayer — presence fan-out + broadcast B→A on a room topic"
cat > "$TMP/duo.mjs" <<'EOF'
const url=process.env.WSURL,T=process.env.TOK,topic='tetris/room/m173';
const res={presence:false,broadcast:false};
const a=new WebSocket(url),b=new WebSocket(url);let aReady=false;
const fin=c=>{try{a.close();b.close()}catch{};console.log(JSON.stringify(res));process.exit(c);};
const to=setTimeout(()=>fin(res.presence&&res.broadcast?0:1),9000);
a.addEventListener('open',()=>a.send(JSON.stringify({type:'AUTH',token:T})));
a.addEventListener('message',e=>{let m;try{m=JSON.parse(e.data.toString())}catch{return}
 if(m.type==='AUTH_OK'){a.send(JSON.stringify({type:'SUBSCRIBE',sub_id:'a',topic}));a.send(JSON.stringify({type:'TRACK',topic,meta:{name:'alice'}}));aReady=true;}
 if(m.type==='EVENT'&&m.event){const t=m.event.event_type;
  if(t==='presence'&&((m.event.payload||{}).members||[]).some(x=>x.meta&&x.meta.name==='bob'))res.presence=true;
  if(t==='broadcast'&&(m.event.payload||{}).event==='start')res.broadcast=true;}
 if(res.presence&&res.broadcast){clearTimeout(to);fin(0);}});
b.addEventListener('open',()=>b.send(JSON.stringify({type:'AUTH',token:T})));
b.addEventListener('message',e=>{let m;try{m=JSON.parse(e.data.toString())}catch{return}
 if(m.type==='AUTH_OK'){const go=()=>{b.send(JSON.stringify({type:'TRACK',topic,meta:{name:'bob'}}));setTimeout(()=>b.send(JSON.stringify({type:'BROADCAST',topic,event:'start',payload:{seed:1}})),400);};aReady?go():setTimeout(go,700);}});
EOF
DUO="$(docker run --rm --network host -e WSURL="ws://127.0.0.1:${KPORT}/realtime/v1/ws" -e TOK="$RT" -v "$TMP":/t:ro "$NODE_IMG" node /t/duo.mjs 2>/dev/null | tail -1)"
echo "$DUO" | grep -q '"presence":true' && ok "presence fanned both members out" || fail "presence did not propagate ($DUO)"
echo "$DUO" | grep -q '"broadcast":true' && ok "B's BROADCAST reached A (game events flow)" || fail "broadcast did not reach peer ($DUO)"

# ── (G) CLASSEMENT ───────────────────────────────────────────────────────────
sect "(G) classement — ratings readable, tier derived"
rk="$(q "$PGDB" ratings '{"op":"list","sort":{"rating":"desc"},"limit":50}')"
top="$(printf '%s' "$rk" | jpy 'import sys,json;r=json.load(sys.stdin).get("rows",[]);print(r[0]["league_tier"] if r else "")')"
n="$(printf '%s' "$rk" | jpy 'import sys,json;print(len(json.load(sys.stdin).get("rows",[])))')"
[ "${n:-0}" -ge 2 ] && [ -n "$top" ] && ok "live classement derivable ($n rated; top tier=$top)" || fail "ratings/classement not readable"

# ── (H) SERVICES — maximal edition planes ────────────────────────────────────
sect "(H) maximal services up"
for svc in realtime mongo redis function-scheduler analytics-service grafana; do
  st="$(docker inspect "mini-baas-$svc" --format '{{.State.Status}}' 2>/dev/null || echo missing)"
  [ "$st" = running ] && ok "$svc: $st" || fail "$svc not running ($st)"
done

printf '\n\033[1;32m✅ m173 PASS — red-tetris is fully Grobase-backed: auth + owner-scoped\n   persistence + live leaderboard CDC + realtime multiplayer (presence+broadcast)\n   + live classement, on the maximal services edition.\033[0m\n'
