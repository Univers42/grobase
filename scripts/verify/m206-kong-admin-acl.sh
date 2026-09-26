#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m206-kong-admin-acl.sh — every internal-only Kong route needs the           #
#  service_role key, not only a private source IP (N-24).                      #
#                                                                              #
#    A throwaway Kong (no network, the repo kong.yml rendered by the repo's    #
#    render-kong-config.sh from dummy keys) is asked, over its own admin API,  #
#    which routes carry ip-restriction; each must also carry acl allow        #
#    [baas-admin]. Then, from 127.0.0.1 (inside every ip-restriction          #
#    allowlist), each such route answers the anon key with the acl 403 and    #
#    lets the service key through (the upstream is absent, so "through" is    #
#    any answer but that 403). No service may point at the studio container:  #
#    Studio holds the service_role key, has no login, and is reached on       #
#    127.0.0.1:3000 or an SSH tunnel, never through the gateway (N-25).       #
#  Why: ip-restriction alone is one proxy hop from useless — behind the WAF   #
#  every client arrives from a private bridge IP (N-23).                      #
#  No stack needed; needs the kong image locally (M206_KONG_IMAGE overrides). #
#                                                                              #
# **************************************************************************** #
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=scripts/lib/lib-kong-scratch.sh
. "${ROOT}/scripts/lib/lib-kong-scratch.sh"
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

# kbody prints just the body of admin GET $1.
kbody() { kong_scratch_get "${K}" 8001 "$1" | tr -d '\r' | awk 'b { print } /^$/ { b = 1 }'; }

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
status() { kong_scratch_status "${K}" 8000 "$1" "apikey: $2"; }

# body_of prints the proxy's raw answer to GET $1 with apikey $2.
body_of() { kong_scratch_get "${K}" 8000 "$1" "apikey: $2"; }

# assert_no_studio fails when any Kong service targets the studio container.
assert_no_studio() {
  local hit
  hit="$(kbody '/services?size=1000' | jq -r '[.data[] | select(.host == "studio") | .name] | join(" ")')"
  [ -z "${hit}" ] || fail "Kong service(s) ${hit} route to studio — an unauthenticated console holding the service key"
  ok "no Kong service routes to the studio container"
}

# assert_acl proves every ip-restricted route is acl-gated, statically
# and by probing it with both keys.
assert_acl() {
  local name path acl n=0
  while read -r name path acl; do
    [ "${acl}" = true ] || fail "route ${name} (${path}) is ip-restricted but not acl baas-admin — the public anon key passes it"
    [ "$(status "${path}" scratch-anon)" = 403 ] || fail "${path}: anon key not refused with 403"
    body_of "${path}" scratch-anon | grep -q 'cannot consume this service' || fail "${path}: the 403 is not the acl's"
    ! body_of "${path}" scratch-service | grep -q 'cannot consume this service' || fail "${path}: service key refused by the acl"
    n=$((n + 1))
  done <"${T}/gated"
  [ "${n}" -ge 10 ] || fail "only ${n} gated routes found — the check would be near-vacuous"
  ok "${n} ip-restricted routes: acl baas-admin present, anon key 403 by the acl, service key passes"
}

command -v jq >/dev/null || fail "jq is required"
printf '\033[0;36m[M206] throwaway kong: ip-restricted routes need the service_role key\033[0m\n'
IMG="$(kong_image)"
docker image inspect "${IMG}" >/dev/null 2>&1 || fail "kong image ${IMG} not present locally (make build-svc-kong, or docker pull)"
kong_scratch_start "${K}" "${IMG}" none || fail "could not start throwaway kong"
kong_scratch_wait "${K}" || fail "throwaway kong never served :8000"
gated_routes >"${T}/gated"
assert_no_studio
assert_acl
printf '\033[0;32m[M206] PASS — no internal-only Kong route is open to the public anon key\033[0m\n'
