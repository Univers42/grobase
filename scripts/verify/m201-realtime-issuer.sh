#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m201-realtime-issuer.sh — realtime accepts only listed token issuers (M-4). #
#                                                                              #
#  Every token minter shares one HMAC secret, and realtime did not look at     #
#  `iss`: any same-secret token (an OTP proof, a bridge token, a token with    #
#  no issuer at all) opened a realtime session. Realtime now takes a comma-    #
#  separated REALTIME_JWT_ISSUER allow-list and, once it is set, refuses a     #
#  token without `iss` (REALTIME_JWT_ALLOW_NO_ISSUER=1 opts out).              #
#                                                                              #
#    (1) the rendered compose gives realtime the SAME GoTrue issuer that       #
#        GoTrue stamps, plus `supabase` and `grobase-realtime`                 #
#    (2) live, against the running realtime: a token from each listed issuer  #
#        gets AUTH_OK; a foreign issuer and a token with no `iss` are refused  #
#  The secret and the list are read from the realtime container's own env     #
#  and never printed. Needs the stack up with realtime built from this tree.   #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RT=mini-baas-realtime
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M201] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M201] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

# rt_env NAME prints one variable from the realtime container's env.
rt_env() { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${RT}" | sed -n "s/^$1=//p"; }

# auth_result ISS prints AUTH_OK or the refusal code for a fresh token with that
# `iss` ("-" = no `iss` claim), sent to realtime's /ws on its own network.
auth_result() {
  docker run --rm --network "${NET}" -e RT_SECRET -e TOKEN_ISS="$1" node:22-alpine node -e '
const { createHmac } = require("node:crypto");
const b64u = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const claims = { sub: "m201", exp: Math.floor(Date.now() / 1000) + 300, namespaces: ["m201"] };
if (process.env.TOKEN_ISS !== "-") claims.iss = process.env.TOKEN_ISS;
const unsigned = `${b64u({ alg: "HS256", typ: "JWT" })}.${b64u(claims)}`;
const token = `${unsigned}.${createHmac("sha256", process.env.RT_SECRET).update(unsigned).digest("base64url")}`;
const ws = new WebSocket("ws://mini-baas-realtime:4000/ws");
setTimeout(() => { console.log("TIMEOUT"); process.exit(0); }, 8000);
ws.onopen = () => ws.send(JSON.stringify({ type: "AUTH", token }));
ws.onmessage = (e) => { const m = JSON.parse(e.data); console.log(m.type === "AUTH_OK" ? "AUTH_OK" : (m.code ?? m.type)); process.exit(0); };
ws.onerror = () => { console.log("WS_ERROR"); process.exit(0); };' 2>/dev/null | tail -n1
}

step "0/2 preconditions — realtime running with a JWT secret"
docker inspect -f '{{.State.Running}}' "${RT}" 2>/dev/null | grep -qx true || fail "${RT} is not running (make up)"
NET="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "${RT}" | awk '{print $1}')"
RT_SECRET="$(rt_env REALTIME_JWT_SECRET)"
export RT_SECRET
[ -n "${RT_SECRET}" ] || fail "realtime has no REALTIME_JWT_SECRET (it would run NoAuth)"
LIST="$(rt_env REALTIME_JWT_ISSUER)"
[ -n "$(rt_env REALTIME_JWT_ALLOW_NO_ISSUER)" ] && fail "REALTIME_JWT_ALLOW_NO_ISSUER is set on ${RT}; unset it to run this gate"
ok "realtime up on ${NET}; issuer list has $(tr ',' '\n' <<<"${LIST}" | grep -c .) entries"

step "1/2 compose — realtime's list starts with GoTrue's own issuer"
cd "${ROOT}" || exit 1
RENDERED="$(docker compose --profile realtime --profile data-plane config 2>/dev/null)" || fail "docker compose config failed"
GOTRUE_ISS="$(sed -n 's/^ *GOTRUE_JWT_ISSUER: //p' <<<"${RENDERED}" | head -n1)"
RT_ISS="$(sed -n 's/^ *REALTIME_JWT_ISSUER: //p' <<<"${RENDERED}" | head -n1)"
[ -n "${GOTRUE_ISS}" ] || fail "compose renders no GOTRUE_JWT_ISSUER"
[ "${RT_ISS}" = "${GOTRUE_ISS},supabase,grobase-realtime" ] ||
  fail "REALTIME_JWT_ISSUER is not '<GoTrue issuer>,supabase,grobase-realtime'"
[ "${LIST}" = "${RT_ISS}" ] || fail "running realtime's list differs from the rendered compose (rebuild/recreate realtime)"
ok "REALTIME_JWT_ISSUER = GoTrue issuer + supabase + grobase-realtime, live and rendered"

step "2/2 live — listed issuers pass, foreign and missing issuers are refused"
for iss in "${GOTRUE_ISS}" supabase grobase-realtime; do
  got="$(auth_result "${iss}")"
  [ "${got}" = AUTH_OK ] || fail "iss '${iss}' was refused (${got})"
done
ok "GoTrue, supabase and grobase-realtime tokens: AUTH_OK"
for iss in osionos-bridge -; do
  got="$(auth_result "${iss}")"
  [ "${got}" = AUTH_FAILED ] || fail "iss '${iss}' expected AUTH_FAILED, got ${got}"
done
ok "foreign issuer and no-iss tokens: AUTH_FAILED"

printf '\033[0;32m[M201] PASS — realtime accepts only listed issuers and refuses tokens without one\033[0m\n'
