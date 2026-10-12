#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m219-remote-access-overlay.sh — REMOTE_ACCESS publishes on the loopback,    #
#  only when asked                                                             #
#                                                                              #
#  A groot whose frontends run on another machine dials this stack through    #
#  an ssh LocalForward per plane. Kong, redis, tenant-control and the registry #
#  already publish on 127.0.0.1; realtime (4000) and mailpit SMTP (1025) did   #
#  not, so a tunnelled bridge published to a dead address and the gateway's   #
#  mail vanished, both silently (2026-10-10). The overlay fixes that and must  #
#  never grow into a network exposure:                                         #
#                                                                              #
#   LOOPBACK every published port in the overlay binds 127.0.0.1.             #
#   OPT-IN   DC gains the overlay only for REMOTE_ACCESS=1, read from the env  #
#            or .env.local; unset renders the plain compose command.           #
#   MUTANTS  each check refuses the way back in.                               #
#                                                                              #
#  Static only: no network, no stack, no credential read, no value printed.    #
#                                                                              #
# **************************************************************************** #
set -uo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OVERLAY="${ROOT}/orchestrators/compose/docker-compose.remote-access.yml"
CFG="${ROOT}/orchestrators/makes/00-config.mk"

_B=$'\033[0;36m' _G=$'\033[0;32m' _R=$'\033[0;31m' _0=$'\033[0m'
rc=0
step() { printf '%s[M219] %s%s\n' "${_B}" "$1" "${_0}"; }
ok() { printf '%s  ✓ %s%s\n' "${_G}" "$1" "${_0}"; }
fail() {
  printf '%s[M219] FAIL — %s%s\n' "${_R}" "$1" "${_0}"
  rc=1
}

for f in "${OVERLAY}" "${CFG}"; do
  [ -f "${f}" ] || {
    fail "missing ${f#"${ROOT}"/}"
    exit 1
  }
done

# loopback_ok <overlay>: every `- "host:guest"` publish line binds 127.0.0.1, and there is one.
loopback_ok() {
  local lines
  lines="$(grep -E '^\s+- "' "$1")"
  [ -n "${lines}" ] && ! printf '%s\n' "${lines}" | grep -qvE '^\s+- "127\.0\.0\.1:'
}

# dc_renders <cfg> <REMOTE_ACCESS value>: the compose command make builds for that value.
dc_renders() {
  (cd "${ROOT}" && make -s -f "$1" -f /dev/stdin show REMOTE_ACCESS="$2" <<<'show: ; @echo $(DC)' 2>/dev/null)
}
optin_ok() {
  dc_renders "$1" 1 | grep -q -- '-f orchestrators/compose/docker-compose.remote-access.yml' &&
    ! dc_renders "$1" "" | grep -q 'remote-access'
}
envlocal_ok() { grep -qE '^REMOTE_ACCESS\s+\?= \$\(shell sed -n .s/\^REMOTE_ACCESS=//p. \.env\.local' "$1"; }

loopback_arm() {
  step "LOOPBACK — every overlay publish binds 127.0.0.1"
  loopback_ok "${OVERLAY}" && ok "only 127.0.0.1:… publishes in the overlay" ||
    fail "the overlay publishes on a non-loopback address (or nothing at all)"
}

optin_arm() {
  step "OPT-IN — the overlay joins DC only for REMOTE_ACCESS=1"
  optin_ok "${CFG}" && ok "REMOTE_ACCESS=1 adds the overlay; unset leaves DC plain" ||
    fail "00-config.mk does not gate the overlay on REMOTE_ACCESS=1"
  envlocal_ok "${CFG}" && ok "REMOTE_ACCESS is read from .env.local when the env is silent" ||
    fail "00-config.mk does not read REMOTE_ACCESS from .env.local"
}

mutants_arm() {
  step "MUTANTS — each check refuses the way back in"
  local work ov cfg
  work="$(mktemp -d)" || return
  trap 'rm -rf "${work}"' RETURN
  ov="${work}/overlay.yml"
  cfg="${work}/00-config.mk"

  sed 's/"127\.0\.0\.1:\${REALTIME_HOST_PORT:-4000}:4000"/"0.0.0.0:4000:4000"/' "${OVERLAY}" >"${ov}"
  loopback_ok "${ov}" && fail "mutant survived: a 0.0.0.0 publish is not caught" ||
    ok "refused: realtime published on every interface"

  sed 's/"127\.0\.0\.1:\${MAILPIT_SMTP_PORT:-1025}:1025"/"1025:1025"/' "${OVERLAY}" >"${ov}"
  loopback_ok "${ov}" && fail "mutant survived: a bare host port is not caught" ||
    ok "refused: SMTP published with no bind address"

  sed 's/\$(if \$(filter 1,\$(REMOTE_ACCESS)), -f orchestrators\/compose\/docker-compose.remote-access.yml)//' "${CFG}" >"${cfg}"
  optin_ok "${cfg}" && fail "mutant survived: the overlay dropped from DC is not caught" ||
    ok "refused: REMOTE_ACCESS=1 no longer adds the overlay"

  sed 's/\$(if \$(filter 1,\$(REMOTE_ACCESS)), -f orchestrators\/compose\/docker-compose.remote-access.yml)/ -f orchestrators\/compose\/docker-compose.remote-access.yml/' "${CFG}" >"${cfg}"
  optin_ok "${cfg}" && fail "mutant survived: an always-on overlay is not caught" ||
    ok "refused: the overlay applied unconditionally"
}

loopback_arm
optin_arm
mutants_arm

if [ "${rc}" -eq 0 ]; then
  printf '%s[M219] PASS — the remote-access overlay publishes on the loopback, only when asked%s\n' "${_G}" "${_0}"
else
  printf '%s[M219] FAIL%s\n' "${_R}" "${_0}"
fi
exit "${rc}"
