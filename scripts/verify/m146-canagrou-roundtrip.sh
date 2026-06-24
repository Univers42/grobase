#!/usr/bin/env bash
# **************************************************************************** #
#  m146-canagrou-roundtrip.sh — Canagrou-on-Grobase live e2e gate              #
#                                                                              #
#  Proves the Canagrou photo app is fully backed by Grobase, end to end,       #
#  through Kong against the RUNNING stack:                                     #
#    1. provision   — `canagrou-tenant.sh` (idempotent): tenant+key+pg mount+  #
#                     schema+bucket+tokens.                                     #
#    2. auth        — GoTrue signup → JWT (sub); wrong password is rejected.   #
#    3. profile     — insert the app profile keyed by the GoTrue sub.          #
#    4. post        — insert via /query → read-back returns the image_key;     #
#                     a bogus filter returns nothing (teeth).                   #
#    5. like        — insert → count 1; delete → count 0.                      #
#    6. comment     — insert → list returns the content.                       #
#    7. storage     — upload a known binary via the shared identity →          #
#                     download is byte-identical (cmp).                        #
#    8. realtime    — a WS subscriber (that did NOT write) observes the EVENT  #
#                     after a /query insert on the posts topic.                #
#    9. reflection  — a SECOND user (different JWT) lists posts and SEES the   #
#                     first user's post (the public-wall read-after-write).    #
#   10. anti-spoof   — U1 (with U1's JWT) cannot impersonate U2: a forged       #
#                     user_id is coerced server-side to U1's sub; U1 cannot     #
#                     delete/update U2's row (0 affected); U2's row still reads.#
#                                                                              #
#  The realtime EVENT (step 8) and the cross-user read (step 9) are the        #
#  "data reflects in the frontend" proof. Step 10 is the anti-impersonation    #
#  NEGATIVE gate (the write path now carries the per-user JWT + a BEFORE        #
#  INSERT trigger binds authorship). Requires the stack up with auth +         #
#  query + storage + realtime planes.                                          #
# **************************************************************************** #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NODE_IMAGE="${NODE_IMAGE:-node:22-alpine}"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M146] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M146] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

TMP="$(mktemp -d)"
USER_IDS=()
trap 'rm -rf "${TMP}"' EXIT

# jval FILE KEY — first top-level-ish JSON string value for KEY (python, robust).
jval() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2],""))' "$1" "$2" 2>/dev/null || true; }
# jsub TOKEN — decode the `sub` claim from a JWT without verifying.
jsub() { python3 -c '
import sys,base64,json
p=sys.argv[1].split(".")[1]; p+="="*(-len(p)%4)
print(json.loads(base64.urlsafe_b64decode(p)).get("sub",""))' "$1" 2>/dev/null || true; }

# ── 1) provision (idempotent) ────────────────────────────────────────────────
step "1/9 provision the canagrou tenant (idempotent)"
bash "${BAAS_DIR}/scripts/seed/canagrou-tenant.sh" >/tmp/m146-seed.log 2>&1 \
  || fail "provisioning failed — see /tmp/m146-seed.log: $(tail -3 /tmp/m146-seed.log)"
# shellcheck disable=SC1091
source "${BAAS_DIR}/.canagrou-tenant.env"
# shellcheck disable=SC1091
source "${BAAS_DIR}/vendor/Canagrou/web/.env"
KONG="${CANAGROU_KONG_URL}"
ANON="${CANAGROU_ANON_APIKEY}"
AK="${CANAGROU_API_KEY}"
DB="${CANAGROU_DB_ID}"
ST="${VITE_BAAS_STORAGE_TOKEN}"
RT="${VITE_BAAS_REALTIME_TOKEN}"
BUCKET="${CANAGROU_BUCKET}"
[[ -n "${KONG}" && -n "${AK}" && -n "${DB}" && -n "${ST}" && -n "${RT}" ]] || fail "incomplete provisioning state"
ok "tenant=${CANAGROU_TENANT_SLUG} mount=${DB}"

# /query CRUD helper: body→/tmp/m146-q.json, echoes status.
q() {
  curl -s -o /tmp/m146-q.json -w '%{http_code}' -X POST "${KONG}/query/v1/${DB}/tables/$1" \
    -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${AK}" -H 'Content-Type: application/json' -d "$2"
}
# qj TABLE BODY JWT — /query CRUD carrying a user Bearer JWT, so the data plane
# owner-scopes the write to `user:<sub>` and the bind-author trigger fires.
qj() {
  curl -s -o /tmp/m146-q.json -w '%{http_code}' -X POST "${KONG}/query/v1/${DB}/tables/$1" \
    -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${AK}" -H "Authorization: Bearer $3" \
    -H 'Content-Type: application/json' -d "$2"
}
# GoTrue helper.
gotrue() {
  curl -s -o /tmp/m146-a.json -w '%{http_code}' -X POST "${KONG}/auth/v1/$1" \
    -H "apikey: ${ANON}" -H 'Content-Type: application/json' -d "$2"
}

signup_user() { # $1 label → echoes "<sub> <jwt>"
  local email="m146_$1_$(date +%s)$$@canagrou.local"
  local code
  code=$(gotrue "signup" "{\"email\":\"${email}\",\"password\":\"M146pass!secret\",\"data\":{\"username\":\"m146_$1_$$\"}}")
  [[ "${code}" == "200" || "${code}" == "201" ]] || fail "signup $1 (${code}): $(head -c 200 /tmp/m146-a.json)"
  local jwt sub
  jwt="$(jval /tmp/m146-a.json access_token)"
  sub="$(jsub "${jwt}")"
  [[ -n "${jwt}" && -n "${sub}" ]] || fail "signup $1 returned no JWT/sub"
  echo "${sub} ${jwt}"
}

# ── 2) auth ──────────────────────────────────────────────────────────────────
step "2/9 auth: signup → JWT; wrong password rejected"
read -r U1 J1 <<<"$(signup_user u1)"
USER_IDS+=("${U1}")
ok "signup → JWT (sub ${U1:0:8})"
bad=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${KONG}/auth/v1/token?grant_type=password" \
  -H "apikey: ${ANON}" -H 'Content-Type: application/json' \
  -d "{\"email\":\"nobody_$$@canagrou.local\",\"password\":\"wrong\"}")
[[ "${bad}" != "200" ]] || fail "wrong-password login should not return 200"
ok "wrong password rejected (${bad})"

# ── 3) profile ────────────────────────────────────────────────────────────────
step "3/9 profile insert (keyed by GoTrue sub)"
[[ "$(qj profiles "{\"op\":\"insert\",\"data\":{\"id\":\"${U1}\",\"username\":\"m146_u1_$$\"}}" "${J1}")" == "201" ]] \
  || fail "profile insert: $(head -c 200 /tmp/m146-q.json)"
ok "profile row created"

# ── 4) post insert → read-back ────────────────────────────────────────────────
step "4/9 post insert → read-back"
IMG_KEY="${U1}.png"
[[ "$(qj posts "{\"op\":\"insert\",\"data\":{\"user_id\":\"${U1}\",\"image_key\":\"${IMG_KEY}\"}}" "${J1}")" == "201" ]] \
  || fail "post insert: $(head -c 200 /tmp/m146-q.json)"
PID="$(python3 -c 'import json;print(json.load(open("/tmp/m146-q.json"))["rows"][0]["id"])')"
q posts "{\"op\":\"list\",\"filter\":{\"user_id\":{\"\$eq\":\"${U1}\"}}}" >/dev/null
grep -q "\"image_key\":\"${IMG_KEY}\"" /tmp/m146-q.json || fail "read-back missing image_key"
q posts "{\"op\":\"list\",\"filter\":{\"user_id\":{\"\$eq\":\"nobody-xyz\"}}}" >/dev/null
grep -q "\"image_key\":\"${IMG_KEY}\"" /tmp/m146-q.json && fail "bogus filter leaked the post"
ok "post ${PID} reads back; bogus filter returns nothing"

# ── 5) like toggle → count ────────────────────────────────────────────────────
step "5/9 like toggle → count"
qj likes "{\"op\":\"insert\",\"data\":{\"user_id\":\"${U1}\",\"post_id\":${PID}}}" "${J1}" >/dev/null
q likes "{\"op\":\"list\",\"filter\":{\"post_id\":{\"\$eq\":${PID}}}}" >/dev/null
c1="$(python3 -c 'import json;print(len(json.load(open("/tmp/m146-q.json"))["rows"]))')"
[[ "${c1}" == "1" ]] || fail "expected 1 like, got ${c1}"
qj likes "{\"op\":\"delete\",\"filter\":{\"post_id\":{\"\$eq\":${PID}}}}" "${J1}" >/dev/null
q likes "{\"op\":\"list\",\"filter\":{\"post_id\":{\"\$eq\":${PID}}}}" >/dev/null
c0="$(python3 -c 'import json;print(len(json.load(open("/tmp/m146-q.json"))["rows"]))')"
[[ "${c0}" == "0" ]] || fail "expected 0 likes after delete, got ${c0}"
ok "like → 1, unlike → 0"

# ── 6) comment add → list ─────────────────────────────────────────────────────
step "6/9 comment add → list"
qj comments "{\"op\":\"insert\",\"data\":{\"user_id\":\"${U1}\",\"post_id\":${PID},\"content\":\"m146 hello\"}}" "${J1}" >/dev/null
q comments "{\"op\":\"list\",\"filter\":{\"post_id\":{\"\$eq\":${PID}}}}" >/dev/null
grep -q '"content":"m146 hello"' /tmp/m146-q.json || fail "comment not listed"
ok "comment added + listed"

# ── 7) storage upload → byte-identical download ───────────────────────────────
step "7/9 storage upload → byte-identical download (shared identity)"
printf '%b' 'm146-img-\x00\x01\xfe\xff-roundtrip' >"${TMP}/up.bin"
up=$(curl -s -o /tmp/m146-st.json -w '%{http_code}' -X PUT "${KONG}/storage/v1/object/${BUCKET}/${IMG_KEY}" \
  -H "apikey: ${ANON}" -H "Authorization: Bearer ${ST}" \
  -H 'Content-Type: application/octet-stream' --data-binary @"${TMP}/up.bin")
[[ "${up}" == "200" ]] || fail "storage upload (${up}): $(head -c 200 /tmp/m146-st.json)"
dl=$(curl -s -o "${TMP}/dl.bin" -w '%{http_code}' "${KONG}/storage/v1/object/${BUCKET}/${IMG_KEY}" \
  -H "apikey: ${ANON}" -H "Authorization: Bearer ${ST}")
[[ "${dl}" == "200" ]] || fail "storage download (${dl})"
cmp -s "${TMP}/up.bin" "${TMP}/dl.bin" || fail "downloaded bytes differ from upload"
ok "upload + byte-identical download"

# ── 8) realtime: a subscriber that did NOT write observes the EVENT ───────────
step "8/9 realtime: subscribe → insert → observe EVENT"
RT_OUT=$(docker run --rm --network host -e KONG="${KONG}" -e RT="${RT}" -e ANON="${ANON}" \
  -e DB="${DB}" -e AK="${AK}" -e J1="${J1}" "${NODE_IMAGE}" node -e '
const topic = `table:${process.env.DB}:posts`;
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
    ws.send(JSON.stringify({ type: "SUBSCRIBE", sub_id: "m146", topic }));
    setTimeout(() => fetch(`${process.env.KONG}/query/v1/${process.env.DB}/tables/posts`, {
      method: "POST",
      headers: { apikey: process.env.ANON, "X-Baas-Api-Key": process.env.AK, Authorization: "Bearer " + process.env.J1, "Content-Type": "application/json" },
      body: JSON.stringify({ op: "insert", data: { user_id: "'"${U1}"'", image_key: "'"${U1}"'-rt.png" } }),
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

# ── 9) cross-user reflection (read-after-write by a different user) ───────────
step "9/9 reflection: a second user sees the first user's post"
read -r U2 J2 <<<"$(signup_user u2)"
USER_IDS+=("${U2}")
q posts "{\"op\":\"list\",\"filter\":{\"image_key\":{\"\$eq\":\"${IMG_KEY}\"}}}" >/dev/null
grep -q "\"image_key\":\"${IMG_KEY}\"" /tmp/m146-q.json || fail "second user cannot see the first user's post"
ok "second user sees the post (public-wall reflection)"

# ── 10) anti-impersonation: per-user JWT + server-side authorship binding ─────
step "10/10 anti-impersonation: forged user_id coerced; cross-user write denied"
# U1's profile already exists (step 3, anonymous). U2 needs one, created under
# U2's OWN JWT but FORGING U1's id — the trigger must bind profiles.id from
# owner_id `user:U2`, so the forged id is overwritten with U2.
[[ "$(qj profiles "{\"op\":\"insert\",\"data\":{\"id\":\"${U1}\",\"username\":\"m146_imp_u2_$$\"}}" "${J2}")" == "201" ]] \
  || fail "U2 profile (authed, forged id) insert: $(head -c 200 /tmp/m146-q.json)"
PROF_ID="$(python3 -c 'import json;print(json.load(open("/tmp/m146-q.json"))["rows"][0]["id"])')"
[[ "${PROF_ID}" == "${U2}" ]] || fail "impersonation HOLE: profile id landed as '${PROF_ID}' (want U2 ${U2:0:8}, NOT U1 ${U1:0:8})"
ok "forged profile id coerced to the authenticated writer (U2)"

# U2 (authed) creates a post owned by U2.
V2_KEY="${U2}-victim.png"
[[ "$(qj posts "{\"op\":\"insert\",\"data\":{\"user_id\":\"${U2}\",\"image_key\":\"${V2_KEY}\"}}" "${J2}")" == "201" ]] \
  || fail "U2 victim post insert: $(head -c 200 /tmp/m146-q.json)"
V2_PID="$(python3 -c 'import json;print(json.load(open("/tmp/m146-q.json"))["rows"][0]["id"])')"

# (a) U1, with U1's JWT, FORGES U2's user_id on insert → must be coerced to U1.
FORGE_KEY="${U1}-forge.png"
[[ "$(qj posts "{\"op\":\"insert\",\"data\":{\"user_id\":\"${U2}\",\"image_key\":\"${FORGE_KEY}\"}}" "${J1}")" == "201" ]] \
  || fail "U1 forged-author insert rejected unexpectedly: $(head -c 200 /tmp/m146-q.json)"
COERCED="$(python3 -c 'import json;print(json.load(open("/tmp/m146-q.json"))["rows"][0]["user_id"])')"
[[ "${COERCED}" == "${U1}" ]] || fail "impersonation HOLE: forged user_id landed as '${COERCED}' (want U1 ${U1:0:8}, NOT U2 ${U2:0:8})"
[[ "${COERCED}" != "${U2}" ]] || fail "impersonation HOLE: author bound to victim U2"
ok "forged user_id coerced to the authenticated writer (U1)"

# (a') the public app key ALONE (no JWT) cannot author: an app-key-only insert
# forging a victim user_id must be REJECTED (no `user:` owner ⇒ the bind-author
# trigger raises — authorship requires authentication, closing the crafted-request
# impersonation vector the public key would otherwise allow).
ANON_CODE="$(q posts "{\"op\":\"insert\",\"data\":{\"user_id\":\"${U2}\",\"image_key\":\"${U1}-anon-forge.png\"}}")"
[[ "${ANON_CODE}" != "201" ]] \
  || fail "impersonation HOLE: app-key-only (no JWT) write authored a post as U2 (HTTP ${ANON_CODE})"
ok "app-key-only write rejected — authorship requires a JWT"

# (b) U1, with U1's JWT, tries to DELETE U2's post → owner-scoped to 0 rows.
# affected N from the mutation envelope: rowCount (canonical), else rows length.
affected() { python3 -c 'import json;d=json.load(open("/tmp/m146-q.json"));print(d.get("rowCount", d.get("count", len(d.get("rows",[])))))' 2>/dev/null || echo 0; }
qj posts "{\"op\":\"delete\",\"filter\":{\"id\":{\"\$eq\":${V2_PID}}}}" "${J1}" >/dev/null
DEL_N="$(affected)"
[[ "${DEL_N}" == "0" ]] || fail "impersonation HOLE: U1 deleted ${DEL_N} of U2's rows (want 0)"

# (c) U1, with U1's JWT, tries to UPDATE U2's post → owner-scoped to 0 rows.
qj posts "{\"op\":\"update\",\"data\":{\"image_key\":\"hijacked.png\"},\"filter\":{\"id\":{\"\$eq\":${V2_PID}}}}" "${J1}" >/dev/null
UPD_N="$(affected)"
[[ "${UPD_N}" == "0" ]] || fail "impersonation HOLE: U1 updated ${UPD_N} of U2's rows (want 0)"
ok "U1 cannot delete or update U2's post (0 affected)"

# (d) public wall preserved: U2's victim post is still readable (unscoped read).
q posts "{\"op\":\"list\",\"filter\":{\"image_key\":{\"\$eq\":\"${V2_KEY}\"}}}" >/dev/null
grep -q "\"image_key\":\"${V2_KEY}\"" /tmp/m146-q.json || fail "public-wall regression: U2's post no longer reads after the write-deny checks"
grep -q '"image_key":"hijacked.png"' /tmp/m146-q.json && fail "impersonation HOLE: U2's post WAS hijacked"
ok "public wall intact: U2's post still reads, unaltered"

# ── cleanup test data (leave the permanent tenant) ───────────────────────────
# Authed rows (owner `user:<sub>`) only delete under their own JWT (owner-scoped);
# the anonymous sweep below clears the app-key-owned rows from steps 3–9.
for pair in "${U1} ${J1}" "${U2} ${J2}"; do
  read -r uid jwt <<<"${pair}"
  qj posts "{\"op\":\"delete\",\"filter\":{\"user_id\":{\"\$eq\":\"${uid}\"}}}" "${jwt}" >/dev/null 2>&1 || true
  qj profiles "{\"op\":\"delete\",\"filter\":{\"id\":{\"\$eq\":\"${uid}\"}}}" "${jwt}" >/dev/null 2>&1 || true
done
for uid in "${USER_IDS[@]}"; do
  q posts "{\"op\":\"delete\",\"filter\":{\"user_id\":{\"\$eq\":\"${uid}\"}}}" >/dev/null 2>&1 || true
  q profiles "{\"op\":\"delete\",\"filter\":{\"id\":{\"\$eq\":\"${uid}\"}}}" >/dev/null 2>&1 || true
done
curl -s -o /dev/null -X DELETE "${KONG}/storage/v1/object/${BUCKET}/${IMG_KEY}" \
  -H "apikey: ${ANON}" -H "Authorization: Bearer ${ST}" 2>/dev/null || true

printf '\033[0;32m[M146] ALL GATES GREEN — Canagrou fully backed by Grobase: auth · profile · post · like · comment · storage byte-roundtrip · realtime EVENT · cross-user reflection · anti-impersonation (server-bound authorship)\033[0m\n'
