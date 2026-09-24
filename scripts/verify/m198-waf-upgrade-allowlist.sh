#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m198-waf-upgrade-allowlist.sh — the WAF relays only `Upgrade: websocket`    #
#  to Kong; `Upgrade: h2c` (HTTP/2-cleartext smuggling) never reaches it       #
#                                                                              #
#  An h2c upgrade relayed by a reverse proxy lets a client tunnel raw HTTP/2   #
#  requests past the proxy's inspection, i.e. past ModSecurity. The WAF        #
#  config (infra/docker/services/waf/conf/nginx.conf) maps the Upgrade header  #
#  through an allowlist: `websocket` passes (realtime), anything else is       #
#  dropped and the upstream Connection is `close`.                              #
#                                                                              #
#  It boots the WAF image with that config on a private network whose `kong`  #
#  is a header-echo server, then sends three requests through port 80:        #
#    h2c        upstream sees no Upgrade and `Connection: close`               #
#    websocket  upstream sees `Upgrade: websocket`, `Connection: upgrade`      #
#    none       upstream sees no Upgrade and `Connection: close`               #
#  MUTANT: the same config with the Upgrade header fed from $http_upgrade      #
#  again (the pre-fix line) MUST relay h2c, else the probe is blind and the    #
#  gate fails.                                                                 #
#                                                                              #
#  Needs docker, the WAF image and node:20-alpine already present (nothing is  #
#  pulled) and certs/localhost{,-key}.pem; otherwise SKIP, exit 77, never 0.   #
#  Containers, network and temp dir go in an EXIT trap.                        #
#  M198_CONF=<path> tests another config (a mutant that relays h2c must go    #
#  red).                                                                       #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONF="${M198_CONF:-${ROOT}/infra/docker/services/waf/conf/nginx.conf}"
WAF_IMG="${M198_WAF_IMAGE:-ghcr.io/univers42/grobase-waf:latest}"
NODE_IMG="${M198_NODE_IMAGE:-public.ecr.aws/docker/library/node:20-alpine}"
CERT="${ROOT}/certs/localhost.pem"
KEY="${ROOT}/certs/localhost-key.pem"
TAG="m193gate$$"
NET="${TAG}-net"
WORK="$(mktemp -d)"
FAILED=0

ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
bad() {
  printf '\033[0;31m  ✗ %s\033[0m\n' "$*"
  FAILED=1
}
step() { printf '\033[0;36m[M198] %s\033[0m\n' "$*"; }

# skip REASON: print why nothing was proven and exit 77 (a gate that did not look has not passed).
skip() {
  printf '\033[0;33m[M198] SKIP — %s; nothing proven\033[0m\n' "$*"
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
    [ "$(probe "${name}" /waf-health "")" = '{"status":"ok","service":"waf"}' ] && return 0
    sleep 1
  done
  docker logs "${name}" 2>&1 | tail -5 >&2
  return 1
}

# probe WAF PATH UPGRADE: GET WAF:80/PATH (with `Upgrade: UPGRADE` when non-empty) from the
# echo container; print the response body (for the echo upstream: the headers kong received).
probe() {
  docker exec -e WAF="$1" -e P="$2" -e UP="$3" "${TAG}-kong" node -e '
    const h = { Host: "localhost" };
    if (process.env.UP) Object.assign(h, { Upgrade: process.env.UP, Connection: "Upgrade, HTTP2-Settings", "HTTP2-Settings": "AAMAAABkAAQAAP__" });
    const r = require("http").request({ host: process.env.WAF, port: 80, path: process.env.P, headers: h });
    r.on("response", (s) => { let b = ""; s.on("data", (c) => (b += c)); s.on("end", () => process.stdout.write(b)); });
    r.on("upgrade", (s) => { process.stdout.write("{\"upgraded\":true}"); s.destroy(); });
    r.on("error", () => {});
    r.end();' 2>/dev/null
}

# upstream WAF UPGRADE: "<upgrade>|<connection>" as the echo upstream saw them ("-" when absent).
upstream() {
  probe "$1" /m198 "$2" | node_json
}

# node_json: read the echoed header JSON on stdin, print "<upgrade>|<connection>".
node_json() {
  docker exec -i "${TAG}-kong" node -e '
    let b = ""; process.stdin.on("data", (c) => (b += c)).on("end", () => {
      try { const j = JSON.parse(b); process.stdout.write((j.upgrade || "-") + "|" + (j.connection || "-")); }
      catch { process.stdout.write("unparsed:" + b.slice(0, 80)); } });'
}

# expect LABEL GOT WANT: record a pass or a failure for one probe.
expect() {
  if [ "$2" = "$3" ]; then ok "$1: upstream saw '$2'"; else bad "$1: upstream saw '$2', want '$3'"; fi
}

step "0/3 preconditions"
preconditions
docker network create "${NET}" >/dev/null || skip "could not create a docker network"
docker run -d --name "${TAG}-kong" --network "${NET}" --network-alias kong "${NODE_IMG}" node -e '
  require("http").createServer((q, r) => { r.setHeader("content-type", "application/json"); r.end(JSON.stringify(q.headers)); }).listen(8000);' >/dev/null ||
  skip "could not start the echo upstream"

step "1/3 WAF with ${CONF#"${ROOT}"/}"
start_waf "${TAG}-waf" "${CONF}" || { bad "the WAF did not become healthy with this config"; exit 1; }
expect "h2c upgrade" "$(upstream "${TAG}-waf" h2c)" "-|close"
expect "websocket upgrade" "$(upstream "${TAG}-waf" websocket)" "websocket|upgrade"
expect "no upgrade" "$(upstream "${TAG}-waf" "")" "-|close"

step "2/3 mutant: Upgrade fed from \$http_upgrade again must relay h2c"
sed 's/proxy_set_header   Upgrade           \$ws_upgrade;/proxy_set_header   Upgrade           $http_upgrade;/' "${CONF}" >"${WORK}/mutant.conf"
if cmp -s "${CONF}" "${WORK}/mutant.conf"; then
  bad "mutant: the Upgrade allowlist line is not in the config any more — rebuild this leg"
elif ! start_waf "${TAG}-mut" "${WORK}/mutant.conf"; then
  bad "mutant: the WAF did not start with the mutant config"
else
  got="$(upstream "${TAG}-mut" h2c)"
  case "${got}" in
  h2c\|*) ok "mutant relays h2c ('${got}') — the probe sees smuggling" ;;
  *) bad "mutant relayed '${got}', not h2c — the probe is blind" ;;
  esac
fi

step "3/3 verdict"
[ "${FAILED}" -eq 0 ] || {
  printf '\033[0;31m[M198] FAIL — the WAF relays a non-WebSocket upgrade, or the probe is blind\033[0m\n' >&2
  exit 1
}
printf '\033[0;32m[M198] PASS — only Upgrade: websocket reaches Kong; h2c is dropped\033[0m\n'
