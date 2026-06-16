#!/usr/bin/env bash
# **************************************************************************** #
#  m23-agency-platform.sh — gate for the agency PLATFORM layer                 #
#                                                                              #
#  Proves the collaboration surface built on top of the m23 foundation:        #
#    a) policy bundle: GET /permissions/bundles/latest via Kong serves         #
#       user_roles + policies, with at least one field mask present           #
#    b) bridge login mints app sessions for owner + analyst                    #
#    c) chat roundtrip: owner posts into a namespaced probe channel →          #
#       analyst reads it back → a WS subscriber (node:22-alpine on the         #
#       mini-baas network, m22 pattern) receives message_created on the        #
#       chat:<ws>:<channel> topic                                              #
#    d) DM privacy: a third party reading someone else's DM is a 403           #
#    e) /api/rtc/token mints a LiveKit join token; the LiveKit twirp admin     #
#       API accepts an HS256 admin JWT (ListRooms)                             #
#    f) feed roundtrip: owner like + comment on a wiki page → analyst sees     #
#       both                                                                   #
#    g) /api/people search + /api/profile/:id fetch                            #
#    h) analyst /api/perms/decide carries the transactions.amount mask         #
#                                                                              #
#  Requires: both stacks running + make agency-all + agency content seeded.    #
#  Probe artifacts are namespaced sim-probe-* and removed on exit.             #
# **************************************************************************** #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${INFRA_ROOT}/../../.." && pwd)"
TENANT_ENV="${INFRA_ROOT}/.agency-tenant.env"
PEOPLE_ENV="${REPO_ROOT}/tools/seeds/.agency-people.env"
CA_FILE="${REPO_ROOT}/apps/baas/certs/track-binocle-local-ca.pem"
BRIDGE_URL="${AGENCY_BRIDGE_URL:-https://localhost:4000}"
LIVEKIT_HTTP_URL="${AGENCY_LIVEKIT_URL:-http://127.0.0.1:7880}"
ORG_WS_DEFAULT="b1a0c1e5-0000-4000-a000-000000000001"

cyan()  { printf '\033[0;36m[M23P] %s\033[0m\n' "$*"; }
green() { printf '\033[0;32m[M23P] PASS: %s\033[0m\n' "$*"; }
fail()  { printf '\033[0;31m[M23P] FAIL: %s\033[0m\n' "$*" >&2; exit 1; }

[[ -f "${TENANT_ENV}" ]] || fail "missing ${TENANT_ENV} (run make agency-seed)"
[[ -f "${PEOPLE_ENV}" ]] || fail "missing ${PEOPLE_ENV} (run make agency-people)"
# shellcheck disable=SC1090
source "${TENANT_ENV}"
ORG_WS_ID="$(grep '^AGENCY_ORG_WORKSPACE_ID=' "${PEOPLE_ENV}" | cut -d= -f2)"
ORG_WS_ID="${ORG_WS_ID:-${ORG_WS_DEFAULT}}"
person_field() { grep "^AGENCY_PERSON_$1=" "${PEOPLE_ENV}" | cut -d= -f2 | cut -d'|' -f"$2"; }
ANALYST_UUID="$(person_field 11 1)"   # Erik Johansson — analyst
ANALYST_EMAIL="$(person_field 11 2)"
DEPUTY_UUID="$(person_field 1 1)"     # Marcus Reed — deputy director (DM peer)

# curl wrapper: trust the project CA when present, else tolerate the local cert
CURL=(curl -sS)
if [[ -f "${CA_FILE}" ]]; then CURL+=(--cacert "${CA_FILE}"); else CURL+=(-k); fi
RPSQL() { docker exec -i track-binocle-postgres-1 psql -U postgres -d postgres -At "$@"; }
jsonget() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }

PROBE_RUN="$(date +%s)"
PROBE_CHANNEL_NAME="sim-probe-m23p-${PROBE_RUN}"
WS_NAME="m23p-ws-${PROBE_RUN}"
PROBE_COMMENT_MARK="sim-probe m23p comment ${PROBE_RUN}"
cleanup() {
  docker rm -f "${WS_NAME}" >/dev/null 2>&1 || true
  RPSQL -q -c "DELETE FROM osionos_channels WHERE name='${PROBE_CHANNEL_NAME}'" >/dev/null 2>&1 || true
  RPSQL -q -c "DELETE FROM osionos_feed_comments WHERE content='${PROBE_COMMENT_MARK}'" >/dev/null 2>&1 || true
  if [[ -n "${FEED_PAGE_ID:-}" && -n "${OWNER_TOKEN:-}" ]]; then
    "${CURL[@]}" -X DELETE "${BRIDGE_URL}/api/feed/${FEED_PAGE_ID}/like" \
      -H "Authorization: Bearer ${OWNER_TOKEN}" -o /dev/null 2>/dev/null || true
  fi
  rm -f /tmp/m23p-ws-probe.mjs 2>/dev/null || true
}
trap cleanup EXIT

# ── a) policy bundle through Kong ─────────────────────────────────────────────
cyan "a) GET /permissions/bundles/latest via Kong (user_roles + policies + mask)"
PE_TOKEN="$(docker inspect mini-baas-permission-engine \
  --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep '^ADAPTER_REGISTRY_SERVICE_TOKEN=' | cut -d= -f2-)"
[[ -n "${PE_TOKEN}" ]] || fail "permission-engine service token not found"
bundle="$(curl -fsS "${AGENCY_KONG_URL}/permissions/v1/permissions/bundles/latest" \
  -H "apikey: ${AGENCY_SERVICE_APIKEY}" -H "X-Service-Token: ${PE_TOKEN}" \
  -H "X-Tenant-Id: agency")" || fail "bundle fetch through Kong failed"
echo "${bundle}" | grep -q '"user_roles":' || fail "bundle missing user_roles"
echo "${bundle}" | grep -q '"policies":'   || fail "bundle missing policies"
roles_n=$(echo "${bundle}" | jsonget "len(d['user_roles'])")
pol_n=$(echo "${bundle}" | jsonget "len(d['policies'])")
[[ "${roles_n}" -ge 21 ]] || fail "bundle has only ${roles_n} user_roles (expected ≥21)"
[[ "${pol_n}" -ge 40 ]] || fail "bundle has only ${pol_n} policies (expected ≥40)"
echo "${bundle}" | grep -q '"amount"' || fail "bundle spot-check: no policy carries the amount mask"
green "bundle serves ${roles_n} user_roles + ${pol_n} policies incl. the amount mask"

# ── b) bridge logins ──────────────────────────────────────────────────────────
cyan "b) bridge /api/auth/login mints sessions (owner + analyst)"
bridge_login() { # $1 email, $2 password → access token on stdout
  "${CURL[@]}" -X POST "${BRIDGE_URL}/api/auth/login" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$1\",\"password\":\"$2\"}" \
    | jsonget "d['session']['accessToken']"
}
OWNER_TOKEN="$(bridge_login owner@agency.local 'BinocleOwner1!')" \
  || fail "owner bridge login failed"
[[ "${OWNER_TOKEN}" == osionos_v1.* ]] || fail "owner login did not mint an osionos_v1 token"
ANALYST_TOKEN="$(bridge_login "${ANALYST_EMAIL}" 'AgencyDemo1!')" \
  || fail "analyst bridge login failed"
[[ "${ANALYST_TOKEN}" == osionos_v1.* ]] || fail "analyst login did not mint an osionos_v1 token"
green "owner + analyst sessions minted through the auth-gateway proxy"

# ── c) chat roundtrip + realtime WS echo ──────────────────────────────────────
cyan "c) chat roundtrip: owner → probe channel → analyst + WS message_created"
created="$("${CURL[@]}" -X POST "${BRIDGE_URL}/api/chat/channels" \
  -H "Authorization: Bearer ${OWNER_TOKEN}" -H 'Content-Type: application/json' \
  -d "{\"workspaceId\":\"${ORG_WS_ID}\",\"name\":\"${PROBE_CHANNEL_NAME}\"}")" \
  || fail "probe channel creation failed"
CHANNEL_ID="$(echo "${created}" | jsonget "d['channel']['id']")"
[[ -n "${CHANNEL_ID}" ]] || fail "no channel id in: ${created}"

STACK_NET="$(docker inspect mini-baas-kong \
  --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null | head -1)"
[[ -n "${STACK_NET}" ]] || fail "could not resolve the mini-baas docker network"
RT_JWT_SECRET="$(docker inspect mini-baas-realtime \
  --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
  | grep '^REALTIME_JWT_SECRET=' | cut -d= -f2-)"
[[ -n "${RT_JWT_SECRET}" ]] || fail "REALTIME_JWT_SECRET not found on mini-baas-realtime"
WS_PROBE="/tmp/m23p-ws-probe.mjs"
cat > "${WS_PROBE}" <<'WSJS'
import { createHmac } from 'node:crypto';
const b64u = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const head = b64u({ alg: 'HS256', typ: 'JWT' });
const body = b64u({ sub: 'm23p-verify', exp: Math.floor(Date.now() / 1000) + 300 });
const sig = createHmac('sha256', process.env.RT_JWT_SECRET)
  .update(`${head}.${body}`).digest('base64url');
const ws = new WebSocket(process.env.RT_WS_URL);
const die = (msg) => { console.log(msg); process.exit(1); };
setTimeout(() => die('TIMEOUT waiting for message_created'), Number(process.env.RT_WAIT_MS ?? 30000));
ws.onopen = () => ws.send(JSON.stringify({ type: 'AUTH', token: `${head}.${body}.${sig}` }));
ws.onerror = (e) => die(`WS_ERROR ${e.message ?? 'connect failed'}`);
ws.onmessage = (m) => {
  const f = JSON.parse(m.data);
  if (f.type === 'AUTH_OK') {
    ws.send(JSON.stringify({ type: 'SUBSCRIBE', sub_id: 's1', topic: process.env.RT_TOPIC }));
  } else if (f.type === 'SUBSCRIBED') {
    console.log('SUBSCRIBED');
  } else if (f.type === 'EVENT' && f.event.event_type === 'message_created') {
    console.log(`MESSAGE_CREATED ${f.event.topic} ${JSON.stringify(f.event.payload)}`);
    process.exit(0);
  } else if (f.type === 'ERROR') {
    die(`PROTO_ERROR ${f.code} ${f.message}`);
  }
};
WSJS
WS_NODE_IMAGE="${BAAS_WS_NODE_IMAGE:-node:22-alpine}"
docker rm -f "${WS_NAME}" >/dev/null 2>&1 || true
docker run -d --name "${WS_NAME}" --network "${STACK_NET}" \
  -v "${WS_PROBE}:/probe.mjs:ro" \
  -e RT_WS_URL="ws://kong:8000/realtime/v1/ws" \
  -e RT_JWT_SECRET="${RT_JWT_SECRET}" \
  -e RT_TOPIC="chat:${ORG_WS_ID}:${CHANNEL_ID}" \
  -e RT_WAIT_MS=30000 \
  "${WS_NODE_IMAGE}" node /probe.mjs >/dev/null \
  || fail "could not start the WS subscriber container (${WS_NODE_IMAGE})"
for _ in $(seq 1 40); do
  docker logs "${WS_NAME}" 2>&1 | grep -q 'SUBSCRIBED' && break
  sleep 0.5
done
docker logs "${WS_NAME}" 2>&1 | grep -q 'SUBSCRIBED' \
  || fail "WS subscriber never reached SUBSCRIBED: $(docker logs "${WS_NAME}" 2>&1 | tail -3)"

MSG_TEXT="m23p chat roundtrip ${PROBE_RUN}"
"${CURL[@]}" -X POST "${BRIDGE_URL}/api/chat/channels/${CHANNEL_ID}/messages" \
  -H "Authorization: Bearer ${OWNER_TOKEN}" -H 'Content-Type: application/json' \
  -d "{\"content\":\"${MSG_TEXT}\"}" | grep -q '"ok":true' \
  || fail "owner message post failed"
"${CURL[@]}" "${BRIDGE_URL}/api/chat/channels/${CHANNEL_ID}/messages" \
  -H "Authorization: Bearer ${ANALYST_TOKEN}" | grep -q "${MSG_TEXT}" \
  || fail "analyst does not see the owner's message"
ECHO_OK=0
for _ in $(seq 1 10); do
  if docker logs "${WS_NAME}" 2>&1 | grep -q 'MESSAGE_CREATED'; then ECHO_OK=1; break; fi
  sleep 0.5
done
[[ "${ECHO_OK}" == "1" ]] \
  || fail "no message_created frame within 5s: $(docker logs "${WS_NAME}" 2>&1 | tail -3)"
docker logs "${WS_NAME}" 2>&1 | grep 'MESSAGE_CREATED' \
  | grep -q "chat:${ORG_WS_ID}:${CHANNEL_ID}" \
  || fail "message_created arrived on the wrong topic"
green "owner→channel→analyst roundtrip + message_created on chat:<ws>:<channel>"

# ── d) DM privacy ─────────────────────────────────────────────────────────────
cyan "d) DM privacy: third party reading someone else's DM is a 403"
dm="$("${CURL[@]}" -X POST "${BRIDGE_URL}/api/chat/dm" \
  -H "Authorization: Bearer ${OWNER_TOKEN}" -H 'Content-Type: application/json' \
  -d "{\"peerUserId\":\"${DEPUTY_UUID}\"}")" || fail "owner↔deputy DM open failed"
DM_ID="$(echo "${dm}" | jsonget "d['channel']['id']")"
code="$("${CURL[@]}" -o /tmp/m23p-dm.json -w '%{http_code}' \
  "${BRIDGE_URL}/api/chat/channels/${DM_ID}/messages" \
  -H "Authorization: Bearer ${ANALYST_TOKEN}")"
[[ "${code}" == "403" ]] || fail "third-party DM read must be 403, got ${code}: $(cat /tmp/m23p-dm.json)"
green "analyst reading the owner↔deputy DM is rejected with 403"

# ── e) RTC token + LiveKit admin twirp ────────────────────────────────────────
cyan "e) /api/rtc/token mints + LiveKit ListRooms accepts an admin JWT"
WARROOM_ID="$(RPSQL -c "SELECT id FROM osionos_channels WHERE workspace_id='${ORG_WS_ID}' AND kind='video' LIMIT 1")"
[[ -n "${WARROOM_ID}" ]] || fail "no video channel found on the org workspace"
rtc="$("${CURL[@]}" -X POST "${BRIDGE_URL}/api/rtc/token" \
  -H "Authorization: Bearer ${OWNER_TOKEN}" -H 'Content-Type: application/json' \
  -d "{\"channelId\":\"${WARROOM_ID}\"}")" || fail "rtc token mint failed"
echo "${rtc}" | grep -q '"ok":true' || fail "rtc token response not ok: ${rtc}"
echo "${rtc}" | grep -q '"token":"eyJ' || fail "rtc response carries no JWT"
echo "${rtc}" | grep -q '"url":"ws' || fail "rtc response carries no client ws url"

LK_PAIR="$(docker inspect track-binocle-livekit-1 \
  --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep '^LIVEKIT_KEYS=' | cut -d= -f2-)"
LK_KEY="${LK_PAIR%%:*}"
LK_SECRET="$(echo "${LK_PAIR#*:}" | xargs)"
[[ -n "${LK_KEY}" && -n "${LK_SECRET}" ]] || fail "LIVEKIT_KEYS not found on track-binocle-livekit-1"
ADMIN_JWT="$(docker run --rm -e LK_KEY="${LK_KEY}" -e LK_SECRET="${LK_SECRET}" \
  "${WS_NODE_IMAGE}" node -e '
const { createHmac } = require("node:crypto");
const b64u = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const now = Math.floor(Date.now()/1000);
const head = b64u({ alg: "HS256", typ: "JWT" });
const body = b64u({ iss: process.env.LK_KEY, sub: "m23p-admin", nbf: now-10, exp: now+300, video: { roomList: true } });
const sig = createHmac("sha256", process.env.LK_SECRET).update(`${head}.${body}`).digest("base64url");
console.log(`${head}.${body}.${sig}`);
')" || fail "admin JWT mint failed"
rooms_code="$(curl -s -o /tmp/m23p-rooms.json -w '%{http_code}' \
  -X POST "${LIVEKIT_HTTP_URL}/twirp/livekit.RoomService/ListRooms" \
  -H "Authorization: Bearer ${ADMIN_JWT}" -H 'Content-Type: application/json' -d '{}')"
[[ "${rooms_code}" == "200" ]] || fail "ListRooms must be 200, got ${rooms_code}: $(cat /tmp/m23p-rooms.json)"
grep -q '"rooms"' /tmp/m23p-rooms.json || fail "ListRooms reply has no rooms field"
green "rtc token minted for the video channel; LiveKit twirp admin path live"

# ── f) feed like + comment roundtrip ──────────────────────────────────────────
cyan "f) feed roundtrip: owner like+comment on a wiki page → analyst sees both"
FEED_PAGE_ID="$("${CURL[@]}" "${BRIDGE_URL}/api/pages?workspaceId=${ORG_WS_ID}" \
  -H "Authorization: Bearer ${OWNER_TOKEN}" | jsonget "d[0]['_id']")"
[[ -n "${FEED_PAGE_ID}" ]] || fail "could not pick a wiki page on the org workspace"
"${CURL[@]}" -X POST "${BRIDGE_URL}/api/feed/${FEED_PAGE_ID}/like" \
  -H "Authorization: Bearer ${OWNER_TOKEN}" | grep -q '"likedByMe":true' \
  || fail "owner like failed"
"${CURL[@]}" "${BRIDGE_URL}/api/feed/${FEED_PAGE_ID}/likes" \
  -H "Authorization: Bearer ${ANALYST_TOKEN}" | grep -q '"count":[1-9]' \
  || fail "analyst does not see the like count"
"${CURL[@]}" -X POST "${BRIDGE_URL}/api/feed/${FEED_PAGE_ID}/comments" \
  -H "Authorization: Bearer ${OWNER_TOKEN}" -H 'Content-Type: application/json' \
  -d "{\"content\":\"${PROBE_COMMENT_MARK}\"}" | grep -q '"ok":true' \
  || fail "owner comment failed"
"${CURL[@]}" "${BRIDGE_URL}/api/feed/${FEED_PAGE_ID}/comments" \
  -H "Authorization: Bearer ${ANALYST_TOKEN}" | grep -q "${PROBE_COMMENT_MARK}" \
  || fail "analyst does not see the owner's comment"
green "like + comment visible cross-user on page ${FEED_PAGE_ID}"

# ── g) people search + profile ────────────────────────────────────────────────
cyan "g) /api/people search + /api/profile/:id"
"${CURL[@]}" "${BRIDGE_URL}/api/people?query=johansson" \
  -H "Authorization: Bearer ${OWNER_TOKEN}" | grep -q "${ANALYST_UUID}" \
  || fail "people search did not find the analyst"
profile="$("${CURL[@]}" "${BRIDGE_URL}/api/profile/${ANALYST_UUID}" \
  -H "Authorization: Bearer ${OWNER_TOKEN}")" || fail "profile fetch failed"
echo "${profile}" | grep -q '"ok":true' || fail "profile response not ok: ${profile}"
echo "${profile}" | grep -q "\"workspaceId\":\"${ORG_WS_ID}\"" \
  || fail "profile is not scoped to the org workspace: ${profile}"
green "people search resolves the analyst; profile carries org role + presence"

# ── h) analyst decide mask through the bridge proxy ───────────────────────────
cyan "h) /api/perms/decide (bridge proxy) shows the analyst amount mask"
decision="$("${CURL[@]}" -X POST "${BRIDGE_URL}/api/perms/decide" \
  -H 'Content-Type: application/json' \
  -d "{\"user\":{\"id\":\"${ANALYST_UUID}\"},\"resource_type\":\"table\",\"resource_name\":\"transactions\",\"op\":\"list\"}")" \
  || fail "decide through the bridge failed"
echo "${decision}" | grep -q '"allow":true' || fail "analyst must be allowed: ${decision}"
echo "${decision}" | grep -q '"amount":"\*\*\*"' \
  || fail "analyst decision must mask amount: ${decision}"
green "bridge perms proxy returns allow + {redact:{amount:'***'}} for the analyst"

green "M23 PLATFORM OK — bundle, sessions, chat+WS, DM privacy, video, feed, people, masks all live"
