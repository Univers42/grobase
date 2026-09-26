#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m207-edge-client-ip.sh — behind the WAF, Kong and its upstreams see the     #
#  real client, and nothing client-sent about where it came from (N-23).       #
#                                                                              #
#  Without KONG_TRUSTED_IPS Kong takes the WAF's bridge IP as every client's   #
#  address: ip-restriction lets the internet through (the WAF IP is private)  #
#  and every limit_by: ip counter, GoTrue's X-Real-IP limiter included, is     #
#  one shared bucket. Trusting the WAF makes Kong forward the X-Forwarded-*    #
#  it receives, so the WAF must overwrite X-Forwarded-For and drop a           #
#  client's X-Forwarded-Host/-Port/-Path/-Prefix (ipguard and the audit log    #
#  take the left-most X-Forwarded-For hop as the client).                      #
#                                                                              #
#    static  base renders no KONG_TRUSTED_IPS; prod and cloud trust the        #
#            private ranges; PROD_KONG_TRUSTED_IPS= opts out                   #
#    live    a client on a public-range bridge (TEST-NET-3) → the WAF image    #
#            with the repo config → Kong on a private bridge (repo kong.yml,   #
#            trusted IPs from the prod render) → a header-echo "postgrest":    #
#            /studio (ip-restricted) answers 403, and the upstream sees the    #
#            client's IP in X-Real-IP and first in X-Forwarded-For, and none   #
#            of its forged X-Forwarded-* values                                #
#    mutant  the pre-fix WAF header lines MUST leak the forged values, else    #
#            the probe is blind and the gate fails                             #
#  Ponytail: the client reaches the WAF on a bridge, so docker keeps its IP.   #
#  A client arriving through docker's userland proxy (IPv6 on a published      #
#  port) or a proxy in front of the WAF shows up as a private gateway IP and   #
#  passes ip-restriction; this gate cannot see that case.                      #
#  Needs .env, jq, the kong + WAF + node:20-alpine images (nothing pulled)     #
#  and certs/localhost{,-key}.pem; otherwise SKIP, exit 77, never 0.           #
# **************************************************************************** #
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONF="${M207_WAF_CONF:-${ROOT}/infra/docker/services/waf/conf/nginx.conf}"
WAF_IMG="${M207_WAF_IMAGE:-ghcr.io/univers42/grobase-waf:latest}"
NODE_IMG="${M207_NODE_IMAGE:-public.ecr.aws/docker/library/node:20-alpine}"
PRIVATE="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
TAG="m207gate$$"
WORK="$(mktemp -d)"
FAILED=0

ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
bad() {
  printf '\033[0;31m  ✗ %s\033[0m\n' "$*"
  FAILED=1
}
step() { printf '\033[0;36m[M207] %s\033[0m\n' "$*"; }

# skip prints why nothing was proven and exits 77.
skip() {
  printf '\033[0;33m[M207] SKIP — %s; nothing proven\033[0m\n' "$*"
  exit 77
}

# cleanup removes every container, both networks and the temp dir of this run.
cleanup() {
  docker rm -f "${TAG}-up" "${TAG}-kong" "${TAG}-waf" "${TAG}-mut" "${TAG}-cli" >/dev/null 2>&1 || true
  docker network rm "${TAG}-edge" "${TAG}-app" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

# render writes the compose config for files $2.. (every profile) to $1 as JSON.
render() {
  local out="$1"
  shift
  (cd "${ROOT}" && COMPOSE_PROFILES='*' docker compose "$@" config --format json) >"${out}" 2>"${WORK}/render.err" ||
    skip "compose does not render: $(head -c 300 "${WORK}/render.err")"
}

# trusted prints KONG_TRUSTED_IPS as rendered file $1 gives it to kong.
trusted() { jq -r '.services.kong.environment.KONG_TRUSTED_IPS // ""' "$1"; }

# preconditions checks the tools, images and files the live half needs.
preconditions() {
  command -v docker >/dev/null 2>&1 || skip "docker is not available"
  command -v jq >/dev/null 2>&1 || skip "jq is not available"
  [ -f "${ROOT}/.env" ] || skip ".env missing (make env)"
  [ -f "${ROOT}/certs/localhost.pem" ] && [ -f "${ROOT}/certs/localhost-key.pem" ] || skip "certs missing (make certs)"
  render "${WORK}/base.json" -f docker-compose.yml
  KONG_IMG="$(jq -r '.services.kong.image' "${WORK}/base.json")"
  for img in "${KONG_IMG}" "${WAF_IMG}" "${NODE_IMG}"; do
    docker image inspect "${img}" >/dev/null 2>&1 || skip "${img} is not present locally"
  done
}

# static_overlays asserts where KONG_TRUSTED_IPS is set and that it opts out.
static_overlays() {
  local prod=orchestrators/compose/docker-compose.prod.yml cloud="${WORK}/cloud.yml"
  : >"${WORK}/flags.env.cloud"
  sed "s#infra/config/cloud/flags\.env\.cloud#${WORK}/flags.env.cloud#g" \
    "${ROOT}/orchestrators/compose/docker-compose.cloud.yml" >"${cloud}"
  render "${WORK}/prod.json" -f docker-compose.yml -f "${prod}"
  render "${WORK}/cloud.json" -f docker-compose.yml -f "${cloud}"
  [ -z "$(trusted "${WORK}/base.json")" ] && ok "base: no KONG_TRUSTED_IPS (dev unchanged)" || bad "base sets KONG_TRUSTED_IPS"
  [ "$(trusted "${WORK}/prod.json")" = "${PRIVATE}" ] && ok "prod trusts ${PRIVATE}" || bad "prod KONG_TRUSTED_IPS='$(trusted "${WORK}/prod.json")'"
  [ "$(trusted "${WORK}/cloud.json")" = "${PRIVATE}" ] && ok "cloud trusts ${PRIVATE}" || bad "cloud KONG_TRUSTED_IPS='$(trusted "${WORK}/cloud.json")'"
  PROD_KONG_TRUSTED_IPS='' render "${WORK}/optout.json" -f docker-compose.yml -f "${prod}"
  [ -z "$(trusted "${WORK}/optout.json")" ] && ok "PROD_KONG_TRUSTED_IPS= opts out" || bad "PROD_KONG_TRUSTED_IPS= does not opt out"
}

# networks makes the public-range edge bridge and a private app bridge.
networks() {
  docker network create --internal --subnet 203.0.113.0/24 "${TAG}-edge" >/dev/null || skip "cannot create the edge network"
  docker network create --internal "${TAG}-app" >/dev/null || skip "cannot create the app network"
  docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "${TAG}-app" | grep -Eq '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' ||
    skip "docker gave the app network a non-private subnet"
}

# start_echo runs a node server on the app bridge as "postgrest" that answers
# every request with the headers it received, as JSON.
start_echo() {
  docker run -d --name "${TAG}-up" --network "${TAG}-app" --network-alias postgrest "${NODE_IMG}" node -e '
    require("http").createServer((q, r) => { r.setHeader("content-type", "application/json"); r.end(JSON.stringify(q.headers)); }).listen(3000);' >/dev/null ||
    skip "could not start the echo upstream"
}

# start_kong runs Kong as "kong" on the app bridge with the repo kong.yml and
# trusted IPs $1 (none when empty), and waits for its proxy.
start_kong() {
  local -a trust=()
  [ -z "$1" ] || trust=(-e "KONG_TRUSTED_IPS=$1")
  docker run -d --name "${TAG}-kong" --network "${TAG}-app" --network-alias kong --memory 1g "${trust[@]}" \
    -v "${ROOT}/infra/docker/services/kong/conf/kong.yml:/etc/kong/kong.yml.tmpl:ro" \
    -v "${ROOT}/infra/docker/services/kong/render-kong-config.sh:/etc/kong/render-kong-config.sh:ro" \
    -e KONG_DATABASE=off -e KONG_DECLARATIVE_CONFIG=/tmp/kong.yml -e KONG_NGINX_WORKER_PROCESSES=1 \
    -e KONG_MEM_CACHE_SIZE=64m -e KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES=cjson.safe \
    -e KONG_PUBLIC_API_KEY=m207-anon -e KONG_SERVICE_API_KEY=m207-service -e KONG_CORS_ORIGIN_DEV_LIST= \
    -e KONG_CORS_ORIGIN_APP=https://app.example -e KONG_CORS_ORIGIN_PLAYGROUND=https://app.example \
    -e KONG_CORS_ORIGIN_STUDIO=https://app.example -e KONG_CORS_ORIGIN_FRONTEND=https://app.example \
    -e JWT_SECRET=m207-dummy-jwt-secret-m207-dummy-jwt -e GOTRUE_JWT_ISS=http://localhost:8000/auth/v1 \
    -e KONG_ANON_UUID=cd4f782c-ac87-5081-b322-b54834d15651 --entrypoint sh "${KONG_IMG}" \
    -ec 'sh /etc/kong/render-kong-config.sh /etc/kong/kong.yml.tmpl /tmp/kong.yml
      exec /docker-entrypoint.sh kong docker-start' >/dev/null || skip "could not start kong"
  for _ in $(seq 1 60); do
    docker exec "${TAG}-kong" bash -c 'exec 3<>/dev/tcp/127.0.0.1/8000' 2>/dev/null && return
    sleep 1
  done
  skip "kong never served :8000 ($(docker logs "${TAG}-kong" 2>&1 | tail -n2))"
}

# start_waf runs WAF $1 with config $2 on the app bridge, then joins it to the
# edge bridge (m198 explains the per-container conf.d copy).
start_waf() {
  local dir="${WORK}/confd-$1"
  mkdir -p "${dir}" && cp "$2" "${dir}/default.conf" && chmod 0777 "${dir}" && chmod 0666 "${dir}/default.conf"
  docker run -d --name "$1" --network "${TAG}-app" -v "${dir}:/etc/nginx/conf.d" \
    -v "${ROOT}/certs/localhost.pem:/run/secrets/localhost_cert:ro" \
    -v "${ROOT}/certs/localhost-key.pem:/run/secrets/localhost_key:ro" "${WAF_IMG}" >/dev/null || return 1
  docker network connect "${TAG}-edge" "$1" || return 1
  for _ in $(seq 1 60); do
    send "$1" /waf-health '{}' | grep -q '"service":"waf"' && return 0
    sleep 1
  done
  return 1
}

# send prints "<status> <body>" for GET $2 on WAF $1 from the edge client with
# the extra headers in JSON object $3.
send() {
  docker exec -e WAF="$1" -e P="$2" -e H="$3" "${TAG}-cli" node -e '
    const h = Object.assign({ Host: "localhost" }, JSON.parse(process.env.H));
    const r = require("http").request({ host: process.env.WAF, port: 80, path: process.env.P, headers: h });
    r.on("response", (s) => { let b = ""; s.on("data", (c) => (b += c)); s.on("end", () => process.stdout.write(s.statusCode + " " + b)); });
    r.on("error", (e) => process.stdout.write("000 " + e.code));
    r.end();' 2>/dev/null
}

# forged is the header set a client uses to lie about where it came from.
forged() {
  printf '%s' '{"apikey":"m207-anon","X-Real-IP":"10.9.9.9","X-Forwarded-For":"10.9.9.9",
    "X-Forwarded-Host":"evil.example","X-Forwarded-Port":"1","X-Forwarded-Path":"/evil","X-Forwarded-Prefix":"/evil"}'
}

# leaks prints, for the echoed headers in file $1 and client IP $2, every way
# the upstream's view differs from the truth (nothing when it matches).
leaks() {
  jq -r --arg c "$2" '[
    (select(."x-real-ip" != $c) | "x-real-ip=\(."x-real-ip")"),
    (select((."x-forwarded-for" // "" | split(",")[0] | gsub(" "; "")) != $c) | "x-forwarded-for=\(."x-forwarded-for")"),
    (to_entries[] | select(.key | startswith("x-forwarded-")) | select(.value | test("evil|^1$|10\\.9\\.9\\.9")) | "\(.key)=\(.value)")
  ] | unique | join(" ")' "$1"
}

# live_edge proves the ip-restriction answer and the upstream's header view
# through WAF $1.
live_edge() {
  local cip out
  cip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${TAG}-edge\").IPAddress}}" "${TAG}-cli")"
  out="$(send "$1" /studio '{"X-Real-IP":"10.0.0.1","X-Forwarded-For":"10.0.0.1"}')"
  case "${out}" in
    "403 "*"not allowed"*) ok "/studio from ${cip}: 403 from ip-restriction despite a forged private X-Real-IP" ;;
    *) bad "/studio from public ${cip} got '${out:0:90}' — ip-restriction saw a private address" ;;
  esac
  out="$(send "$1" /rest/v1/m207 "$(forged)")"
  [ "${out%% *}" = 200 ] || bad "/rest/v1 through the edge got '${out:0:90}'"
  printf '%s' "${out#* }" >"${WORK}/seen.json"
  LEAKS="$(leaks "${WORK}/seen.json" "${cip}" 2>/dev/null || echo unparsed)"
}

step "0/3 preconditions"
preconditions
step "1/3 static: where Kong trusts the edge"
static_overlays
step "2/3 live: public client → WAF (${CONF#"${ROOT}"/}) → Kong (trusted: '$(trusted "${WORK}/prod.json")') → echo"
networks
start_echo
start_kong "$(trusted "${WORK}/prod.json")"
docker run -d --name "${TAG}-cli" --network "${TAG}-edge" "${NODE_IMG}" node -e 'setInterval(() => {}, 1e9)' >/dev/null ||
  skip "could not start the edge client"
start_waf "${TAG}-waf" "${CONF}" || skip "the WAF did not become healthy ($(docker logs "${TAG}-waf" 2>&1 | tail -n2))"
live_edge "${TAG}-waf"
[ -z "${LEAKS}" ] && ok "upstream sees the client's IP first and no forged X-Forwarded-*" || bad "upstream sees: ${LEAKS}"
step "3/3 mutant: the pre-fix WAF header lines must leak the forged values"
sed -e '/X-Forwarded-\(Host\|Port\|Path\|Prefix\)/d' -e 's/X-Forwarded-For   \$remote_addr;/X-Forwarded-For   $proxy_add_x_forwarded_for;/' \
  "${CONF}" >"${WORK}/mutant.conf"
if cmp -s "${CONF}" "${WORK}/mutant.conf"; then
  bad "mutant is identical to the config — the WAF header lines this gate relies on are gone"
else
  start_waf "${TAG}-mut" "${WORK}/mutant.conf" || skip "the mutant WAF did not start"
  live_edge "${TAG}-mut"
  [ -n "${LEAKS}" ] && ok "mutant leaks (${LEAKS}) — the probe can see a leak" || bad "mutant leaks nothing — the probe is blind"
fi
[ "${FAILED}" = 0 ] || {
  printf '\033[0;31m[M207] FAIL\033[0m\n'
  exit 1
}
printf '\033[0;32m[M207] PASS — Kong behind the WAF sees the real client; upstreams get no forged X-Forwarded-*\033[0m\n'
