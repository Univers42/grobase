#!/usr/bin/env bash
# **************************************************************************** #
# m237-edge-compression.sh — the WAF gzips ONLY an allowlist of data routes    #
#                                                                              #
# Gzipping a response whose body mixes a secret with attacker-reflected input  #
# is BREACH-readable. The WAF config (infra/docker/services/waf/conf/nginx.conf)#
# therefore compresses exactly three routing shapes and nothing else:          #
#   ^/rest/v1/(?!rpc/)   table rows (rpc is uncompressed)                      #
#   ^/data/v1/                                                         #
#   /query/v1/execute    the one exact path, not /query/v1/*           #
# Every other route (auth, keys, OTP, signed URLs, rpc, functions, admin,      #
# realtime, sessions, query non-execute, …) must stay uncompressed.            #
#                                                                              #
# It boots the WAF image with that config on a private network whose `kong` is #
# a Content-Type: application/json, 4096-byte echo upstream, then requests     #
# each route from the echo container with Accept-Encoding: gzip and reads the  #
# response's content-encoding back: 'gzip' on the allowlist, '-' otherwise.    #
# Leg 2 also probes *every literal prefix* in Kong's config (gate m237 keeps   #
# Kong as the source of truth), and the mutant leg flips the base `gzip off;`  #
# to `on;` — if /auth/v1/token then is not 'gzip', the probe is blind.         #
#                                                                              #
# Ponytail: Kong regex paths (entries starting with '~') are NOT probed —      #
# nginx matches prefixes, Kong matches patterns, so a regex route's data path  #
# is covered only if a literal prefix above already covers it.                 #
#                                                                              #
# Needs docker, the WAF image and node:20-alpine already present (nothing is   #
# pulled) and certs/localhost{,-key}.pem; otherwise SKIP, exit 77, never 0.    #
# Containers, network and temp dir go in an EXIT trap.                         #
# M237_CONF=<path> tests another config (a mutant that gzips auth must go red).#
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONF="${M237_CONF:-${ROOT}/infra/docker/services/waf/conf/nginx.conf}"
WAF_IMG="${M237_WAF_IMAGE:-ghcr.io/univers42/grobase-waf:latest}"
NODE_IMG="${M237_NODE_IMAGE:-mirror.gcr.io/library/node:20-alpine}"
KONG_YML="${ROOT}/infra/docker/services/kong/conf/kong.yml"
CERT="${ROOT}/certs/localhost.pem"
KEY="${ROOT}/certs/localhost-key.pem"
TAG="m237gate$$"
NET="${TAG}-net"
WORK="$(mktemp -d)"
FAILED=0

ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
bad() {
  printf '\033[0;31m  ✗ %s\033[0m\n' "$*"
  FAILED=1
}
step() { printf '\033[0;36m[M237] %s\033[0m\n' "$*"; }

# skip REASON: print why nothing was proven and exit 77 (a gate that did not look has not passed).
skip() {
  printf '\033[0;33m[M237] SKIP — %s; nothing proven\033[0m\n' "$*"
  exit 77
}

# cleanup: remove every container, the network and the temp dir this run made.
cleanup() {
  docker rm -f "${TAG}-kong" "${TAG}-waf" "${TAG}-mut" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

# preconditions: docker, both images present locally, the TLS pair the WAF config loads,
# the two configs, and a grep that speaks PCRE (the allowlist regexes are -P only).
preconditions() {
  command -v docker >/dev/null 2>&1 || skip "docker is not available"
  docker image inspect "${WAF_IMG}" >/dev/null 2>&1 || skip "${WAF_IMG} is not present (make build-svc-waf)"
  docker image inspect "${NODE_IMG}" >/dev/null 2>&1 || skip "${NODE_IMG} is not present"
  [ -f "${CERT}" ] && [ -f "${KEY}" ] || skip "certs/localhost.pem + key are missing (make certs)"
  [ -f "${CONF}" ] || skip "${CONF} not found"
  [ -f "${KONG_YML}" ] || skip "${KONG_YML} not found"
  printf 'x' | grep -qP 'x' 2>/dev/null || skip "grep -P is unavailable"
}

# health_body WAF: GET /waf-health from the echo container and print the JSON body ("" until up).
health_body() {
  docker exec -e WAF="$1" "${TAG}-kong" node -e '
    const r = require("http").request({ host: process.env.WAF, port: 80, path: "/waf-health", headers: { Host: "localhost" } });
    r.on("response", (s) => { let b = ""; s.on("data", (c) => (b += c)); s.on("end", () => process.stdout.write(b)); });
    r.on("error", () => {});
    r.end();' 2>/dev/null
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
    [ "$(health_body "${name}")" = '{"status":"ok","service":"waf"}' ] && return 0
    sleep 1
  done
  docker logs "${name}" 2>&1 | tail -5 >&2
  return 1
}

# probe WAF PATH METHOD: METHOD WAF:80/PATH from the echo container with Host: localhost and
# Accept-Encoding: gzip; print the response content-encoding header, or '-' when absent.
probe() {
  docker exec -e WAF="$1" -e P="$2" -e M="$3" "${TAG}-kong" node -e '
    const r = require("http").request({ host: process.env.WAF, port: 80, path: process.env.P, method: process.env.M,
      headers: { Host: "localhost", "Accept-Encoding": "gzip" } });
    r.on("response", (s) => { s.resume(); s.on("end", () => process.stdout.write(s.headers["content-encoding"] || "-")); });
    r.on("error", () => { process.stdout.write("error"); });
    r.end();' 2>/dev/null
}

# allowlisted PATH: true when PATH matches one of the three allowlist regexes the WAF gzips.
allowlisted() {
  printf '%s' "$1" | grep -qP '^/rest/v1/(?!rpc/)|^/data/v1/|^/query/v1/execute$'
}

# kong_prefixes: every literal (non-'~') path prefix listed under `paths:` in Kong's config,
# inline arrays and `- /x` list items alike, deduplicated.
kong_prefixes() {
  awk '
    /^[[:space:]]*paths:[[:space:]]*\[/ {
      line = $0; sub(/^[^[]*\[/, "", line); sub(/\].*/, "", line)
      n = split(line, parts, ",")
      for (i = 1; i <= n; i++) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[i]); print parts[i] }
      next
    }
    /^[[:space:]]*paths:[[:space:]]*$/ { listing = 1; next }
    listing && /^[[:space:]]*-/ { line = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", line); sub(/[[:space:]]+$/, "", line); print line; next }
    listing { listing = 0 }
  ' "${KONG_YML}" | grep -v '^[[:space:]]*~' | grep -v '^[[:space:]]*$' | sort -u
}

# expect LABEL GOT WANT: record a pass or a failure for one probe.
expect() {
  if [ "$2" = "$3" ]; then ok "$1: content-encoding '$2'"; else bad "$1: content-encoding '$2', want '$3'"; fi
}

# check_route METHOD PATH WANT: probe METHOD PATH on the real WAF and record it against WANT.
check_route() {
  expect "$1 $2" "$(probe "${TAG}-waf" "$2" "$1")" "$3"
}

step "0/4 preconditions"
preconditions
docker network create "${NET}" >/dev/null || skip "could not create a docker network"
docker run -d --name "${TAG}-kong" --network "${NET}" --network-alias kong "${NODE_IMG}" node -e '
  require("http").createServer((q, r) => { r.setHeader("content-type", "application/json"); r.end(JSON.stringify({ pad: "x".repeat(4086) })); }).listen(8000);' >/dev/null ||
  skip "could not start the echo upstream"

step "1/4 real config: the gzip allowlist"
start_waf "${TAG}-waf" "${CONF}" || {
  bad "the WAF did not become healthy with this config"
  exit 1
}
check_route GET /rest/v1/osionos_pages gzip
check_route POST /rest/v1/osionos_pages gzip
check_route GET /data/v1/query gzip
check_route POST /query/v1/execute gzip
check_route POST /rest/v1/rpc/mint -
check_route GET /auth/v1/token -
check_route POST /auth/v1/token -
check_route GET /v1/tenants/me/keys -
check_route POST /v1/auth/otp/verify -
check_route GET /storage/v1/sign/b/o -
check_route GET /functions/v1/f -
check_route GET /admin/v1/keys -
check_route GET /query/v1/other -
check_route GET /sessions/v1/x -
check_route GET /realtime/v1/x -

step "2/4 every literal Kong path prefix stays uncompressed unless allowlisted"
prefixes_seen=0
while read -r prefix; do
  [ -n "${prefix}" ] || continue
  target="${prefix}/m237"
  want='-'
  allowlisted "${target}" && want='gzip'
  check_route GET "${target}" "${want}"
  prefixes_seen=$((prefixes_seen + 1))
done < <(kong_prefixes)
[ "${prefixes_seen}" -gt 0 ] || bad "no literal Kong path prefixes found in ${KONG_YML} — extraction broke"

step "3/4 mutant: base gzip off -> on must compress /auth/v1/token, else the probe is blind"
sed 's/^    gzip              off;/    gzip              on;/' "${CONF}" >"${WORK}/mutant.conf"
if cmp -s "${CONF}" "${WORK}/mutant.conf"; then
  bad "mutant: the base 'gzip off;' line is not in the config any more — rebuild this leg"
elif ! start_waf "${TAG}-mut" "${WORK}/mutant.conf"; then
  bad "mutant: the WAF did not start with the mutant config"
else
  got="$(probe "${TAG}-mut" /auth/v1/token GET)"
  case "${got}" in
  gzip) ok "mutant gzips /auth/v1/token ('${got}') — the probe sees compression" ;;
  *) bad "mutant left /auth/v1/token '${got}' — the probe is blind" ;;
  esac
fi

step "4/4 verdict"
[ "${FAILED}" -eq 0 ] || {
  printf '\033[0;31m[M237] FAIL — the WAF gzips outside the data-route allowlist, or the probe is blind\033[0m\n' >&2
  exit 1
}
printf '\033[0;32m[M237] PASS — only the data-route allowlist is compressed; everything else stays plain\033[0m\n'
