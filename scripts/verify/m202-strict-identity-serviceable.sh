#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m202-strict-identity-serviceable.sh — IDENTITY_HEADER_MODE=strict is         #
#  serviceable for real traffic (H-19).                                        #
#                                                                              #
#  Production stayed on `compat` because only the api-key route could produce  #
#  an identity strict accepts: ApiKeyMiddleware self-signs an envelope, and it  #
#  is mounted on query-router alone. Every other Nest service saw only the raw  #
#  X-User-* headers Kong derives from the JWT, which strict rejects — so the    #
#  flip would have 401'd legitimate traffic. resolveRequestIdentity now has a   #
#  bearer-JWT rung, and THIS gate is what licenses the flip:                   #
#                                                                              #
#    (1) the rendered compose gives every service that verifies a user token    #
#        the same GOTRUE_JWT_ISSUER that GoTrue stamps                          #
#    (2) live, a strict storage-router accepts a real GoTrue session, while a   #
#        raw X-User-Id with no token, a cross-app realtime token (whose `sub`  #
#        is a tenant slug) and a token signed with the wrong secret are all     #
#        refused — and the same raw header IS accepted by the compat instance,  #
#        so its 401 is the mode at work, not a broken probe                     #
#                                                                              #
#  The strict instance is a second process started INSIDE the running          #
#  storage-router container with only IDENTITY_HEADER_MODE and PORT            #
#  overridden, so it runs the deployed image with the deployed env and the     #
#  stack itself stays compat. Tokens are signed and probes sent from inside    #
#  that container too, so JWT_SECRET never leaves the process that holds it.   #
#  storage-router is the subject on purpose: it has no signer of its own, so   #
#  it is where strict is hardest. Needs the stack up (`make up`) with          #
#  storage-router built from this tree and recreated from the current compose. #
#                                                                              #
#  Ponytail: one service stands in for the Nest fleet. They share             #
#  resolveRequestIdentity from libs/common, so a service that wires its own    #
#  guard instead would pass here and still 401 in strict — grep for guards    #
#  that bypass the library before trusting this for a service not listed.     #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SR=mini-baas-storage-router
STRICT_PORT=3099
MAIN=dist/apps/storage-router/apps/storage-router/src/main.js
RUNG=dist/apps/storage-router/libs/common/src/identity/user-jwt.js
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M202] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M202] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

# sr_env NAME prints one NON-secret variable from the container's env.
sr_env() { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${SR}" | sed -n "s/^$1=//p"; }

# sr_has NAME succeeds when the container's env sets NAME, without reading it.
sr_has() { docker exec "${SR}" sh -c "[ -n \"\${$1:-}\" ]"; }

# start_sidecar runs a strict storage-router on STRICT_PORT inside the
# container and waits for it to listen; exec keeps the pid file honest.
start_sidecar() {
  docker exec -d -e IDENTITY_HEADER_MODE=strict -e PORT="${STRICT_PORT}" "${SR}" \
    sh -c "echo \$\$ >/tmp/m202.pid; exec node ${MAIN} >/tmp/m202.log 2>&1"
  for _ in $(seq 1 30); do
    docker exec "${SR}" grep -q "listening on :${STRICT_PORT}" /tmp/m202.log 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

# stop_sidecar kills the strict process and removes its files; PID 1 is untouched.
stop_sidecar() {
  docker exec "${SR}" sh -c '[ -f /tmp/m202.pid ] && kill "$(cat /tmp/m202.pid)"; rm -f /tmp/m202.pid /tmp/m202.log' \
    >/dev/null 2>&1 || true
}

# run_probes signs up a GoTrue user and sends every case to both the strict
# sidecar and the compat instance, from inside the container. Prints one
# "<case> <port> <status>" line per probe and never prints a token.
run_probes() {
  docker exec -e STRICT_PORT="${STRICT_PORT}" "${SR}" node -e '
const crypto = require("node:crypto");
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const sign = (claims, key) => {
  const h = b64({ alg: "HS256", typ: "JWT" }), p = b64(claims);
  return `${h}.${p}.${crypto.createHmac("sha256", key).update(`${h}.${p}`).digest("base64url")}`;
};
const claims = (sub, iss) => ({ sub, iss, role: "authenticated", exp: Math.floor(Date.now() / 1000) + 300 });
(async () => {
  const su = await fetch("http://gotrue:9999/signup", {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ email: `m202-${Date.now()}@grobase.local`, password: "M202-probe#2026" }),
  });
  const session = (await su.json()).access_token;
  if (!session) return console.log(`signup none ${su.status}`);
  const cases = {
    session: { authorization: `Bearer ${session}` },
    raw: { "x-user-id": "00000000-0000-4000-8000-0000000000ff", "x-baas-tenant-id": "m202" },
    xapp: { authorization: `Bearer ${sign(claims("victim-tenant", "grobase-realtime"), process.env.JWT_SECRET)}` },
    wrongsecret: { authorization: `Bearer ${sign(claims("m202-forged", process.env.GOTRUE_JWT_ISSUER), crypto.randomBytes(32))}` },
  };
  for (const [name, headers] of Object.entries(cases)) {
    for (const port of [process.env.STRICT_PORT, "3040"]) {
      const r = await fetch(`http://127.0.0.1:${port}/storage/v1/bucket`, { headers });
      console.log(`${name} ${port} ${r.status}`);
    }
  }
})().catch((e) => console.log(`error ${e.message}`));' 2>&1
}

# status CASE PORT prints the recorded HTTP status for one probe.
status() { sed -n "s/^$1 $2 //p" <<<"${OUT}"; }

step "0/2 preconditions — storage-router is current and can verify a user token"
docker inspect -f '{{.State.Running}}' "${SR}" 2>/dev/null | grep -qx true || fail "${SR} is not running (make up)"
docker exec "${SR}" test -f "${RUNG}" ||
  fail "${SR}'s image predates the bearer-JWT rung (no ${RUNG}); rebuild it: docker compose build storage-router && make up"
[ -n "$(sr_env GOTRUE_JWT_ISSUER)" ] ||
  fail "${SR} has no GOTRUE_JWT_ISSUER — it was created from an older compose; recreate it (make up)"
[ -n "$(sr_env JWT_ALLOW_NO_ISSUER)" ] && fail "JWT_ALLOW_NO_ISSUER is set on ${SR}; unset it to run this gate"
sr_has JWT_SECRET || fail "${SR} has no JWT_SECRET, so it can verify no user token"
ok "storage-router carries the rung, a pinned issuer and a JWT secret"

step "1/2 compose — every user-token verifier shares GoTrue's issuer"
cd "${ROOT}" || exit 1
RENDERED="$(docker compose --profile adapter-plane --profile auth-api --profile storage config 2>/dev/null)" ||
  fail "docker compose config failed"
GOTRUE_ISS="$(sed -n 's/^ *GOTRUE_JWT_ISSUER: //p' <<<"${RENDERED}" | sort -u)"
[ -n "${GOTRUE_ISS}" ] || fail "compose renders no GOTRUE_JWT_ISSUER at all"
[ "$(wc -l <<<"${GOTRUE_ISS}")" -eq 1 ] ||
  fail "services disagree on GOTRUE_JWT_ISSUER; a token one mints would not verify at another"
VERIFIERS="$(grep -c '^ *GOTRUE_JWT_ISSUER: ' <<<"${RENDERED}")"
[ "${VERIFIERS}" -ge 3 ] || fail "only ${VERIFIERS} service(s) carry GOTRUE_JWT_ISSUER; expected the Nest set"
ok "${VERIFIERS} services share one issuer: ${GOTRUE_ISS}"

step "2/2 live — strict accepts a real session and refuses everything else"
stop_sidecar
trap stop_sidecar EXIT
start_sidecar || fail "the strict instance never listened on :${STRICT_PORT} (see /tmp/m202.log in ${SR})"
OUT="$(run_probes)"
grep -q '^signup none' <<<"${OUT}" && fail "GoTrue signup returned no session (${OUT#signup none })"
grep -q '^error' <<<"${OUT}" && fail "probe crashed: ${OUT#error }"

case "$(status session "${STRICT_PORT}")" in
2*) ok "real GoTrue session → $(status session "${STRICT_PORT}") in strict" ;;
*) fail "a real GoTrue session got $(status session "${STRICT_PORT}") in strict — the flip is not serviceable" ;;
esac
case "$(status raw 3040)" in
2*) ;;
*) fail "the compat instance refused the raw header ($(status raw 3040)); the strict negative below would be vacuous" ;;
esac
[ "$(status raw "${STRICT_PORT}")" = 401 ] ||
  fail "a raw X-User-Id with no token got $(status raw "${STRICT_PORT}") in strict, expected 401"
ok "raw X-User-Id, no token → 401 in strict (compat: $(status raw 3040))"
[ "$(status xapp "${STRICT_PORT}")" = 401 ] ||
  fail "a cross-app realtime token got $(status xapp "${STRICT_PORT}"), expected 401 (its sub is a tenant slug)"
ok "cross-app realtime token (iss grobase-realtime) → 401"
[ "$(status wrongsecret "${STRICT_PORT}")" = 401 ] ||
  fail "a token signed with the wrong secret got $(status wrongsecret "${STRICT_PORT}"), expected 401"
ok "token signed with another secret → 401"

printf '\033[0;32m[M202] OK — strict identity mode is serviceable for real traffic\033[0m\n'
