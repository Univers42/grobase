#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m206-kong-admin-acl.sh — every internal-only Kong route needs the           #
#  service_role key, not only a private source IP (N-24).                      #
#                                                                              #
#    A throwaway Kong (no network, the repo kong.yml rendered by the repo's    #
#    render-kong-config.sh from dummy keys) is asked, over its own admin API,  #
#    which routes carry ip-restriction; each of them except the browser UI    #
#    /studio must also carry acl allow [baas-admin]. Then, from 127.0.0.1     #
#    (inside every ip-restriction allowlist), each such route answers the     #
#    anon key with the acl 403 and lets the service key through (the         #
#    upstream is absent, so "through" is any answer but that 403).           #
#  Why: ip-restriction alone is one proxy hop from useless — behind the WAF   #
#  every client arrives from a private bridge IP (N-23).                      #
#  No stack needed; needs the kong image locally (M206_KONG_IMAGE overrides). #
#                                                                              #
# **************************************************************************** #
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
K="m206-kong-$$"
T="$(mktemp -d)"
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M206] FAIL: %s\033[0m\n' "$*" >&2
  exit 1
}
cleanup() {
  docker rm -f "${K}" >/dev/null 2>&1 || true
  rm -rf "${T}"
}
trap cleanup EXIT

# kong_image prints the kong image the base compose file names, or the override.
kong_image() {
  [ -z "${M206_KONG_IMAGE:-}" ] || {
    printf '%s\n' "${M206_KONG_IMAGE}"
    return
  }
  (cd "${ROOT}" && docker compose config --format json) | jq -r '.services.kong.image'
}

# start_kong runs throwaway Kong ${K} from image $1 on no network.
start_kong() {
  docker run -d --name "${K}" --network none --memory 1g \
    -v "${ROOT}/infra/docker/services/kong/conf/kong.yml:/etc/kong/kong.yml.tmpl:ro" \
    -v "${ROOT}/infra/docker/services/kong/render-kong-config.sh:/etc/kong/render-kong-config.sh:ro" \
    -e KONG_DATABASE=off -e KONG_DECLARATIVE_CONFIG=/tmp/kong.yml -e KONG_NGINX_WORKER_PROCESSES=1 \
    -e KONG_MEM_CACHE_SIZE=64m -e KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES=cjson.safe \
    -e KONG_PUBLIC_API_KEY=m206-anon -e KONG_SERVICE_API_KEY=m206-service \
    -e KONG_CORS_ORIGIN_APP=https://app.example -e KONG_CORS_ORIGIN_PLAYGROUND=https://app.example \
    -e KONG_CORS_ORIGIN_STUDIO=https://app.example -e KONG_CORS_ORIGIN_FRONTEND=https://app.example \
    -e KONG_CORS_ORIGIN_DEV_LIST= -e JWT_SECRET=m206-dummy-jwt-secret-m206-dummy-jwt \
    -e GOTRUE_JWT_ISS=http://localhost:8000/auth/v1 -e KONG_ANON_UUID=cd4f782c-ac87-5081-b322-b54834d15651 \
    --entrypoint sh "$1" -ec 'sh /etc/kong/render-kong-config.sh /etc/kong/kong.yml.tmpl /tmp/kong.yml
      exec /docker-entrypoint.sh kong docker-start' >/dev/null || fail "could not start throwaway kong"
}

# kreq prints Kong's raw HTTP answer to GET $2 on port $1 with apikey $3 (bash
# /dev/tcp: the image ships no curl), REFUSED when nothing listens.
kreq() {
  docker exec "${K}" bash -c "exec 3<>/dev/tcp/127.0.0.1/$1 && printf 'GET $2 HTTP/1.0\r\nHost: localhost\r\napikey: $3\r\n\r\n' >&3 && cat <&3" \
    2>/dev/null || printf 'REFUSED\n'
}

# kbody prints just the body of admin GET $1.
kbody() { kreq 8001 "$1" none | tr -d '\r' | awk 'b { print } /^$/ { b = 1 }'; }

# wait_kong waits up to 60 s for the admin API to answer.
wait_kong() {
  local i
  for i in $(seq 1 60); do
    kreq 8001 /status none | head -n1 | grep -q ' 200' && return
    sleep 1
  done
  fail "throwaway kong never served its admin API ($(docker logs "${K}" 2>&1 | tail -n3))"
}

# gated_routes writes "<name> <first path> <has-acl>" for every route that
# carries ip-restriction, from Kong's own parsed config.
gated_routes() {
  kbody '/routes?size=1000' >"${T}/routes.json"
  kbody '/plugins?size=1000' >"${T}/plugins.json"
  jq -r --slurpfile p "${T}/plugins.json" '.data[] | . as $r
    | [$p[0].data[] | select(.route.id == $r.id)] as $mine
    | select(any($mine[]; .name == "ip-restriction"))
    | "\($r.name) \($r.paths[0]) \(any($mine[]; .name == "acl" and ((.config.allow // []) | index("baas-admin"))))"' \
    "${T}/routes.json"
}

# status prints the HTTP status of proxy GET $1 with apikey $2.
status() { kreq 8000 "$1" "$2" | head -n1 | tr -d '\r' | awk '{ print $2 }'; }

# assert_acl proves every ip-restricted route but studio is acl-gated, statically
# and by probing it with both keys.
assert_acl() {
  local name path acl n=0
  while read -r name path acl; do
    [ "${name}" != studio-routes ] || continue
    [ "${acl}" = true ] || fail "route ${name} (${path}) is ip-restricted but not acl baas-admin — the public anon key passes it"
    [ "$(status "${path}" m206-anon)" = 403 ] || fail "${path}: anon key not refused with 403"
    kreq 8000 "${path}" m206-anon | grep -q 'cannot consume this service' || fail "${path}: the 403 is not the acl's"
    ! kreq 8000 "${path}" m206-service | grep -q 'cannot consume this service' || fail "${path}: service key refused by the acl"
    n=$((n + 1))
  done <"${T}/gated"
  [ "${n}" -ge 10 ] || fail "only ${n} gated routes found — the check would be near-vacuous"
  ok "${n} ip-restricted routes: acl baas-admin present, anon key 403 by the acl, service key passes"
}

command -v jq >/dev/null || fail "jq is required"
printf '\033[0;36m[M206] throwaway kong: ip-restricted routes need the service_role key\033[0m\n'
IMG="$(kong_image)"
docker image inspect "${IMG}" >/dev/null 2>&1 || fail "kong image ${IMG} not present locally (make build-svc-kong, or docker pull)"
start_kong "${IMG}"
wait_kong
gated_routes >"${T}/gated"
grep -q '^studio-routes ' "${T}/gated" || fail "studio-routes lost its ip-restriction"
assert_acl
printf '\033[0;32m[M206] PASS — no internal-only Kong route is open to the public anon key\033[0m\n'
