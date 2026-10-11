#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m220-stack-health.sh — `make health` answers for the WHOLE stack and can    #
#  fail                                                                        #
#                                                                              #
#  `make health` used to curl two Kong routes and exit 0 whatever came back,   #
#  so a stack with a dead service, a severed bridge or a foreign .env still    #
#  read as fine (2026-10-11: 401 on both routes, exit 0). It now runs          #
#  scripts/ops/stack-health.sh, which must keep these properties:              #
#                                                                              #
#   PARSER   an edge is a `<host>:<port>` naming ANOTHER RUNNING container of   #
#            the project; self, stopped and external hosts are not edges, and  #
#            a password that looks like `user:9…` is not mistaken for one.     #
#   WIRING   the make target runs the script and `quickstart` waits for        #
#            "starting" containers instead of failing on them.                 #
#   LIVE     (stack up) a listening port probes ok, a dead port and an unknown #
#            host probe fail, the full run exits 0, and the same run with a    #
#            wrong anon key exits 1 — the mutant a check that cannot fail      #
#            would let through.                                                #
#                                                                              #
#  Static legs need no stack. The live leg is skipped (stated, not passed)     #
#  without one; M220_REQUIRE=1 turns that skip into a failure.                 #
#                                                                              #
# **************************************************************************** #
set -uo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HEALTH="${ROOT}/scripts/ops/stack-health.sh"
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
    'K http://api:3000/v1'
}

step "PARSER — only real edges between running containers"
got="$(fixture | sh "${HEALTH}" parse-edges)"
want=$'p-api postgres 5432\np-kong api 3000'
if [ "${got}" = "${want}" ]; then
  ok "2 edges from the fixture (alias resolved, kong upstream attributed to kong)"
else
  fail "parse-edges printed: ${got//$'\n'/ | }"
fi
[ -z "$(printf 'S /p-api api running\nE /p-api X=http://api:3000\n' | sh "${HEALTH}" parse-edges)" ] &&
  ok "a service naming only itself yields no edge" || fail "self-reference became an edge"

step "WIRING — make health runs the script, quickstart waits"
grep -qE '^\s+@HEALTH_WAIT=.*sh scripts/ops/stack-health\.sh' "${ROOT}/orchestrators/makes/20-stack.mk" &&
  ok "health → scripts/ops/stack-health.sh" || fail "make health no longer runs stack-health.sh"
grep -qE 'MAKE\) health HEALTH_WAIT=[1-9]' "${ROOT}/orchestrators/makes/90-release.mk" &&
  ok "quickstart passes a non-zero HEALTH_WAIT" || fail "quickstart runs health without waiting"

step "LIVE — probes and the full run against the running stack"
client="${PROJECT}-kong"
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${client}"; then
  if [ "${M220_REQUIRE:-0}" = 1 ]; then fail "no running stack and M220_REQUIRE=1"; else printf '  • SKIPPED — no running stack (not a pass)\n'; fi
else
  probes="$(printf 'postgrest 3000\npostgrest 1\nno-such-host-m220 80\n' | sh "${HEALTH}" probe "${client}")"
  [ "${probes}" = $'ok postgrest 3000\nfail postgrest 1\nfail no-such-host-m220 80' ] &&
    ok "listening port ok · dead port fail · unknown host fail" || fail "probe printed: ${probes//$'\n'/ | }"
  (cd "${ROOT}" && sh "${HEALTH}" >/dev/null 2>&1) && ok "full run exits 0" || fail "full run failed on the live stack"
  (cd "${ROOT}" && ENV_FILE=/dev/null sh "${HEALTH}" >/dev/null 2>&1) &&
    fail "MUTANT survived: a wrong anon key still exits 0" || ok "mutant: wrong anon key exits non-zero"
fi

[ "${rc}" -eq 0 ] && printf '%s[M220] PASS%s\n' "${_G}" "${_0}"
exit "${rc}"
