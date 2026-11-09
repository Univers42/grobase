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
#  With --compose-json (the publishes compose will bind), a listener of       #
#  another project on 127.0.0.2:                                               #
#    3 the port is published on 127.0.0.1 only       -> KEPT (no clash)        #
#    4 the port is published on every interface      -> BUMPED                 #
#  Case 3 is the 2026-11-06 outage: tailscaled serving the VM's tailnet       #
#  address on :8443 moved a WAF bound to 127.0.0.1 + the guest address.       #
#                                                                              #
#  Mutant: M193_SCRIPT=<the previous resolve-ports.sh> keeps nothing: case 1   #
#  (or case 3) gets bumped and this gate goes red.                            #
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

step "0/4 a free port to hold"
command -v docker >/dev/null 2>&1 || fail "docker is required"
command -v ss >/dev/null 2>&1 || fail "ss is required (iproute2)"
# Retry the pull: a Docker Hub 502/429 is "come back later", not a defect in resolve-ports.
docker image inspect "${IMG}" >/dev/null 2>&1 ||
  RETRY_429_BASE_S="${M193_RETRY_BASE_S:-10}" \
    bash "$(dirname "$0")/../ci/retry-on-429.sh" docker pull -q "${IMG}" >/dev/null ||
  fail "cannot get ${IMG} (after retries — registry unreachable)"
P=""
for cand in $(seq 18600 18699); do
  grep -qE "(:|^)${cand}$" <<<"$(ss -tlnH | awk '{print $4}')" || {
    P="${cand}"
    break
  }
done
[ -n "${P}" ] || fail "no free port in 18600-18699"
ok "port ${P}"

resolved() { # <project> [host_ip] -> the port resolve-ports hands KONG_HTTP_PORT for $P
  local out
  if [ $# -gt 1 ]; then # the publish compose would bind: $2, or every interface when empty
    out=$(publish_json "$2" | COMPOSE_PROJECT_NAME="$1" KONG_HTTP_PORT="${P}" bash "${TOOL}" --compose-json 2>/dev/null)
  else
    out=$(COMPOSE_PROJECT_NAME="$1" KONG_HTTP_PORT="${P}" bash "${TOOL}" 2>/dev/null)
  fi
  printf '%s\n' "${out}" | sed -n 's/^export KONG_HTTP_PORT=//p'
}
publish_json() { # <host_ip or empty> -> a compose config with one kong publish of $P
  printf '{"services":{"kong":{"ports":[{"published":"%s","target":8000,"protocol":"tcp"%s}]}}}\n' \
    "${P}" "${1:+,\"host_ip\":\"$1\"}"
}
hold() { # <project label> [bind address, default 127.0.0.1]
  docker rm -f "${C}" >/dev/null 2>&1 || true
  docker run -d --name "${C}" --label "com.docker.compose.project=$1" -p "${2:-127.0.0.1}:${P}:80" \
    --entrypoint sleep "${IMG}" 300 >/dev/null
  for _ in $(seq 1 10); do
    grep -qE ":${P}$" <<<"$(ss -tlnH | awk '{print $4}')" && return 0
    sleep 1
  done
  fail "the holder never published ${P}"
}

step "1/4 held by this project -> kept"
hold "${OWN}"
got=$(resolved "${OWN}")
[ "${got}" = "${P}" ] || fail "port ${P} held by this project's own container was moved to ${got:-?}: \`make up\` on a live stack would relocate the stack"
ok "KONG_HTTP_PORT stays ${P}"

step "2/4 held by another project -> bumped"
hold "someone-else-$$"
got=$(resolved "${OWN}")
[ -n "${got}" ] && [ "${got}" != "${P}" ] || fail "port ${P} held by ANOTHER project was not avoided (got ${got:-?})"
ok "KONG_HTTP_PORT moves to ${got}"

step "3/4 another project on 127.0.0.2, this stack publishes on 127.0.0.1 -> kept"
command -v jq >/dev/null 2>&1 || fail "jq is required"
hold "someone-else-$$" 127.0.0.2
got=$(resolved "${OWN}" 127.0.0.1)
[ "${got}" = "${P}" ] || fail "a listener on 127.0.0.2 moved a publish bound to 127.0.0.1 only (got ${got:-?}): the WAF would leave 8443 whenever tailscaled serves the tailnet address"
ok "KONG_HTTP_PORT stays ${P}"

step "4/4 the same listener, this stack publishes on every interface -> bumped"
got=$(resolved "${OWN}" "")
[ -n "${got}" ] && [ "${got}" != "${P}" ] || fail "a wildcard publish of ${P} ignored the listener on 127.0.0.2 (got ${got:-?})"
ok "KONG_HTTP_PORT moves to ${got}"
