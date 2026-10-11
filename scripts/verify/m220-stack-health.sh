#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m220-stack-health.sh — `make health` answers for the WHOLE stack and can    #
#  fail                                                                        #
#                                                                              #
#  `make health` used to curl two Kong routes and exit 0 whatever came back,   #
#  so a stack with a dead service, a severed bridge or a foreign .env still    #
#  read as fine (2026-10-11: 401 on both routes, exit 0). It now runs          #
#  scripts/ops/stack-health.sh (+ stack-health-requests.sh), which must keep:  #
#                                                                              #
#   PARSER   an edge is a `<host>:<port>` naming ANOTHER RUNNING container of   #
#            the project; self, stopped and external hosts are not edges, a    #
#            password that looks like `user:9…` is not mistaken for one, and a #
#            depends_on with no explicit address becomes an edge on the        #
#            dependency's exposed ports.                                       #
#   ROUTES   kong.yml yields "path upstream-host" pairs; regex routes do not.  #
#   WIRING   the make target runs the script and `quickstart` waits for        #
#            "starting" containers instead of failing on them.                 #
#   LIVE     (stack up) a listening port probes ok, a dead port and an unknown #
#            host probe fail, any-of-several ports passes on one, the full run #
#            exits 0, and four mutants exit 1: a wrong anon key, a wrong       #
#            postgres password, a gateway route to a dead upstream port, and a #
#            shape naming a service that has no container.                     #
#                                                                              #
#  Static legs need no stack. The live leg is skipped (stated, not passed)     #
#  without one; M220_REQUIRE=1 turns that skip into a failure.                 #
#                                                                              #
# **************************************************************************** #
set -uo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HEALTH="${ROOT}/scripts/ops/stack-health.sh"
REQUESTS="${ROOT}/scripts/ops/stack-health-requests.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
PROJECT="${COMPOSE_PROJECT_NAME:-mini-baas}"

_B=$'\033[0;36m' _G=$'\033[0;32m' _R=$'\033[0;31m' _0=$'\033[0m'
rc=0
step() { printf '%s[M220] %s%s\n' "${_B}" "$1" "${_0}"; }
ok() { printf '%s  ✓ %s%s\n' "${_G}" "$1" "${_0}"; }
fail() {
  printf '%s[M220] FAIL — %s%s\n' "${_R}" "$1" "${_0}"
  rc=1
}

# fixture prints a synthetic project: kong + api + db running, one stopped service.
fixture() {
  printf '%s\n' \
    'S /p-kong kong running' 'S /p-api api running' 'S /p-db db running' 'S /p-dead dead exited' \
    'A /p-db postgres' \
    'E /p-api DSN=postgres://user:9secret@postgres:5432/app' \
    'E /p-api SELF=http://api:3000' 'E /p-api GONE=http://dead:9/' 'E /p-api EXT=https://example.com:443' \
    'E /p-dead DSN=postgres://postgres:5432' \
    'K http://api:3000/v1' \
    'P /p-db 5432/tcp' 'P /p-kong 8000/tcp' 'P /p-kong 8001/tcp' 'P /p-kong 53/udp' \
    'D /p-api db:service_healthy:false,kong:service_started:false,dead:service_started:false' \
    'D /p-kong '
}

step "PARSER — only real edges between running containers"
got="$(fixture | sh "${HEALTH}" parse-edges)"
want=$'p-api kong 8000,8001\np-api postgres 5432\np-kong api 3000'
if [ "${got}" = "${want}" ]; then
  ok "3 edges from the fixture (alias resolved, kong upstream attributed to kong, depends_on→exposed tcp ports, explicit edge not doubled)"
else
  fail "parse-edges printed: ${got//$'\n'/ | }"
fi
[ -z "$(printf 'S /p-api api running\nE /p-api X=http://api:3000\n' | sh "${HEALTH}" parse-edges)" ] &&
  ok "a service naming only itself yields no edge" || fail "self-reference became an edge"

step "ROUTES — kong.yml → path + upstream host"
printf '%s\n' 'services:' '  - name: a' '    url: http://gotrue:9999' '    routes:' '      - paths: [/auth/v1, "/auth/v2"]' \
  '  - name: b' '    url: http://tenant-control:3022/x' '    routes:' '      - paths:' '          - ~/v1/tenants/me$' '      - paths: [/tenants/v1]' >"${WORK}/kong.yml"
routes="$(KONG_YML="${WORK}/kong.yml" sh "${REQUESTS}" routes)"
[ "${routes}" = $'/auth/v1 gotrue\n/auth/v2 gotrue\n/tenants/v1 tenant-control' ] &&
  ok "3 literal routes with their upstream; the regex route is left out" || fail "route_table printed: ${routes//$'\n'/ | }"

step "WIRING — make health runs the script, quickstart waits"
mk="${ROOT}/orchestrators/makes/20-stack.mk"
grep -q 'sh scripts/ops/stack-health\.sh' "${mk}" && grep -q 'HEALTH_EXPECT="$(if $(filter command environment' "${mk}" &&
  ok "health → scripts/ops/stack-health.sh, the shape passed only when given explicitly" || fail "make health no longer runs stack-health.sh with an explicit-shape HEALTH_EXPECT"
grep -qE 'MAKE\) health HEALTH_WAIT=[1-9]' "${ROOT}/orchestrators/makes/90-release.mk" &&
  ok "quickstart passes a non-zero HEALTH_WAIT" || fail "quickstart runs health without waiting"

step "LIVE — probes and the full run against the running stack"
client="${PROJECT}-kong"
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${client}"; then
  if [ "${M220_REQUIRE:-0}" = 1 ]; then fail "no running stack and M220_REQUIRE=1"; else printf '  • SKIPPED — no running stack (not a pass)\n'; fi
else
  probes="$(printf 'postgrest 3000\npostgrest 1\nno-such-host-m220 80\npostgrest 1,3000\n' | sh "${HEALTH}" probe "${client}")"
  [ "${probes}" = $'ok postgrest 3000\nfail postgrest 1\nfail no-such-host-m220 80\nok postgrest 1,3000' ] &&
    ok "listening port ok · dead port fail · unknown host fail · any-of passes on one" || fail "probe printed: ${probes//$'\n'/ | }"
  (cd "${ROOT}" && sh "${HEALTH}" >/dev/null 2>&1) && ok "full run exits 0" || fail "full run failed on the live stack"
  (cd "${ROOT}" && ENV_FILE=/dev/null sh "${REQUESTS}" gateway >/dev/null 2>&1) &&
    fail "MUTANT survived: a wrong anon key still exits 0" || ok "mutant: wrong anon key exits non-zero"
  printf 'POSTGRES_USER=postgres\nPOSTGRES_PASSWORD=m220-not-the-password\n' >"${WORK}/bad.env"
  out="$(cd "${ROOT}" && ENV_FILE="${WORK}/bad.env" sh "${REQUESTS}" engines 2>&1)" &&
    fail "MUTANT survived: a wrong postgres password still exits 0" || ok "mutant: wrong postgres password exits non-zero"
  grep -q 'postgres REJECTS' <<<"${out}" || fail "the rejected engine is not named"
  sed -E '0,/url: http:\/\/gotrue:[0-9]+/s//url: http:\/\/gotrue:1/' "${ROOT}/infra/docker/services/kong/conf/kong.yml" >"${WORK}/kong-live.yml"
  edges="$(cd "${ROOT}" && KONG_YML="${WORK}/kong-live.yml" sh "${HEALTH}" 2>&1)" &&
    fail "MUTANT survived: kong → gotrue on a dead port still exits 0" || ok "mutant: an unreachable declared upstream exits non-zero"
  grep -q 'UNREACHABLE: gotrue:1' <<<"${edges}" || fail "the unreachable edge is not named"
  shape="$(cd "${ROOT}" && HEALTH_EXPECT="kong no-such-service-m220" sh "${HEALTH}" 2>&1)" &&
    fail "MUTANT survived: a shape naming a service with no container still exits 0" || ok "mutant: a missing service of the selected shape exits non-zero"
  grep -q 'no-such-service-m220 is part of the selected shape' <<<"${shape}" || fail "the missing service is not named"
  if docker ps --format '{{.Names}}' | grep -qx "${PROJECT}-prometheus"; then
    (cd "${ROOT}" && sh "${REQUESTS}" monitoring 2>&1 | grep -q 'scrape targets, none down') &&
      ok "monitoring leg reads Prometheus' targets" || fail "monitoring leg did not report the scrape targets"
  fi
fi

[ "${rc}" -eq 0 ] && printf '%s[M220] PASS%s\n' "${_G}" "${_0}"
exit "${rc}"
