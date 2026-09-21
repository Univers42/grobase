#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m183-healthcheck-network-readiness.sh — probes must assert the network      #
#                                                                              #
#  A healthcheck exists to release `depends_on: service_healthy`. It is only    #
#  worth anything if it asks the question the DEPENDENTS ask. Both engines in   #
#  this stack shipped probes that asked an easier one:                          #
#                                                                              #
#    mongo    `mongosh` with no --host dials 127.0.0.1. On a fresh volume the   #
#             entrypoint runs a TEMPORARY mongod bound to loopback for its      #
#             initdb steps, so the probe passed against an instance no          #
#             dependent could reach. mongo-init dialled mongo:27017, got        #
#             ECONNREFUSED, and being restart:"no" never tried again.           #
#    postgres `pg_isready` with no -h asks the Unix SOCKET. The temporary       #
#             initdb server runs with listen_addresses='' — socket only, no     #
#             TCP at all — so the probe answers 0 during a window in which      #
#             nothing can connect over the network.                             #
#                                                                              #
#  This gate is in two halves, and the first exists so the second cannot pass   #
#  vacuously:                                                                   #
#    1  STATIC   the configured probes name a host, and mongo-init retries.     #
#    2  DYNAMIC  spin a REAL postgres on a FRESH volume and MEASURE the window  #
#                between "socket accepting" and "TCP listening". If that        #
#                window is zero the gate says so and fails rather than          #
#                claiming a green it did not earn.                              #
#                                                                              #
#  Touches nothing that is running: its own container, volume and network,      #
#  all removed by an EXIT trap.                                                 #
# **************************************************************************** #
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-orchestrators/compose/base/data-engines.yml}"
PG_IMAGE="${PG_IMAGE:-ghcr.io/univers42/grobase-postgres:latest}"
# Starves the container so initdb stretches and the window is observable. At full
# speed TCP beats the first probe and the race simply never fires — which is why
# this only ever failed on a loaded CI runner and never on a warm VM.
PG_CPUS="${PG_CPUS:-0.10}"
NAME="m183-pg-$$"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M183] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M183] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

cleanup() {
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
  docker volume rm -f "${NAME}-data" >/dev/null 2>&1 || true
  docker network rm "${NAME}-net" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# log_ms PATTERN — epoch-millis of the first container log line matching PATTERN.
log_ms() {
  local line
  line="$(docker logs -t "${NAME}" 2>&1 | grep -m1 -- "$1" | awk '{print $1}')"
  [ -n "${line}" ] || return 1
  date -d "${line}" +%s%3N
}

step "0/4 preconditions"
command -v docker >/dev/null 2>&1 || fail "docker is required"
[ -f "${COMPOSE_FILE}" ] || fail "${COMPOSE_FILE} not found (run from the repo root)"
docker image inspect "${PG_IMAGE}" >/dev/null 2>&1 ||
  fail "${PG_IMAGE} not present locally — run 'make build' or 'docker pull ${PG_IMAGE}'"
ok "docker present; ${PG_IMAGE} available"

step "1/4 STATIC — the configured probes name a host"
# Comment lines in this file discuss the very flags being asserted, so strip them
# first: matching prose instead of config would make this check meaningless.
config_only() { grep -v '^[[:space:]]*#' "${COMPOSE_FILE}"; }

pg_probe="$(config_only | grep -m1 'pg_isready' || true)"
[ -n "${pg_probe}" ] || fail "no pg_isready probe found in ${COMPOSE_FILE}"
case "${pg_probe}" in
*'pg_isready -h '*) ok "postgres probe names a host" ;;
*) fail "postgres probe has no -h, so it asks the Unix socket the initdb temporary server answers:${pg_probe}" ;;
esac

mongo_probe="$(config_only | grep -m1 'mongosh' || true)"
[ -n "${mongo_probe}" ] || fail "no mongosh probe found in ${COMPOSE_FILE}"
case "${mongo_probe}" in
*'mongosh --host '*) ok "mongo probe names a host" ;;
*) fail "mongo probe has no --host, so the loopback-bound initdb mongod can answer it:${mongo_probe}" ;;
esac

step "2/4 STATIC — mongo-init retries a refused dial"
# restart:"no" means a single failed dial is final, so the retry has to be in the
# script. Look for a bounded loop around the connect, not just the election wait.
if config_only | grep -q 'until mongosh\|while ! mongosh\|if mongosh --host mongo'; then
  ok "mongo-init retries the connection rather than treating one refusal as final"
else
  fail "mongo-init has no connection retry; one ECONNREFUSED ends a restart:\"no\" one-shot"
fi

step "3/4 DYNAMIC — measure the socket-accepting -> TCP-listening window"
docker network create "${NAME}-net" >/dev/null
docker volume create "${NAME}-data" >/dev/null
docker run -d --name "${NAME}" --network "${NAME}-net" --network-alias postgres \
  --cpus "${PG_CPUS}" \
  -e POSTGRES_PASSWORD=m183 -e POSTGRES_USER=postgres -e POSTGRES_DB=postgres \
  -v "${NAME}-data":/var/lib/postgresql/data "${PG_IMAGE}" >/dev/null

deadline=$((SECONDS + 180))
until docker logs "${NAME}" 2>&1 | grep -q 'listening on IPv4'; do
  [ "${SECONDS}" -lt "${deadline}" ] || fail "postgres never reached a TCP listener within 180s"
  sleep 0.5
done

t_socket="$(log_ms 'database system is ready to accept connections')" ||
  fail "no 'ready to accept connections' line — cannot measure the window"
t_tcp="$(log_ms 'listening on IPv4')" ||
  fail "no 'listening on IPv4' line — cannot measure the window"
window=$((t_tcp - t_socket))

step "4/4 the window must be real, or this gate proves nothing"
if [ "${window}" -le 0 ]; then
  fail "measured a ${window}ms window: the socket server was not ready before TCP, so this run could not have caught the bug. Re-run with a lower PG_CPUS (currently ${PG_CPUS})."
fi
ok "window is real: socket accepted ${window}ms before the TCP listener existed"
ok "a probe with no -h would have reported HEALTHY for ${window}ms while every dependent got ECONNREFUSED"

printf '\033[0;32m[M183] ALL GATES GREEN — both probes assert the network path; mongo-init retries; window measured at %sms (cpus=%s)\033[0m\n' \
  "${window}" "${PG_CPUS}"
