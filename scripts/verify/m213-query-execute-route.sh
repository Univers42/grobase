#!/usr/bin/env bash
# M213 — the public spec's POST /query/v1/execute (operation queryExecute), which
# every SDK calls (query.run, the from() builder, client.engine), is served by
# query-router behind Kong instead of answering 404.
#  (1) STATIC: the OpenAPI spec, the JS SDK route map and the query-router
#      controller all name the route
#  (2) LIVE, query-router direct with no credential: an unknown sibling path
#      answers 404 (control) while POST /execute answers its AuthGuard's 401
#      ("Missing verified identity"), so the route exists and is guarded. Until
#      2026-10-03 it answered 404.
#  (3) LIVE, through Kong with the anon key: POST /query/v1/execute reaches
#      query-router, whose api-key middleware refuses the anon key as an app key
#      (invalid_api_key). Through Kong every /query/v1 path answers that same 401,
#      which is why (2) talks to query-router directly.
#  Needs kong + query-router running for (2) and (3); otherwise prints SKIP, or
#  fails under M213_REQUIRE=1 (CI, where a skip would pass vacuously).
#
#  Ponytail: (2) and (3) prove routing and the guards, not a data round trip; the
#  mapping onto ExecuteQueryDto and its refusals are pinned by
#  src/apps/query-router/src/query/query.controller.spec.ts.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NET="${M213_NET:-mini-baas_mini-baas}"
CURL_IMG="curlimages/curl:8.10.1"
QR="http://query-router:4001"
BODY='{"database_id":"11111111-1111-4111-8111-111111111111","action":"list","resource":"m213"}'

step() { printf '\033[0;36m[M213] %s\033[0m\n' "$*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M213] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

# running reports whether container $1 is up.
running() {
  docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true
}

# post sends a JSON POST to URL $1, with the apikey header $2 when given, and
# prints the response body, a newline, then the status code.
post() {
  local key=()
  [ -n "${2:-}" ] && key=(-H "apikey: $2")
  docker run --rm --network "${NET}" "${CURL_IMG}" -s -w '\n%{http_code}' -X POST \
    "${key[@]}" -H 'Content-Type: application/json' -d "${BODY}" "$1"
}

# status prints the status code of a post() result $1; body prints its body.
status() { printf '%s' "${1##*$'\n'}"; }
body() { printf '%s' "${1%$'\n'*}"; }

step "STATIC — spec, JS SDK and query-router agree on POST /query/v1/execute"
jq -e '.paths["/query/v1/execute"].post.operationId == "queryExecute"' \
  "${ROOT}/infra/config/openapi/grobase-public.json" >/dev/null ||
  fail "the OpenAPI spec has no queryExecute at POST /query/v1/execute"
grep -q "execute: '/query/v1/execute'" "${ROOT}/sdks/js/src/core/routes.ts" ||
  fail "the JS SDK route map no longer names /query/v1/execute"
grep -q "@Post('execute')" "${ROOT}/src/apps/query-router/src/query/query.controller.ts" ||
  fail "query-router's root QueryController serves no POST /execute"
ok "spec, SDK and controller all name the route"

step "LIVE — query-router serves POST /execute behind its AuthGuard"
for c in mini-baas-kong mini-baas-query-router; do
  running "${c}" || {
    [ "${M213_REQUIRE:-0}" = 1 ] && fail "${c} is not running (M213_REQUIRE=1)"
    printf '  SKIP: %s is not running (make up)\n' "${c}"
    exit 0
  }
done
none="$(post "${QR}/m213-no-such-route")"
[ "$(status "${none}")" = 404 ] ||
  fail "control: an unknown path answered $(status "${none}"), not 404, so a 401 would prove nothing"
ok "an unknown path → 404"
direct="$(post "${QR}/execute")"
[ "$(status "${direct}")" = 401 ] ||
  fail "POST /execute answered $(status "${direct}"); want 401 (route served, no identity)"
body "${direct}" | grep -q 'Missing verified identity' ||
  fail "POST /execute answered 401 but not from AuthGuard: $(body "${direct}")"
ok "POST /execute → 401 Missing verified identity"

step "LIVE — Kong forwards /query/v1/execute to query-router"
anon="$(grep -E '^ANON_KEY=' "${ROOT}/.env" 2>/dev/null | cut -d= -f2-)"
[ -n "${anon}" ] || fail "no ANON_KEY in .env"
via="$(post http://kong:8000/query/v1/execute "${anon}")"
if [ "$(status "${via}")" != 401 ] || ! body "${via}" | grep -q invalid_api_key; then
  fail "through Kong, POST /query/v1/execute answered $(status "${via}") $(body "${via}"); want query-router's 401 invalid_api_key"
fi
ok "through Kong → query-router's 401 invalid_api_key"
printf '\033[0;32m[M213] PASS\033[0m\n'
