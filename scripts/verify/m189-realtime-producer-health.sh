#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m189-realtime-producer-health.sh — realtime must report unhealthy when its  #
#  PostgreSQL change feed is detached, and healthy again once it re-attaches   #
#                                                                              #
#  m184 made the LISTEN re-attach itself, and is_connected() existed, but      #
#  nothing read it: /v1/health answered "ok" and the container probe was a    #
#  bare TCP connect to :4000. A permanently broken producer (a rotated         #
#  password, a dropped database) logged an error every retry and still        #
#  reported healthy while no row change could reach any subscriber.           #
#                                                                              #
#  Now /v1/health lists every producer's attachment and answers 503 when one   #
#  is detached, and `realtime-server --healthcheck` asks that endpoint. This   #
#  gate runs the realtime image against a THROWAWAY PostgreSQL and requires:   #
#    1 PostgreSQL up       -> --healthcheck 0, /v1/health 200, attached true   #
#    2 PostgreSQL stopped  -> --healthcheck non-zero, /v1/health 503           #
#    3 PostgreSQL back     -> --healthcheck 0 again (the supervisor re-attached)#
#                                                                              #
#  Mutant: M189_IMAGE=<an image built before this change> -- its probe only    #
#  connects, so step 2 stays green and this gate goes red on it.               #
#                                                                              #
#  Own network and containers, removed by an EXIT trap; never touches a        #
#  mini-baas-* container. The realtime image defaults to the one compose       #
#  builds for this tree (`docker compose build realtime`).                     #
# **************************************************************************** #
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RT_IMAGE="${M189_IMAGE:-ghcr.io/univers42/grobase-realtime:latest}"
PG_IMAGE="${M189_PG_IMAGE:-postgres:16-alpine}"
CURL_IMAGE="${M189_CURL_IMAGE:-curlimages/curl:latest}"
NET="m189-net-$$"
PG="m189-pg-$$"
RT="m189-rt-$$"
PGPW="m189"
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M189] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M189] FAIL — %s\033[0m\n' "$*" >&2
  docker logs --tail 8 "${RT}" 2>&1 | sed 's/^/    rt| /' >&2 || true
  exit 1
}
cleanup() {
  docker rm -f "${RT}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cd "${ROOT}"

probe() { docker exec "${RT}" /app/realtime-server --healthcheck >/dev/null 2>&1; }
health() { # prints "<http code> <body>"
  docker run --rm --network "${NET}" "${CURL_IMAGE}" -s -m 3 -w '\n%{http_code}' "http://${RT}:4000/v1/health" 2>/dev/null |
    awk '{ body = (NR == 1 ? $0 : body) } END { print $0 " " body }'
}
wait_for() { # <seconds> <description> <command...>
  local n="$1" what="$2"
  shift 2
  while [ "${n}" -gt 0 ]; do
    "$@" && return 0
    sleep 2
    n=$((n - 2))
  done
  fail "timed out waiting for: ${what}"
}
probe_fails() { ! probe; }

step "0/3 preconditions"
command -v docker >/dev/null 2>&1 || fail "docker is required"
docker image inspect "${RT_IMAGE}" >/dev/null 2>&1 ||
  fail "realtime image ${RT_IMAGE} not present (docker compose build realtime, or M189_IMAGE=...)"
docker image inspect "${PG_IMAGE}" >/dev/null 2>&1 || docker pull -q "${PG_IMAGE}" >/dev/null || fail "cannot pull ${PG_IMAGE}"
docker image inspect "${CURL_IMAGE}" >/dev/null 2>&1 || docker pull -q "${CURL_IMAGE}" >/dev/null || fail "cannot pull ${CURL_IMAGE}"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" --network-alias pg -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
# -h: the initdb temporary server answers the socket before TCP exists (m183).
wait_for 90 "PostgreSQL accepting TCP" docker exec "${PG}" pg_isready -h 127.0.0.1 -U postgres -q
docker run -d --name "${RT}" --network "${NET}" \
  -e REALTIME_HOST=0.0.0.0 -e REALTIME_PORT=4000 -e REALTIME_JWT_SECRET=m189-not-a-secret \
  -e REALTIME_PG_URL="postgres://postgres:${PGPW}@pg:5432/postgres" -e REALTIME_PG_CHANNEL=realtime_events \
  -e RUST_LOG=info "${RT_IMAGE}" >/dev/null
ok "throwaway PostgreSQL and realtime (${RT_IMAGE}) started"

step "1/3 PostgreSQL up -> healthy, producer attached"
wait_for 60 "--healthcheck to pass" probe
read -r code body < <(health)
[ "${code}" = 200 ] || fail "/v1/health answered ${code}: ${body}"
case "${body}" in *'"attached":true'*) ;; *) fail "/v1/health does not report the producer attached: ${body}" ;; esac
ok "--healthcheck 0, /v1/health 200, ${body#*\"producers\":}"

step "2/3 PostgreSQL stopped -> unhealthy"
docker stop -t 2 "${PG}" >/dev/null
wait_for 45 "--healthcheck to FAIL with PostgreSQL gone (a probe that only connects never does)" probe_fails
read -r code body < <(health)
[ "${code}" = 503 ] || fail "/v1/health answered ${code} with PostgreSQL stopped: ${body}"
ok "--healthcheck non-zero, /v1/health 503"

step "3/3 PostgreSQL back -> healthy again"
docker start "${PG}" >/dev/null
wait_for 120 "--healthcheck to recover after PostgreSQL returned" probe
ok "producer re-attached, --healthcheck 0 again"
