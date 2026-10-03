#!/usr/bin/env bash
# M213 — the public spec's POST /query/v1/execute (operation queryExecute), which
# every SDK calls (query.run, the from() builder, client.engine), is served
# behind Kong instead of answering 404.
#  (1) STATIC: the OpenAPI spec, the JS SDK route map and the query-router
#      controller all name the route
#  (2) LIVE: through Kong with only the anon key, an unknown sibling path
#      answers 404 (control) while /query/v1/execute answers 401 — its AuthGuard
#      refused the missing credential, so the route exists. Until 2026-10-03 it
#      answered 404.
#  Needs kong + query-router running for (2); otherwise prints SKIP, or fails
#  under M213_REQUIRE=1 (CI, where a skip would pass vacuously).
#
#  Ponytail: (2) proves routing and the guard, not a data round trip; the
#  mapping onto ExecuteQueryDto and its refusals are pinned by
#  src/apps/query-router/src/query/query.controller.spec.ts.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NET="${M213_NET:-mini-baas_mini-baas}"
CURL_IMG="curlimages/curl:8.10.1"
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

# post sends a JSON POST through Kong with only the anon key to path $1 and
# prints the status code.
post() {
  docker run --rm --network "${NET}" "${CURL_IMG}" -s -o /dev/null -w '%{http_code}' \
    -X POST -H "apikey: ${anon}" -H 'Content-Type: application/json' \
    -d "${BODY}" "http://kong:8000$1"
}

step "STATIC — spec, JS SDK and query-router agree on POST /query/v1/execute"
jq -e '.paths["/query/v1/execute"].post.operationId == "queryExecute"' \
  "${ROOT}/infra/config/openapi/grobase-public.json" >/dev/null ||
  fail "the OpenAPI spec has no queryExecute at POST /query/v1/execute"
grep -q "execute: '/query/v1/execute'" "${ROOT}/sdks/js/src/core/routes.ts" ||
  fail "the JS SDK route map no longer names /query/v1/execute"
grep -q "@Post('execute')" "${ROOT}/src/apps/query-router/src/query/query.controller.ts" ||
  fail "query-router's root QueryController serves no POST /execute"
ok "spec, SDK and controller all name the route"

step "LIVE — through Kong, the route answers its guard (401), not 404"
for c in mini-baas-kong mini-baas-query-router; do
  running "${c}" || {
    [ "${M213_REQUIRE:-0}" = 1 ] && fail "${c} is not running (M213_REQUIRE=1)"
    printf '  SKIP: %s is not running (make up)\n' "${c}"
    exit 0
  }
done
anon="$(grep -E '^ANON_KEY=' "${ROOT}/.env" 2>/dev/null | cut -d= -f2-)"
[ -n "${anon}" ] || fail "no ANON_KEY in .env"
none="$(post /query/v1/m213-no-such-route)"
[ "${none}" = 404 ] || fail "control: an unknown path answered ${none}, not 404, so a 401 would prove nothing"
ok "an unknown path → 404"
code="$(post /query/v1/execute)"
[ "${code}" = 401 ] || fail "POST /query/v1/execute answered ${code}; want 401 (route served, credential refused)"
ok "POST /query/v1/execute → 401"
printf '\033[0;32m[M213] PASS\033[0m\n'
