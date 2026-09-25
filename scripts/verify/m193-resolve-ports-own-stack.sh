#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m193-resolve-ports-own-stack.sh — `make up` on a live stack must not move   #
#  the stack's own ports, and must still avoid everybody else's                #
#                                                                              #
#  resolve-ports.sh asked `ss` whether each default port was listening, and    #
#  the stack's own running Kong counts as "listening". So `make up` on a live  #
#  stack relocated Kong 8000->8001 and the WAF 8443->8444 / 8880->8881, while  #
#  every client, tunnel and verifier still dialled the old ports -- measured   #
#  on 2026-09-23, and the reason "never run make up on a live stack" was an    #
#  operator rule (issue #19). A port published by a container of THIS compose #
#  project is now treated as free: `up` reuses or frees it.                    #
#                                                                              #
#  Two throwaway containers that only publish a free port:                     #
#    1 held by a container labelled as this project  -> the port is KEPT      #
#    2 held by a container of another project        -> the port is BUMPED    #
#                                                                              #
#  Mutant: M193_SCRIPT=<the previous resolve-ports.sh> keeps nothing: case 1   #
#  gets bumped and this gate goes red.                                        #
# **************************************************************************** #
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TOOL="${M193_SCRIPT:-${ROOT}/scripts/ops/resolve-ports.sh}"
IMG="${M193_IMAGE:-curlimages/curl:latest}"
OWN="m193own$$"
C="m193-holder-$$"
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M193] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M193] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}
trap 'docker rm -f "${C}" >/dev/null 2>&1 || true' EXIT

step "0/2 a free port to hold"
command -v docker >/dev/null 2>&1 || fail "docker is required"
command -v ss >/dev/null 2>&1 || fail "ss is required (iproute2)"
docker image inspect "${IMG}" >/dev/null 2>&1 || docker pull -q "${IMG}" >/dev/null || fail "cannot get ${IMG}"
P=""
for cand in $(seq 18600 18699); do
  ss -tlnH | awk '{print $4}' | grep -qE "(:|^)${cand}$" || {
    P="${cand}"
    break
  }
done
[ -n "${P}" ] || fail "no free port in 18600-18699"
ok "port ${P}"

resolved() { # <project> -> the port resolve-ports hands KONG_HTTP_PORT when asked for $P
  local out
  out=$(COMPOSE_PROJECT_NAME="$1" KONG_HTTP_PORT="${P}" bash "${TOOL}" 2>/dev/null)
  printf '%s\n' "${out}" | sed -n 's/^export KONG_HTTP_PORT=//p'
}
hold() { # <project label>
  docker rm -f "${C}" >/dev/null 2>&1 || true
  docker run -d --name "${C}" --label "com.docker.compose.project=$1" -p "127.0.0.1:${P}:80" \
    --entrypoint sleep "${IMG}" 300 >/dev/null
  for _ in $(seq 1 10); do
    ss -tlnH | awk '{print $4}' | grep -qE ":${P}$" && return 0
    sleep 1
  done
  fail "the holder never published ${P}"
}

step "1/2 held by this project -> kept"
hold "${OWN}"
got=$(resolved "${OWN}")
[ "${got}" = "${P}" ] || fail "port ${P} held by this project's own container was moved to ${got:-?}: \`make up\` on a live stack would relocate the stack"
ok "KONG_HTTP_PORT stays ${P}"

step "2/2 held by another project -> bumped"
hold "someone-else-$$"
got=$(resolved "${OWN}")
[ -n "${got}" ] && [ "${got}" != "${P}" ] || fail "port ${P} held by ANOTHER project was not avoided (got ${got:-?})"
ok "KONG_HTTP_PORT moves to ${got}"
