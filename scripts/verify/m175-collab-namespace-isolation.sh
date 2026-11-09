#!/usr/bin/env bash
# ============================================================
# m175 — Protected-namespace isolation (collab: spaces)
#
# Closes the realtime gap where a wildcard / namespace-less token (granted
# `["*"]` by the permissive fallback or the NoAuth provider) could SUBSCRIBE to
# any `collab:<spaceId>` topic — reading a Shared space it was never added to.
#
# Fix (flag-gated, REALTIME_PROTECTED_NAMESPACES, default EMPTY = byte-parity):
# a `"*"` grant no longer covers a protected-prefix namespace; reaching it needs
# an EXACT namespace grant. Collab members already present `["collab:<id>"]`
# scoped tokens (minted by the membership-gated bridge), so they are unaffected;
# everyone else loses wildcard reach into `collab:` ONLY (chat/feed/live-DB keep
# their wildcard, so there is NO breaking global deny flip).
#
# This gate exercises the authorization decision directly via the realtime-core
# unit test (the pure can_subscribe_to_scoped / can_publish_to_scoped logic),
# plus the byte-parity tests that prove an empty protected list is unchanged.
#
# LIVE (BAAS_VERIFY_LIVE=1, a running stack with realtime built from this tree):
# realtime is recreated with REALTIME_PROTECTED_NAMESPACES=collab: for this run
# only; a wildcard token gets no SUBSCRIBED for collab:<space> but does for chat:,
# an exact collab:<space> grant does; recreated without the flag, the wildcard
# reaches collab: again (parity), and realtime is left that way.
# M175_SKIP_STATIC=1 skips the cargo leg when another job already ran it.
#
# Ponytail: realtime answers a denied SUBSCRIBE with silence, so "denied" is "no
# SUBSCRIBED within 4 s". A realtime too slow to answer an allowed one reads as
# denied (the allowed cases in the same run would fail first and name it).
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RT="$ROOT/infra/docker/services/realtime/realtime-agnostic"
IMG="${M175_TOOLCHAIN:-mini-baas-rust-toolchain}"
ok() { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
fail() {
  printf '  \033[1;31m✗ %s\033[0m\n' "$*" >&2
  exit 1
}

printf '\033[1m── m175: protected-namespace isolation (collab:) ──\033[0m\n'

if [ "${M175_SKIP_STATIC:-0}" != "1" ]; then
  # M175_TOOLCHAIN names a stock Rust image to use instead of building the local one.
  [ -n "${M175_TOOLCHAIN:-}" ] || docker image inspect "$IMG" >/dev/null 2>&1 ||
    make -C "$ROOT" _rust-toolchain >/dev/null

  CARGO="docker run --rm -v $RT:/work -w /work \
    -v mini-baas-cargo-registry:/usr/local/cargo/registry \
    -v mini-baas-cargo-git:/usr/local/cargo/git \
    -v mini-baas-realtime-target:/work/target $IMG cargo"

  $CARGO test -p realtime-core protected_namespace_excludes_wildcard 2>&1 | tail -3 |
    grep -qE '1 passed' || fail "protected-prefix wildcard exclusion test failed"
  ok "wildcard token cannot reach a protected collab: namespace; exact grant still can"

  $CARGO test -p realtime-core auth_claims 2>&1 | tail -3 |
    grep -qE '[2-9] passed|[0-9]{2,} passed' || fail "byte-parity auth_claims tests regressed"
  ok "empty protected list is byte-parity (existing subscribe/deny semantics unchanged)"
fi

# ── live: the running realtime, flag ON for this run, then back to parity ────
RTC=mini-baas-realtime
rt_env() { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${RTC}" | sed -n "s/^$1=//p"; }

# subscribe_result NAMESPACES TOPIC prints SUBSCRIBED, DENIED (no answer in 4 s)
# or the refusal code, for a fresh grobase-realtime token granting NAMESPACES.
subscribe_result() {
  docker run --rm --network "${NET}" -e RT_SECRET -e GRANT="$1" -e TOPIC="$2" node:22-alpine node -e '
const { createHmac } = require("node:crypto");
const b64u = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const claims = { sub: "m175", iss: "grobase-realtime", exp: Math.floor(Date.now() / 1000) + 300,
  namespaces: process.env.GRANT.split(","), can_subscribe: true, can_publish: false };
const unsigned = `${b64u({ alg: "HS256", typ: "JWT" })}.${b64u(claims)}`;
const token = `${unsigned}.${createHmac("sha256", process.env.RT_SECRET).update(unsigned).digest("base64url")}`;
const ws = new WebSocket("ws://mini-baas-realtime:4000/ws");
setTimeout(() => { console.log("TIMEOUT"); process.exit(0); }, 10000);
ws.onopen = () => ws.send(JSON.stringify({ type: "AUTH", token }));
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "AUTH_OK") {
    ws.send(JSON.stringify({ type: "SUBSCRIBE", sub_id: "m175", topic: process.env.TOPIC }));
    setTimeout(() => { console.log("DENIED"); process.exit(0); }, 4000);
    return;
  }
  if (m.type === "SUBSCRIBED") { console.log("SUBSCRIBED"); process.exit(0); }
  if (m.type === "ERROR") { console.log(m.code); process.exit(0); }
};
ws.onerror = () => { console.log("WS_ERROR"); process.exit(0); };' 2>/dev/null | tail -n1
}

# recreate_realtime VALUE recreates realtime (no build) with the protected list
# set to VALUE ("" = the default) and waits for it to be healthy.
recreate_realtime() {
  (cd "$ROOT" && REALTIME_PROTECTED_NAMESPACES="$1" docker compose -f docker-compose.yml up -d \
    --no-deps --no-build --wait realtime >/dev/null 2>&1) || fail "realtime did not come back healthy"
  [ "$(rt_env REALTIME_PROTECTED_NAMESPACES)" = "$1" ] || fail "realtime runs with REALTIME_PROTECTED_NAMESPACES != '$1'"
}

expect() { # GRANT TOPIC WANT WHAT
  local got
  got="$(subscribe_result "$1" "$2")"
  [ "${got}" = "$3" ] || fail "$4: expected $3, got ${got}"
  ok "live: $4 → $3"
}

if [ "${BAAS_VERIFY_LIVE:-0}" = "1" ]; then
  docker inspect -f '{{.State.Running}}' "${RTC}" 2>/dev/null | grep -qx true || fail "${RTC} is not running (make up)"
  NET="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "${RTC}" | awk '{print $1}')"
  RT_SECRET="$(rt_env REALTIME_JWT_SECRET)"
  export RT_SECRET
  [ -n "${RT_SECRET}" ] || fail "realtime has no REALTIME_JWT_SECRET (it would run NoAuth)"
  trap 'recreate_realtime ""' EXIT
  recreate_realtime "collab:"
  expect '*' 'collab:m175-space' DENIED "flag ON, wildcard token on collab:m175-space"
  expect '*' 'chat:m175' SUBSCRIBED "flag ON, wildcard token on chat:m175 (no global deny)"
  expect 'collab:m175-space' 'collab:m175-space' SUBSCRIBED "flag ON, exact collab:m175-space grant"
  recreate_realtime ""
  trap - EXIT
  expect '*' 'collab:m175-space' SUBSCRIBED "flag OFF, wildcard token on collab:m175-space (parity)"
fi

printf '\033[1;32mm175 PASS\033[0m — collab: spaces are isolated from wildcard tokens (flag-gated, default OFF)\n'
