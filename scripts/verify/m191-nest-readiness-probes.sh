#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m191-nest-readiness-probes.sh — a Nest service's healthcheck must ask its   #
#  readiness, which checks its dependencies, not its liveness, which never     #
#  does                                                                        #
#                                                                              #
#  All thirteen Nest services implement GET /health/ready (Terminus checks of  #
#  MongoDB, PostgreSQL, Redis, peers) and all thirteen probed /health/live,    #
#  which answers 200 while the process runs. Measured 2026-09-23 with a        #
#  throwaway MongoDB under a throwaway ai-service: MongoDB stopped ->          #
#  /health/ready 503, /health/live 200, and the container reported (healthy). #
#  query-router waits on permission-engine being healthy; it was released by  #
#  a probe that could not see PostgreSQL.                                      #
#                                                                              #
#    1 STATIC   every service whose src/apps/<svc>/src/health.controller.ts    #
#               has @Get('ready') probes /health/ready (docker compose config) #
#    2 DYNAMIC  ai-service's CONFIGURED probe, run in a throwaway ai-service   #
#               on a throwaway MongoDB: passes with MongoDB up, FAILS with it  #
#               stopped.                                                       #
#                                                                              #
#  Mutant: M191_EXTRA_COMPOSE=scripts/test/mutants/fixtures/nest-probes-live.  #
#  yml restores ai-service's /health/live probe; both halves must go red      #
#  (manifest row nest-probes-live).                                            #
#                                                                              #
#  Own network and containers, removed by an EXIT trap.                        #
# **************************************************************************** #
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${ROOT}"
EXTRA="${M191_EXTRA_COMPOSE:-}"
NET="m191-net-$$"
DB="m191-mongo-$$"
SVC="m191-ai-$$"
WORK="$(mktemp -d)"
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M191] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M191] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}
cleanup() {
  docker rm -f "${SVC}" "${DB}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

files=(-f docker-compose.yml)
[ -z "${EXTRA}" ] || files+=(-f "${EXTRA}")

step "0/2 preconditions"
command -v docker >/dev/null 2>&1 || fail "docker is required"
[ -f .env ] || fail ".env missing (make env)"
docker compose "${files[@]}" --profile '*' config --format json >"${WORK}/config.json" 2>/dev/null ||
  fail "docker compose config failed"
ok "compose config resolved${EXTRA:+ with ${EXTRA}}"

step "1/2 STATIC — services that implement readiness probe it"
python3 - "${WORK}/config.json" >"${WORK}/static.txt" <<'PY'
import glob, json, sys
svcs = json.load(open(sys.argv[1]))["services"]
ready = sorted(f.split("/")[2] for f in glob.glob("src/apps/*/src/health.controller.ts")
               if "@Get('ready')" in open(f).read())
bad = [n for n in ready if n in svcs and "/health/ready" not in json.dumps(svcs[n].get("healthcheck", {}).get("test", ""))]
for n in bad:
    print("BAD " + n)
print("COUNT %d" % len(ready))
PY
n_ready=$(sed -n 's/^COUNT //p' "${WORK}/static.txt")
static_bad=$(sed -n 's/^BAD //p' "${WORK}/static.txt" | tr '\n' ' ')
if [ -n "${static_bad}" ]; then
  printf '  \033[0;31m✗ implement readiness but probe liveness: %s\033[0m\n' "${static_bad}"
  static_fail=1
else
  ok "${n_ready} services implement readiness, all probe /health/ready"
  static_fail=0
fi

step "2/2 DYNAMIC — ai-service's configured probe follows MongoDB"
read -r IMG PORT PROBE < <(
  python3 - "${WORK}/config.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))["services"]["ai-service"]
env = s.get("environment") or {}
print(s["image"], env.get("PORT", "3000"), json.dumps(s["healthcheck"]["test"]))
PY
)
docker image inspect "${IMG}" >/dev/null 2>&1 || docker pull -q "${IMG}" >/dev/null || fail "cannot get ${IMG}"
MONGO_IMG=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["services"]["mongo"]["image"])' "${WORK}/config.json")
docker image inspect "${MONGO_IMG}" >/dev/null 2>&1 || docker pull -q "${MONGO_IMG}" >/dev/null || fail "cannot get ${MONGO_IMG}"
docker network create "${NET}" >/dev/null
docker run -d --name "${DB}" --network "${NET}" --network-alias m191mongo --entrypoint mongod "${MONGO_IMG}" --bind_ip_all >/dev/null
sleep 5
docker run -d --name "${SVC}" --network "${NET}" -e PORT="${PORT}" -e MONGO_URI="mongodb://m191mongo:27017" \
  -e MONGO_DB_NAME=m191 -e JWT_SECRET=m191-not-a-secret "${IMG}" >/dev/null
run_probe() {
  python3 - "${SVC}" "${PROBE}" <<'PY'
import json, subprocess, sys
t = json.loads(sys.argv[2])
argv = ["sh", "-c", t[1]] if t[0] == "CMD-SHELL" else t[1:]
try:
    rc = subprocess.run(["docker", "exec", sys.argv[1], *argv], stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL, timeout=15).returncode
except subprocess.TimeoutExpired:
    rc = 124
sys.exit(rc)
PY
}
up=1
for _ in $(seq 1 30); do
  run_probe && {
    up=0
    break
  }
  sleep 2
done
[ "${up}" -eq 0 ] || fail "ai-service's probe never passed with MongoDB up ($(docker logs --tail 2 "${SVC}" 2>&1 | tail -1))"
ok "MongoDB up: probe passes (${PROBE})"
docker stop -t 2 "${DB}" >/dev/null
down=1
for _ in $(seq 1 15); do
  run_probe || {
    down=0
    break
  }
  sleep 2
done
dyn_fail=0
if [ "${down}" -eq 0 ]; then
  ok "MongoDB stopped: probe fails"
else
  printf '  \033[0;31m✗ MongoDB stopped for 30 s and the probe still passes: it does not ask what dependents need\033[0m\n'
  dyn_fail=1
fi

[ "${static_fail}" -eq 0 ] && [ "${dyn_fail}" -eq 0 ] || fail "Nest healthchecks do not follow their dependencies"
ok "Nest services report ready, not merely alive"
