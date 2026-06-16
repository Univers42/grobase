#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m97-presence-crossnode.sh                          :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M97 — Track-A residual A5: REALTIME cross-node PRESENCE merge.
#
# The in-process PresenceTracker is single-node authoritative: a TRACK on node A
# is invisible to a presence query served by node B. This gate proves the
# SharedPresence backend (Redis) makes presence visible across nodes when the
# REALTIME_PRESENCE_SHARED sub-flag is ON — and byte-parity (single-node) when
# OFF.
#
# Topology (every container/image/network suffixed with $$, EXIT-trap removes
# EVERYTHING, built FROM CURRENT SOURCE via the real Dockerfile, NEVER touches a
# mini-baas-* container/network/image/volume nor the live docker-compose.yml):
#
#   redis  ── shared presence store (key: presence:<topic> hash conn_id→member)
#     ▲  ▲
#     │  │  REALTIME_PRESENCE_SHARED=1, REALTIME_PRESENCE_REDIS_URL=redis://…
#   rt-A  rt-B   (two realtime-server nodes, same scratch image, same redis)
#     │
#     │ a WS client AUTHs + TRACKs channel X on node A and HOLDS the connection
#     ▼
#   then the gate queries  GET http://rt-B:4000/v1/presence?topic=X  on node B.
#
# THREE arms:
#
#   (A) POSITIVE — a client joins channel X on node A and holds open. A presence
#       query on node B (a DIFFERENT node) lists that member. This is the whole
#       point: cross-node merge through the shared Redis store.
#
#   (R) LOAD-BEARING REJECT — two independent properties, either failure fails:
#         (R1) NO cross-channel leak: a member in channel X is NOT visible in a
#              query for channel Y (the member that joined X must never surface
#              under Y — a vacuous "any non-empty list passes" gate is rejected).
#         (R2) leave removes cross-node: when the node-A client UNTRACKs (closes),
#              a presence query on node B no longer lists it — a leave on A
#              propagates to B through the shared store.
#
#   (P) FLAG-OFF PARITY — with REALTIME_PRESENCE_SHARED UNSET on BOTH nodes
#       (the proven baseline), the SAME join on node A is NOT visible on node B
#       (each node keeps only its own in-process set), yet IS visible LOCALLY on
#       node A (presence still works single-node) — byte-identical to today. The
#       ON containers are STOPPED+REMOVED and Redis FLUSHED before this arm so no
#       shared state from (A)/(R) can leak in.
#
# Output is tee'd to artifacts/a5/m97.txt.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                  # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                        # apps/baas
RT_DIR="${INFRA_DIR}/docker/services/realtime/realtime-agnostic"
LOG_SH="${BAAS_DIR}/.claude/lib/log.sh"
ART_DIR="${INFRA_DIR}/artifacts/a5"
ART="${ART_DIR}/m97.txt"

mkdir -p "${ART_DIR}"
exec > >(tee "${ART}") 2>&1

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M97] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M97] FAIL — $*"; exit 1; }

REDIS_IMAGE="${M97_REDIS_IMAGE:-redis:7-alpine}"
NODE_IMAGE="${M97_NODE_IMAGE:-node:20-bookworm-slim}"
RT_IMG="m97-rt-$$:scratch"
NET="m97net-$$"
REDIS="m97-redis-$$"
RT_A_ON="m97-rt-a-on-$$"     # node A, shared ON
RT_B_ON="m97-rt-b-on-$$"     # node B, shared ON
RT_A_OFF="m97-rt-a-off-$$"   # node A, shared OFF (parity)
RT_B_OFF="m97-rt-b-off-$$"   # node B, shared OFF (parity)
REDIS_INNET="redis://${REDIS}:6379"
PREFIX="m97-$$"              # isolate this run's presence namespace in Redis
# Channels: the member joins X; Y is the decoy used to prove no cross-channel leak.
CH_X="room/x-$$"
CH_Y="room/y-$$"
USER_A="alice-$$"           # token == claims.sub under NoAuth ⇒ the member's user_id
RT_PORT_A_ON="${M97_PORT_A_ON:-19190}"
RT_PORT_B_ON="${M97_PORT_B_ON:-19191}"
RT_PORT_A_OFF="${M97_PORT_A_OFF:-19192}"
RT_PORT_B_OFF="${M97_PORT_B_OFF:-19193}"
# Zero-dependency RFC-6455 WS client (node:net + node:crypto) — no npm, no egress.
WSCLIENT="$(mktemp --suffix=.js)"
# A FIFO the client signals once TRACK has been sent + acknowledged, so the gate
# only queries AFTER the member is in Redis; a second signal on close.
SIGDIR="$(mktemp -d)"

cleanup() {
  docker rm -fv "${RT_A_ON}" "${RT_B_ON}" "${RT_A_OFF}" "${RT_B_OFF}" "${REDIS}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${RT_IMG}" >/dev/null 2>&1 || true
  rm -f "${WSCLIENT}" 2>/dev/null || true
  rm -rf "${SIGDIR}" 2>/dev/null || true
}
trap cleanup EXIT

# A long-lived WS client: AUTH (token == TENANT ⇒ claims.sub == TENANT, the
# member's user_id), then TRACK <topic> with meta, then HOLD the connection open
# until told to leave. It writes JOINED to stdout once TRACK is sent, holds for
# HOLD_SECS, then sends a real CLOSE frame (the genuine UNTRACK/disconnect path).
# Prints LEFT after closing. Drives the REAL /ws endpoint — no stub.
cat > "${WSCLIENT}" <<'JS'
const net = require("net");
const crypto = require("crypto");
const host = process.env.RT_HOST, token = process.env.TOKEN;
const topic = process.env.TOPIC;
const holdSecs = Number(process.env.HOLD_SECS || "8");
function maskFrame(text) {
  const payload = Buffer.from(text, "utf8");
  const len = payload.length; // small JSON < 126
  const mask = crypto.randomBytes(4);
  const head = Buffer.from([0x81, 0x80 | len]);
  const masked = Buffer.alloc(len);
  for (let i = 0; i < len; i++) masked[i] = payload[i] ^ mask[i % 4];
  return Buffer.concat([head, mask, masked]);
}
function closeFrame() { // masked close, code 1000
  const mask = crypto.randomBytes(4);
  const body = Buffer.from([0x03, 0xe8]);
  const masked = Buffer.alloc(2);
  for (let i = 0; i < 2; i++) masked[i] = body[i] ^ mask[i % 4];
  return Buffer.concat([Buffer.from([0x88, 0x82]), mask, masked]);
}
const key = crypto.randomBytes(16).toString("base64");
const sock = net.connect(4000, host, () => {
  sock.write(
    "GET /ws HTTP/1.1\r\nHost: " + host + "\r\nUpgrade: websocket\r\n" +
    "Connection: Upgrade\r\nSec-WebSocket-Key: " + key +
    "\r\nSec-WebSocket-Version: 13\r\n\r\n");
});
let handshook = false;
sock.on("data", (buf) => {
  if (!handshook && buf.toString("latin1").includes("101")) {
    handshook = true;
    sock.write(maskFrame(JSON.stringify({ type: "AUTH", token })));
    // Give AUTH a beat, then TRACK and announce JOINED.
    setTimeout(() => {
      sock.write(maskFrame(JSON.stringify(
        { type: "TRACK", topic, meta: { user: token } })));
      setTimeout(() => {
        console.log("JOINED " + topic);
        setTimeout(() => { sock.write(closeFrame()); sock.end(); },
                   holdSecs * 1000);
      }, 400);
    }, 300);
  }
});
sock.on("close", () => { console.log("LEFT " + topic); });
sock.on("error", (e) => { console.error("WS_ERR", e.message); process.exit(1); });
JS

redis_cli() { docker exec -i "${REDIS}" redis-cli "$@"; }

# Query a node's presence endpoint IN-NETWORK (so we hit the node by its
# container name, proving it is a DIFFERENT process than the one the client
# joined). Prints the JSON body. $1=node container  $2=topic
presence_query() { # → JSON
  docker run --rm --network "${NET}" "${NODE_IMAGE}" \
    node -e '
      const http = require("http");
      const url = "http://" + process.argv[1] + ":4000/v1/presence?topic=" +
                  encodeURIComponent(process.argv[2]);
      http.get(url, (res) => {
        let b = ""; res.on("data", (c) => b += c);
        res.on("end", () => { process.stdout.write(b); });
      }).on("error", (e) => { console.error(e.message); process.exit(1); });
    ' "$1" "$2"
}

# Count members whose user_id == USER_A in a presence JSON body for assertions.
count_member() { # $1=json  → integer
  # Parse with jq host-side: this is a Docker-first box with NO host `node` (the
  # WS client + presence query already run in node CONTAINERS). Count members
  # whose user_id == USER_A; malformed/empty JSON → empty output (callers compare
  # the result to an integer, so empty correctly fails the assertion).
  printf '%s' "$1" | jq -r --arg want "${USER_A}" \
    '[.members[]? | select(.user_id == $want)] | length' 2>/dev/null
}

# Run the long-lived WS client (detached) against $1 for topic $2; capture its
# stdout to $3 so the caller can poll for JOINED / LEFT. Returns the docker
# container name so the caller can wait/stop it.
WSC_SEQ=0
start_ws() { # $1=node  $2=topic  $3=outfile  $4=hold_secs
  WSC_SEQ=$((WSC_SEQ + 1))
  local name="m97-wsc-${WSC_SEQ}-$$"
  docker run -d --name "${name}" --network "${NET}" \
    -e RT_HOST="$1" -e TOPIC="$2" -e TOKEN="${USER_A}" -e HOLD_SECS="${4:-8}" \
    -v "${WSCLIENT}":/wsclient.js:ro \
    "${NODE_IMAGE}" node /wsclient.js >/dev/null
  echo "${name}"
}

wait_substr() { # $1=container  $2=needle  $3=tries
  local i
  for i in $(seq 1 "${3:-40}"); do
    docker logs "$1" 2>&1 | grep -q "$2" && return 0
    sleep 0.25
  done
  return 1
}

wait_http() { # $1=container  $2=port  $3=path
  local i
  for i in $(seq 1 60); do
    curl -fsS -o /dev/null "http://127.0.0.1:$2$3" 2>/dev/null && return 0
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -15; return 1; }
    sleep 0.5
  done
  red "$1 never became ready:"; docker logs "$1" 2>&1 | tail -15; return 1
}

# ── 0) build the scratch realtime-server image FROM CURRENT SOURCE ──────────────
step "0/7 build scratch realtime-server from CURRENT source (A5 shared presence)"
DOCKER_BUILDKIT=1 docker build -q -f "${RT_DIR}/Dockerfile" -t "${RT_IMG}" "${RT_DIR}" >/dev/null \
  || fail "scratch realtime-server image build failed — gate must exercise the drafted shared-presence backend (line: docker build RT)"
ok "scratch image built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated network + redis ────────────────────────────────────────────────
step "1/7 boot isolated network (${NET}) + redis (${REDIS})"
docker network create "${NET}" >/dev/null
docker run -d --name "${REDIS}" --network "${NET}" "${REDIS_IMAGE}" >/dev/null
for i in $(seq 1 60); do redis_cli PING 2>/dev/null | grep -q PONG && break; [[ $i -eq 60 ]] && fail "scratch redis never answered PING (line: redis ready)"; sleep 0.5; done
ok "redis up"

# ── 2) (A)+(R) boot TWO nodes with shared presence ON, same redis ──────────────
step "2/7 boot node A + node B (REALTIME_PRESENCE_SHARED=1, shared ${REDIS_INNET}, prefix ${PREFIX})"
for spec in "${RT_A_ON} ${RT_PORT_A_ON}" "${RT_B_ON} ${RT_PORT_B_ON}"; do
  # shellcheck disable=SC2086  # deliberate split: "<name> <port>" → $1 $2
  set -- ${spec}
  docker run -d --name "$1" --network "${NET}" \
    -e REALTIME_PRESENCE_SHARED=1 \
    -e REALTIME_PRESENCE_REDIS_URL="${REDIS_INNET}" \
    -e REALTIME_PRESENCE_PREFIX="${PREFIX}" \
    -e REALTIME_PORT=4000 \
    -e RUST_LOG=info \
    -p "127.0.0.1:$2:4000" "${RT_IMG}" >/dev/null
done
wait_http "${RT_A_ON}" "${RT_PORT_A_ON}" "/v1/health" || fail "node A (ON) not ready (line: wait_http RT_A_ON)"
wait_http "${RT_B_ON}" "${RT_PORT_B_ON}" "/v1/health" || fail "node B (ON) not ready (line: wait_http RT_B_ON)"
for n in "${RT_A_ON}" "${RT_B_ON}"; do
  docker logs "${n}" 2>&1 | grep -q "cross-node presence ON" \
    || { red "${n} logs:"; docker logs "${n}" 2>&1 | tail -15; fail "${n} did not announce cross-node presence ON (line: ${n} announce)"; }
done
ok "both nodes up with shared presence ON (A:${RT_PORT_A_ON}, B:${RT_PORT_B_ON})"

# ── 3) (A) POSITIVE — join channel X on node A, query node B ────────────────────
step "3/7 (A) POSITIVE — client joins ${CH_X} on node A; query node B for ${CH_X}"
WSC_A="$(start_ws "${RT_A_ON}" "${CH_X}" "" 8)"
wait_substr "${WSC_A}" "JOINED" 40 \
  || { red "ws client logs:"; docker logs "${WSC_A}" 2>&1 | tail -15; fail "client never joined ${CH_X} on node A (line: A JOINED)"; }
# Member is now in Redis; query the OTHER node (B) by container name.
JB="$(presence_query "${RT_B_ON}" "${CH_X}")"
echo "    node B /v1/presence?topic=${CH_X} → ${JB}"
NB="$(count_member "${JB}")"
[[ "${NB}" == "1" ]] \
  || fail "(A) node B did NOT list the member that joined node A — got count='${NB}' body='${JB}' (line: A cross-node count != 1)"
ok "(A) member joined on node A is visible on node B — cross-node merge proven"

# ── 4) (R1) LOAD-BEARING REJECT — no cross-channel leak ────────────────────────
step "4/7 (R1) REJECT — member is in ${CH_X}, query node B for the DECOY ${CH_Y}"
JY="$(presence_query "${RT_B_ON}" "${CH_Y}")"
echo "    node B /v1/presence?topic=${CH_Y} → ${JY}"
NY="$(count_member "${JY}")"
[[ "${NY}" == "0" ]] \
  || fail "(R1) CROSS-CHANNEL LEAK — a member in ${CH_X} surfaced in a query for ${CH_Y} (count='${NY}' body='${JY}') (line: R1 leak)"
ok "(R1) member in channel X is NOT visible in channel Y — no cross-channel leak"

# ── 5) (R2) LOAD-BEARING REJECT — leave on A removes from B ─────────────────────
step "5/7 (R2) REJECT — client leaves ${CH_X} on node A (close); query node B again"
docker stop "${WSC_A}" >/dev/null 2>&1 || true   # triggers the real disconnect path on node A
wait_substr "${WSC_A}" "LEFT" 20 || true          # best-effort; stop forces close regardless
# Poll node B until the member is gone (allow the disconnect + Redis HDEL to land).
GONE=0
for i in $(seq 1 40); do
  JBL="$(presence_query "${RT_B_ON}" "${CH_X}")"
  NBL="$(count_member "${JBL}")"
  if [[ "${NBL}" == "0" ]]; then GONE=1; break; fi
  sleep 0.5
done
echo "    node B /v1/presence?topic=${CH_X} (after leave) → ${JBL}"
[[ "${GONE}" == "1" ]] \
  || fail "(R2) leave on node A did NOT remove the member from node B — still count='${NBL}' body='${JBL}' (line: R2 leave not propagated)"
ok "(R2) leave on node A removed the member from node B — cross-node leave proven"
docker rm -f "${WSC_A}" >/dev/null 2>&1 || true

# ── 6) (P) FLAG-OFF PARITY — OFF on both nodes ⇒ B does NOT see A, A sees itself ─
step "6/7 (P) PARITY — STOP+REMOVE the ON nodes, FLUSH redis, boot OFF nodes"
# A flag-OFF parity arm MUST remove the ENABLED containers + wipe shared state
# first, else node B could answer from Redis populated by the ON arm.
docker rm -fv "${RT_A_ON}" "${RT_B_ON}" >/dev/null 2>&1 || true
redis_cli FLUSHALL >/dev/null 2>&1 || true
RKEYS="$(redis_cli --scan --pattern "${PREFIX}:*" 2>/dev/null | wc -l | tr -d '[:space:]')"
[[ "${RKEYS}" == "0" ]] || fail "(P) redis presence namespace not clean before parity arm (keys=${RKEYS}) (line: P redis dirty)"

for spec in "${RT_A_OFF} ${RT_PORT_A_OFF}" "${RT_B_OFF} ${RT_PORT_B_OFF}"; do
  # shellcheck disable=SC2086  # deliberate split: "<name> <port>" → $1 $2
  set -- ${spec}
  # REALTIME_PRESENCE_SHARED UNSET = today's proven baseline (no shared store).
  docker run -d --name "$1" --network "${NET}" \
    -e REALTIME_PORT=4000 \
    -e RUST_LOG=info \
    -p "127.0.0.1:$2:4000" "${RT_IMG}" >/dev/null
done
wait_http "${RT_A_OFF}" "${RT_PORT_A_OFF}" "/v1/health" || fail "(P) node A (OFF) not ready (line: wait_http RT_A_OFF)"
wait_http "${RT_B_OFF}" "${RT_PORT_B_OFF}" "/v1/health" || fail "(P) node B (OFF) not ready (line: wait_http RT_B_OFF)"
# With the flag OFF the server must NOT announce cross-node presence ON.
for n in "${RT_A_OFF}" "${RT_B_OFF}"; do
  docker logs "${n}" 2>&1 | grep -q "cross-node presence ON" \
    && fail "(P) ${n} announced cross-node presence ON with the flag UNSET — NOT parity (line: P announce leak)"
done
ok "(P) both OFF nodes up, no cross-node announce (A:${RT_PORT_A_OFF}, B:${RT_PORT_B_OFF})"

step "6b/7 (P) join ${CH_X} on OFF node A; query OFF node B (must NOT see) + OFF node A (must see locally)"
WSC_A2="$(start_ws "${RT_A_OFF}" "${CH_X}" "" 8)"
wait_substr "${WSC_A2}" "JOINED" 40 \
  || { red "ws client logs:"; docker logs "${WSC_A2}" 2>&1 | tail -15; fail "(P) client never joined ${CH_X} on OFF node A (line: P JOINED)"; }
# Node B (a different node) must NOT see node A's member — single-node baseline.
JPB="$(presence_query "${RT_B_OFF}" "${CH_X}")"
echo "    OFF node B /v1/presence?topic=${CH_X} → ${JPB}"
NPB="$(count_member "${JPB}")"
[[ "${NPB}" == "0" ]] \
  || fail "(P) PARITY BROKEN — OFF node B saw node A's member (count='${NPB}' body='${JPB}'); the flag-OFF baseline must NOT merge (line: P B sees A)"
# But node A itself must still list the member LOCALLY — presence still works.
JPA="$(presence_query "${RT_A_OFF}" "${CH_X}")"
echo "    OFF node A /v1/presence?topic=${CH_X} → ${JPA}"
NPA="$(count_member "${JPA}")"
[[ "${NPA}" == "1" ]] \
  || fail "(P) OFF node A did NOT list its OWN member locally (count='${NPA}' body='${JPA}'); presence must still work single-node (line: P A self)"
# And NO presence keys were written to Redis (no shared store opened at all).
RKEYS2="$(redis_cli --scan --pattern "${PREFIX}:*" 2>/dev/null | wc -l | tr -d '[:space:]')"
[[ "${RKEYS2}" == "0" ]] \
  || fail "(P) PARITY BROKEN — OFF nodes wrote ${RKEYS2} presence key(s) to redis (expected 0; no shared store when OFF) (line: P redis writes)"
docker rm -f "${WSC_A2}" >/dev/null 2>&1 || true
ok "(P) OFF: node B does NOT see node A (single-node), node A sees itself, ZERO redis writes = byte-parity"

# ── 7) done ────────────────────────────────────────────────────────────────────
step "7/7 all A5 cross-node presence assertions hold"
green "[M97] (A) join on node A → visible on node B (cross-node merge through shared redis)"
green "[M97] (R1) member in channel X NOT in channel Y (no cross-channel leak)"
green "[M97] (R2) leave on node A → removed from node B (cross-node leave)"
green "[M97] (P) flag OFF → node B does NOT see node A, node A sees itself, 0 redis writes (byte-parity)"
green "[M97] ALL GATES GREEN — cross-node presence merge works ON; single-node byte-parity OFF"

step "record PASS to the agent log"
if [[ -f "${LOG_SH}" ]]; then
  # shellcheck disable=SC1090
  ( . "${LOG_SH}" \
      && AGENT_ROLE="tester" AGENT_TASK="m97-presence-crossnode" \
         log_event REPORT --outcome PASS --gate m97=PASS \
         --ref "scripts/verify/m97-presence-crossnode.sh" \
         --msg "A5 cross-node presence: join on node A visible on node B via shared redis; no cross-channel leak; leave propagates; OFF=byte-parity (B blind to A, A local-only, 0 redis writes)" \
  ) 2>/dev/null || red "[M97] (note) log.sh helper present but log_event failed — gate result still PASS"
else
  red "[M97] (note) ${LOG_SH} not found — skipping agent-log PASS record (gate result still PASS)"
fi
green "[M97] DONE"
