#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m187-gateway-probes-exercise-the-proxy.sh — the gateway's healthchecks      #
#  must fail when the path dependents use is gone, not only when the process   #
#  is                                                                          #
#                                                                              #
#  Kong's probe was `kong health`: it checks that nginx PIDs exist, so it      #
#  stays green with proxy_listen off, the one listener every client dials.     #
#  The WAF's probe grepped /proc/net/tcp for a socket in LISTEN state and      #
#  never made a request, so the door reported healthy with nothing behind      #
#  it. The WAF waits on Kong's health (`service_healthy`), so a blind Kong     #
#  probe released a blind door.                                                #
#                                                                              #
#  Same shape as m183, and for the same reason: the static half reads the      #
#  CONFIGURED probes (docker compose config), the dynamic half runs them       #
#  against throwaway containers where the answer is known:                     #
#     kong-on  / waf-on   proxy listening        -> both probes must pass      #
#     kong-off / waf-off  KONG_PROXY_LISTEN=off  -> both probes must FAIL      #
#  A probe that passes in the "off" pair asks an easier question than the     #
#  dependents do, and the gate says which.                                     #
#                                                                              #
#  Mutant: M187_EXTRA_COMPOSE=scripts/test/mutants/fixtures/gateway-probes-   #
#  blind.yml restores the old probes; this gate must go red (manifest row      #
#  gateway-probes-blind).                                                      #
#                                                                              #
#  Its own compose project, networks and containers, all removed by an EXIT    #
#  trap. The kong containers are started with `compose run`, which gives them  #
#  NO service alias, so nothing can answer to "kong" on the live network.      #
#  Needs the kong and waf images present locally (`make build` or pull).       #
# **************************************************************************** #
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${ROOT}"
P="m187gate$$"
EXTRA="${M187_EXTRA_COMPOSE:-}"
WORK="$(mktemp -d)"
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M187] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M187] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}
cleanup() {
  local c
  for c in "${P}-kong-on" "${P}-kong-off" "${P}-waf-on" "${P}-waf-off"; do
    docker rm -f "$c" >/dev/null 2>&1 || true
  done
  docker network rm "${P}-on" "${P}-off" >/dev/null 2>&1 || true
  docker network rm "${P}_mini-baas" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

compose_files=(-f docker-compose.yml)
[ -z "${EXTRA}" ] || compose_files+=(-f "${EXTRA}")
dc() { docker compose "${compose_files[@]}" -p "${P}" --profile '*' "$@"; }

step "0/4 preconditions"
command -v docker >/dev/null 2>&1 || fail "docker is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required (reads the resolved compose config)"
[ -f .env ] || fail ".env missing (make env) — compose needs it to resolve the services"
[ -z "${EXTRA}" ] || [ -f "${EXTRA}" ] || fail "M187_EXTRA_COMPOSE=${EXTRA} not found"
dc config --format json >"${WORK}/config.json" 2>/dev/null || fail "docker compose config failed"
read -r KONG_IMG WAF_IMG < <(python3 -c '
import json, sys
s = json.load(open(sys.argv[1]))["services"]
print(s["kong"]["image"], s["waf"]["image"])' "${WORK}/config.json")
for img in "${KONG_IMG}" "${WAF_IMG}"; do
  docker image inspect "${img}" >/dev/null 2>&1 || fail "image ${img} not present locally (make build / docker pull)"
done
ok "kong ${KONG_IMG}, waf ${WAF_IMG}${EXTRA:+, with ${EXTRA}}"

step "1/4 STATIC — the probes as configured"
# One probe per line, as a JSON array, so the dynamic half runs exactly what
# Docker would run and not a hand-copied version of it.
python3 -c '
import json, sys
s = json.load(open(sys.argv[1]))["services"]
for n in ("kong", "waf"):
    t = s[n].get("healthcheck", {}).get("test")
    if not t:
        sys.exit("no healthcheck on " + n)
    # compose config re-escapes $ as $$ for round-tripping; Docker gets one $.
    print(n, json.dumps([a.replace("$$", "$") for a in t]))' "${WORK}/config.json" >"${WORK}/probes" ||
  fail "a gateway service has no healthcheck"
while read -r name probe; do printf '  %-5s %s\n' "${name}" "${probe:0:110}"; done <"${WORK}/probes"

# Run the configured probe of <service> inside <container>; returns its rc.
run_probe() { # <service> <container>
  local json
  json=$(awk -v n="$1" '$1 == n { sub(/^[^ ]+ /, ""); print }' "${WORK}/probes")
  mapfile -t argv < <(python3 -c '
import json, sys
t = json.loads(sys.argv[1])
if t[0] == "CMD-SHELL":
    print("sh"); print("-c"); print(t[1])
elif t[0] == "CMD":
    print(*t[1:], sep="\n")
else:
    sys.exit("unsupported healthcheck form: " + t[0])' "${json}")
  timeout 15 docker exec "$2" "${argv[@]}" >/dev/null 2>&1
}

step "2/4 DYNAMIC — two throwaway Kongs: proxy on, proxy off"
docker network create "${P}-on" >/dev/null
docker network create "${P}-off" >/dev/null
dc run -d --no-deps --name "${P}-kong-on" kong >/dev/null
dc run -d --no-deps --name "${P}-kong-off" -e KONG_PROXY_LISTEN=off kong >/dev/null
docker network connect --alias kong "${P}-on" "${P}-kong-on"
docker network connect --alias kong "${P}-off" "${P}-kong-off"
# "Up" is judged by the process, deliberately: the question is what the
# probe says once Kong is running, so wait for the process, not the probe.
for c in "${P}-kong-on" "${P}-kong-off"; do
  for _ in $(seq 1 45); do
    docker exec "$c" kong health >/dev/null 2>&1 && break
    sleep 2
  done
  docker exec "$c" kong health >/dev/null 2>&1 || fail "$c never came up (docker logs $c)"
done
ok "both Kongs running (kong health: nginx up in each)"

step "3/4 DYNAMIC — two throwaway WAFs, one in front of each Kong"
mkdir -p "${WORK}/certs"
if [ -f certs/localhost.pem ] && [ -f certs/localhost-key.pem ]; then
  cp certs/localhost.pem "${WORK}/certs/cert.pem"
  cp certs/localhost-key.pem "${WORK}/certs/key.pem"
else
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
    -keyout "${WORK}/certs/key.pem" -out "${WORK}/certs/cert.pem" >/dev/null 2>&1 ||
    fail "no certs/localhost*.pem and openssl could not mint a throwaway pair"
fi
chmod 644 "${WORK}/certs/"*.pem
for side in on off; do
  docker run -d --name "${P}-waf-${side}" --network "${P}-${side}" \
    -v "${WORK}/certs/cert.pem:/run/secrets/localhost_cert:ro" \
    -v "${WORK}/certs/key.pem:/run/secrets/localhost_key:ro" \
    "${WAF_IMG}" >/dev/null
done
for side in on off; do
  for _ in $(seq 1 30); do
    [ "$(docker inspect -f '{{.State.Running}}' "${P}-waf-${side}" 2>/dev/null)" = true ] &&
      docker exec "${P}-waf-${side}" sh -c 'grep -qi ":01BB .* 0A" /proc/net/tcp' 2>/dev/null && break
    sleep 1
  done
done
ok "both WAFs running and listening on :443"

step "4/4 verdict — each probe must pass on 'on' and fail on 'off'"
bad=0
check() { # <service> <container> <expect: pass|fail>
  local rc=0
  run_probe "$1" "$2" || rc=$?
  if [ "$3" = pass ] && [ "$rc" -ne 0 ]; then
    printf '  \033[0;31m✗ %s probe FAILED on %s (rc=%s) — a working path reported unhealthy\033[0m\n' "$1" "$2" "$rc"
    bad=$((bad + 1))
  elif [ "$3" = fail ] && [ "$rc" -eq 0 ]; then
    printf '  \033[0;31m✗ %s probe PASSED on %s — it does not exercise the path dependents use\033[0m\n' "$1" "$2"
    bad=$((bad + 1))
  else
    printf '  ✓ %-5s on %-28s rc=%s (%s, as required)\n' "$1" "$2" "$rc" "$3"
  fi
}
check kong "${P}-kong-on" pass
check kong "${P}-kong-off" fail
check waf "${P}-waf-on" pass
check waf "${P}-waf-off" fail
[ "${bad}" -eq 0 ] || fail "${bad} probe verdict(s) wrong"
ok "kong and waf probes pass only when the proxy path answers"
