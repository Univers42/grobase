#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m236-waf-upstream-keepalive.sh — the WAF reuses pooled TCP connections to   #
#  Kong, so a burst of plain requests crosses it on a handful of sockets, not  #
#  one fresh connection per request (upstream kong_upstream keepalive).        #
#                                                                              #
#  The WAF config (infra/docker/services/waf/conf/nginx.conf) declares         #
#  `upstream kong_upstream { keepalive 32; }` and proxies with                 #
#  proxy_http_version 1.1, so nginx holds idle connections to Kong and reuses  #
#  them; without the keepalive directive every request opens a new TCP         #
#  connection, which this gate measures.                                       #
#                                                                              #
#  It boots the WAF image with that config on a private network whose `kong`   #
#  is an echo server counting its own `connection` events. One node process    #
#  resets the counter, sends 100 sequential GETs through the WAF, then reads   #
#  the counter back and prints (count - 1); leg 1 (the real config) must show  #
#  at most one upstream connection per nginx worker (+1): each worker keeps    #
#  its own pool, and fresh client connections spread across the workers.      #
#                                                                              #
#  MUTANT: the same config with the `keepalive 32;` line deleted. If the sed   #
#  removed nothing the leg is blind and the gate fails; otherwise the probe    #
#  MUST see at least 90 connections, else it cannot tell the two configs       #
#  apart.                                                                      #
#                                                                              #
#  Needs docker, the WAF image and node:20-alpine already present (nothing is  #
#  pulled) and certs/localhost{,-key}.pem; otherwise SKIP, exit 77, never 0.   #
#  Containers, network and temp dir go in an EXIT trap.                        #
#  M236_CONF=<path> tests another config (a mutant with keepalive removed      #
#  must go red).                                                               #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONF="${M236_CONF:-${ROOT}/infra/docker/services/waf/conf/nginx.conf}"
WAF_IMG="${M236_WAF_IMAGE:-ghcr.io/univers42/grobase-waf:latest}"
NODE_IMG="${M236_NODE_IMAGE:-mirror.gcr.io/library/node:20-alpine}"
CERT="${ROOT}/certs/localhost.pem"
KEY="${ROOT}/certs/localhost-key.pem"
TAG="m236gate$$"
NET="${TAG}-net"
WORK="$(mktemp -d)"
FAILED=0

ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
bad() {
  printf '\033[0;31m  ✗ %s\033[0m\n' "$*"
  FAILED=1
}
step() { printf '\033[0;36m[M236] %s\033[0m\n' "$*"; }

# skip REASON: print why nothing was proven and exit 77 (a gate that did not look has not passed).
skip() {
  printf '\033[0;33m[M236] SKIP — %s; nothing proven\033[0m\n' "$*"
  exit 77
}

# cleanup: remove every container, the network and the temp dir this run made.
cleanup() {
  docker rm -f "${TAG}-kong" "${TAG}-waf" "${TAG}-mut" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

# preconditions: docker, both images present locally, the TLS pair the WAF config loads.
preconditions() {
  command -v docker >/dev/null 2>&1 || skip "docker is not available"
  docker image inspect "${WAF_IMG}" >/dev/null 2>&1 || skip "${WAF_IMG} is not present (make build-svc-waf)"
  docker image inspect "${NODE_IMG}" >/dev/null 2>&1 || skip "${NODE_IMG} is not present"
  [ -f "${CERT}" ] && [ -f "${KEY}" ] || skip "certs/localhost.pem + key are missing (make certs)"
  [ -f "${CONF}" ] || skip "${CONF} not found"
}

# start_waf NAME CONF: boot the WAF image with CONF as its server block; wait for /waf-health.
# CONF is copied into a per-container conf.d dir mounted in place of the image's: the entrypoint's
# 93-update-proxy-ssl-config.sh runs `sed -i` on default.conf, and a rename over a single-file
# bind mount fails with EBUSY, so a file mount never boots.
start_waf() {
  local name="$1" conf="$2" dir="${WORK}/confd-$1" i
  mkdir -p "${dir}" && cp "${conf}" "${dir}/default.conf" && chmod 0777 "${dir}" && chmod 0666 "${dir}/default.conf"
  docker run -d --name "${name}" --network "${NET}" \
    -v "${dir}:/etc/nginx/conf.d" \
    -v "${CERT}:/run/secrets/localhost_cert:ro" \
    -v "${KEY}:/run/secrets/localhost_key:ro" \
    "${WAF_IMG}" >/dev/null || return 1
  for i in $(seq 1 60); do
    [ "$(health "${name}")" = '{"status":"ok","service":"waf"}' ] && return 0
    sleep 1
  done
  docker logs "${name}" 2>&1 | tail -5 >&2
  return 1
}

# health NAME: GET NAME:80/waf-health from the echo container; the WAF answers it locally
# (modsecurity off) once its listener is up, so this is readiness, not a proxied request.
health() {
  docker exec -e WAF="$1" "${TAG}-kong" node -e '
    const r = require("http").request({ host: process.env.WAF, port: 80, path: "/waf-health", headers: { Host: "localhost" } });
    r.on("response", (s) => { let b = ""; s.on("data", (c) => (b += c)); s.on("end", () => process.stdout.write(b)); });
    r.on("error", () => {});
    r.end();' 2>/dev/null
}

# probe WAF: one node process in the echo container; reset the upstream connection counter, send
# 100 sequential GETs through the WAF (no client keep-alive, awaiting each), then read the counter
# back and print (count - 1) — the count request's own socket is the minus one — i.e. how many TCP
# connections the WAF opened to Kong for those 100 requests.
probe() {
  docker exec -e WAF="$1" "${TAG}-kong" node -e '
    const get = (host, port, path) => new Promise((res, rej) => {
      const r = require("http").request({ host: host, port: port, path: path, headers: { Host: "localhost" }, agent: false }, (s) => { let b = ""; s.on("data", (c) => (b += c)); s.on("end", () => res(b)); });
      r.on("error", rej);
      r.end();
    });
    (async () => {
      await get("127.0.0.1", 8000, "/m236-reset");
      for (let i = 0; i < 100; i++) await get(process.env.WAF, 80, "/m236");
      const n = await get("127.0.0.1", 8000, "/m236-count");
      process.stdout.write(String(Number(n) - 1));
    })().catch(() => {});' 2>/dev/null
}

# workers WAF: how many nginx worker processes the WAF container runs (each owns one keep-alive pool).
workers() {
  docker exec "$1" sh -c 'grep -l "^nginx: worker process" /proc/[0-9]*/cmdline 2>/dev/null | wc -l'
}

step "0/3 preconditions"
preconditions
docker network create "${NET}" >/dev/null || skip "could not create a docker network"
docker run -d --name "${TAG}-kong" --network "${NET}" --network-alias kong "${NODE_IMG}" node -e '
  let n = 0;
  const s = require("http").createServer((q, r) => {
    if (q.url === "/m236-count") r.end(String(n));
    else if (q.url === "/m236-reset") { n = 0; r.end("ok"); }
    else r.end("ok");
  });
  s.on("connection", () => { n++; });
  s.listen(8000);' >/dev/null ||
  skip "could not start the echo upstream"

step "1/3 WAF with ${CONF#"${ROOT}"/}"
start_waf "${TAG}-waf" "${CONF}" || {
  bad "the WAF did not become healthy with this config"
  exit 1
}
got="$(probe "${TAG}-waf")"
max=$(($(workers "${TAG}-waf") + 1))
case "${got}" in
'' | *[!0-9]*) bad "real config: probe returned '${got}', not a connection count" ;;
*) if [ "${got}" -le "${max}" ]; then
  ok "real config reused the pool: ${got} upstream connections for 100 requests (limit ${max}: workers + 1)"
else
  bad "real config opened ${got} upstream connections for 100 requests (want <= ${max}: workers + 1)"
fi ;;
esac

step "2/3 mutant: 'keepalive 32;' removed must open a connection per request"
sed '/keepalive 32;/d' "${CONF}" >"${WORK}/mutant.conf"
if cmp -s "${CONF}" "${WORK}/mutant.conf"; then
  bad "mutant: no 'keepalive 32;' line to remove — rebuild this leg"
elif ! start_waf "${TAG}-mut" "${WORK}/mutant.conf"; then
  bad "mutant: the WAF did not start with the mutant config"
else
  got="$(probe "${TAG}-mut")"
  case "${got}" in
  '' | *[!0-9]*) bad "mutant: probe returned '${got}', not a connection count" ;;
  *) [ "${got}" -ge 90 ] && ok "mutant opened ${got} upstream connections — the probe sees per-request connects" ||
    bad "mutant opened ${got} upstream connections (want >=90) — the probe is blind" ;;
  esac
fi

step "3/3 verdict"
[ "${FAILED}" -eq 0 ] || {
  printf '\033[0;31m[M236] FAIL — the WAF does not reuse its Kong connection pool, or the probe is blind\033[0m\n' >&2
  exit 1
}
printf '\033[0;32m[M236] PASS — the WAF reuses pooled connections to Kong (upstream keepalive)\033[0m\n'
