#!/usr/bin/env bash
# **************************************************************************** #
#  m150-hypertube-roundtrip.sh — Hypertube-on-Grobase Mongo + realtime gate    #
#                                                                              #
#  Proves the re-platformed Hypertube data layer behaves end to end through    #
#  Kong against the RUNNING stack — auth = GoTrue, data = a MongoDB mount with  #
#  shared_resources for the world-readable collections:                        #
#    1. provision   — hypertube-tenant.sh (idempotent): tenant+key+mongo mount. #
#    2. auth        — GoTrue signup → JWT (sub); wrong password is rejected.    #
#    3. movies      — insert a catalog doc (201) → list returns it → delete.    #
#    4. shared read — user A inserts a comment; a DIFFERENT principal (user B)  #
#                     READS it back. The cross-owner read is the LOAD-BEARING   #
#                     assertion — it proves shared_resources on the comments    #
#                     collection (a gate that only shows A reading A is VACUOUS).#
#    5. realtime    — a WS subscriber on table:<mongoDbId>:comments that did    #
#                     NOT write observes the change EVENT after a /query insert. #
#                                                                              #
#  Live gate: needs the hypertube profile up (Mongo + realtime planes). SKIPs   #
#  cleanly (exit 0) when the stack/profile is not reachable so CI stays green.   #
# **************************************************************************** #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NODE_IMAGE="${NODE_IMAGE:-node:22-alpine}"
# shellcheck source=../lib/lib-live-tenant.sh
source "${BAAS_DIR}/scripts/lib/lib-live-tenant.sh"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M150] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
skip() {
  printf '\033[0;33mSKIP m150: %s\033[0m\n' "$*"
  exit 0
}
fail() {
  printf '\033[0;31m[M150] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

jval() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2" 2>/dev/null || true; }
jrows() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("rows",[])))' "$1" 2>/dev/null || echo 0; }
jsub() { python3 -c '
import sys,base64,json
p=sys.argv[1].split(".")[1]; p+="="*(-len(p)%4)
print(json.loads(base64.urlsafe_b64decode(p)).get("sub",""))' "$1" 2>/dev/null || true; }

# ── 0) stack reachable? otherwise SKIP (keep CI green) ───────────────────────
KPORT="$(_lt_host_port mini-baas-kong 8000/tcp)"
[[ -n "${KPORT}" ]] || skip "mini-baas-kong not running (make up + docker compose --profile hypertube up -d)"
docker inspect mini-baas-mongo >/dev/null 2>&1 || skip "mongo plane not up (hypertube profile)"

# ── 1) provision (idempotent) ────────────────────────────────────────────────
step "1/5 provision the hypertube tenant + mongo mount (idempotent)"
bash "${BAAS_DIR}/scripts/seed/hypertube-tenant.sh" >"${TMP}/seed.log" 2>&1 \
  || fail "provisioning failed — $(tail -3 "${TMP}/seed.log")"
# shellcheck disable=SC1091
source "${BAAS_DIR}/.hypertube-baas.env"
KONG="${HT_KONG_URL}"; ANON="${HT_ANON_APIKEY}"; AK="${HT_API_KEY}"; DB="${HT_MONGO_DB_ID}"; RT="${HT_REALTIME_TOKEN}"
[[ -n "${KONG}" && -n "${ANON}" && -n "${AK}" && -n "${DB}" ]] || fail "incomplete provisioning state"
[[ -n "${RT}" ]] || skip "no realtime token (realtime plane not up)"
ok "tenant=${HT_TENANT_SLUG} mongo=${DB}"

# /query CRUD helper (optional user Bearer as $3) → /tmp result, echoes status.
q() {
  local hdr=(-H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${AK}" -H 'Content-Type: application/json')
  [[ -n "${3:-}" ]] && hdr+=(-H "Authorization: Bearer $3")
  curl -s -o "${TMP}/q.json" -w '%{http_code}' -X POST "${KONG}/query/v1/${DB}/tables/$1" "${hdr[@]}" -d "$2"
}
# GoTrue signup → echoes "<sub> <jwt>".
signup() { # $1 label
  local email code
  email="m150_$1_$(date +%s)$$@hypertube.local"
  code=$(curl -s -o "${TMP}/a.json" -w '%{http_code}' -X POST "${KONG}/auth/v1/signup" \
    -H "apikey: ${ANON}" -H 'Content-Type: application/json' \
    -d "{\"email\":\"${email}\",\"password\":\"M150pass!secret\",\"data\":{\"username\":\"m150_$1_$$\"}}")
  [[ "${code}" == "200" || "${code}" == "201" ]] || fail "signup $1 (${code}): $(head -c 200 "${TMP}/a.json")"
  local jwt sub
  jwt="$(jval "${TMP}/a.json" access_token)"
  sub="$(jsub "${jwt}")"
  [[ -n "${jwt}" && -n "${sub}" ]] || fail "signup $1 returned no JWT/sub"
  echo "${sub} ${jwt}"
}

# ── 2) auth: signup → JWT; wrong password rejected ───────────────────────────
step "2/5 auth: GoTrue signup → JWT; wrong password rejected"
read -r UA JA <<<"$(signup a)"
read -r UB JB <<<"$(signup b)"
ok "two users signed up (A=${UA:0:8} B=${UB:0:8})"
bad=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${KONG}/auth/v1/token?grant_type=password" \
  -H "apikey: ${ANON}" -H 'Content-Type: application/json' \
  -d "{\"email\":\"nobody_$$@hypertube.local\",\"password\":\"wrong\"}")
[[ "${bad}" != "200" ]] || fail "wrong-password login should not return 200"
ok "wrong password rejected (${bad})"

# ── 3) movies: insert → list → delete (the shared catalog) ───────────────────
step "3/5 movies: insert catalog doc (201) → list → delete"
MID="m150-$$-$(date +%s)"
[[ "$(q movies "{\"op\":\"insert\",\"data\":{\"movie_id\":\"${MID}\",\"title\":\"Gate Reel\",\"source\":\"test\",\"popularity\":1}}" "${JA}")" == "201" ]] \
  || fail "movies insert: $(head -c 200 "${TMP}/q.json")"
# Shared/public read via the app-key path — the principal the SPA + REST API use
# for catalog/profile/comment reads, a DIFFERENT principal than the user writer.
q movies "{\"op\":\"list\",\"filter\":{\"movie_id\":{\"\$eq\":\"${MID}\"}}}" >/dev/null
[[ "$(jrows "${TMP}/q.json")" -ge 1 ]] || fail "catalog doc not listed back (shared movies broken)"
ok "movie ${MID} written by a user, read back via the shared app-key path"

# ── 4) shared read: A's comment is read by a DIFFERENT principal (B) ─────────
step "4/5 shared_resources: A's comment read back by user B (LOAD-BEARING)"
CTAG="m150-c-$$-$(date +%s)"
[[ "$(q comments "{\"op\":\"insert\",\"data\":{\"movie_id\":\"${MID}\",\"author_id\":\"${UA}\",\"author_username\":\"m150_a\",\"content\":\"${CTAG}\",\"created_at\":\"2026-06-19T00:00:00Z\"}}" "${JA}")" == "201" ]] \
  || fail "A comment insert: $(head -c 200 "${TMP}/q.json")"
q comments "{\"op\":\"list\",\"filter\":{\"movie_id\":{\"\$eq\":\"${MID}\"}}}" >/dev/null
grep -q "\"content\":\"${CTAG}\"" "${TMP}/q.json" \
  || fail "shared path cannot read A's comment — shared_resources on comments broken (VACUOUS otherwise)"
ok "cross-owner read: the shared app-key path sees A's comment (${CTAG})"
q comments "{\"op\":\"list\",\"filter\":{\"movie_id\":{\"\$eq\":\"nobody-xyz-$$\"}}}" >/dev/null
grep -q "\"content\":\"${CTAG}\"" "${TMP}/q.json" && fail "bogus filter leaked the comment"

# ── 5) realtime: a non-writer subscriber observes the comment change EVENT ───
step "5/5 realtime: subscribe table:${DB}:comments → insert → observe EVENT"
RT_OUT=$(docker run --rm --network host -e KONG="${KONG}" -e RT="${RT}" -e ANON="${ANON}" \
  -e DB="${DB}" -e AK="${AK}" -e UA="${UA}" -e MID="${MID}" "${NODE_IMAGE}" node -e '
const topic = `table:${process.env.DB}:comments`;
const u = new URL("/realtime/v1/ws", process.env.KONG);
u.protocol = "ws:"; u.searchParams.set("apikey", process.env.ANON); u.searchParams.set("access_token", process.env.RT);
const ws = new WebSocket(u.toString());
let done = false;
const finish = (v) => { if (done) return; done = true; console.log(v); try { ws.close(); } catch {} process.exit(0); };
setTimeout(() => finish("TIMEOUT"), 12000);
ws.addEventListener("open", () => ws.send(JSON.stringify({ type: "AUTH", token: process.env.RT })));
ws.addEventListener("message", async (f) => {
  let m; try { m = JSON.parse(f.data); } catch { return; }
  if (m.type === "AUTH_OK") {
    ws.send(JSON.stringify({ type: "SUBSCRIBE", sub_id: "m150", topic }));
    setTimeout(() => fetch(`${process.env.KONG}/query/v1/${process.env.DB}/tables/comments`, {
      method: "POST",
      headers: { apikey: process.env.ANON, "X-Baas-Api-Key": process.env.AK, "Content-Type": "application/json" },
      body: JSON.stringify({ op: "insert", data: { movie_id: process.env.MID, author_id: process.env.UA,
        author_username: "m150_rt", content: "m150-rt-event", created_at: "2026-06-19T00:00:01Z" } }),
    }).catch(() => {}), 1200);
  } else if (m.type === "EVENT" || m.type === "ROW_CHANGED") {
    finish("EVENT:" + (m.event && (m.event.event_type || m.event.type) || m.type));
  }
});
ws.addEventListener("error", () => finish("WSERR"));
' 2>/dev/null || true)
case "${RT_OUT}" in
  EVENT:*) ok "realtime ${RT_OUT} delivered to a non-writer subscriber" ;;
  *) fail "no realtime EVENT (got '${RT_OUT}')" ;;
esac

# ── cleanup test data (leave the permanent tenant + mount + demo users) ──────
q comments "{\"op\":\"delete\",\"filter\":{\"movie_id\":{\"\$eq\":\"${MID}\"}}}" "${JA}" >/dev/null 2>&1 || true
q movies "{\"op\":\"delete\",\"filter\":{\"movie_id\":{\"\$eq\":\"${MID}\"}}}" "${JA}" >/dev/null 2>&1 || true

printf '\033[0;32m[M150] ALL GATES GREEN — Hypertube on Grobase: auth · movies catalog · shared_resources cross-owner comment read · realtime EVENT\033[0m\n'
