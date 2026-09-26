#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m204-security-events.sh — a rejected credential is visible end to end.      #
#                                                                              #
#  Sends M204_N requests with a bogus X-Baas-Api-Key through Kong to           #
#  query-router (all answered 401 by its ApiKey middleware) and proves each    #
#  observability layer saw them:                                               #
#    (1) Kong's kong_http_requests_total{code="401"} grew by N                  #
#    (2) query-router's mini_baas_http_requests_total{status_code="401"} grew  #
#        by N — the counter an interceptor used to miss                        #
#    (3) query-router logged N http_request lines with                         #
#        event_type=auth_failure                                               #
#    (4) Prometheus scraped them: the AuthFailureSpike and                     #
#        AppPlaneAuthRejections expressions (rate > 0) return the series       #
#    (5) Loki can select them by the event_type label (when loki runs)         #
#  Needs kong + query-router + prometheus running; otherwise prints SKIP, or   #
#  fails under M204_REQUIRE=1 (CI, where a skip would pass vacuously).         #
#                                                                              #
#  Ponytail: (1)–(3) compare before/after on a live stack, so concurrent       #
#  401s from other traffic can only make a count larger — the check is ">=",   #
#  and a real regression still reads 0. (4) needs both 401 series to exist    #
#  in Prometheus before the burst: a counter born with its value already at    #
#  N has no earlier sample, so rate() reads 0. One warm-up 401 first.          #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
N="${M204_N:-20}"
NET="${M204_NET:-mini-baas_mini-baas}"
CURL_IMG="curlimages/curl:8.10.1"
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M204] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M204] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

# running reports whether container $1 is up.
running() {
  docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true
}

# in_net runs curl inside the stack network with the given arguments.
in_net() {
  docker run --rm --network "${NET}" "${CURL_IMG}" -s "$@"
}

# metric_sum prints the sum of the samples in the /metrics text on stdin that
# match the metric name $1 and contain every label fragment in $2.
metric_sum() {
  awk -v name="$1" -v frag="$2" '
    index($0, name "{") == 1 {
      n = split(frag, parts, ",")
      for (i = 1; i <= n; i++) if (index($0, parts[i]) == 0) next
      total += $NF
    }
    END { printf "%d\n", total }'
}

# kong_401 prints Kong's 401 count for the query-router service.
kong_401() {
  in_net http://kong:8001/metrics | metric_sum kong_http_requests_total 'service="query-router",code="401"'
}

# router_401 prints query-router's own 401 count.
router_401() {
  in_net http://query-router:4001/metrics | metric_sum mini_baas_http_requests_total 'status_code="401"'
}

# prom_query prints the number of series PromQL expression $1 returns.
prom_query() {
  docker exec mini-baas-prometheus /bin/busybox wget -qO- \
    "http://localhost:9090/api/v1/query?query=$(jq -rn --arg q "$1" '$q|@uri')" |
    jq '.data.result | length'
}

# poll retries command $1 (a function printing a number) until it prints >= 1,
# for up to 45 s, and prints the last value.
poll() {
  local v=0 i
  for i in $(seq 1 15); do
    v="$("$1" 2>/dev/null || echo 0)"
    [ "${v:-0}" -ge 1 ] && break
    sleep 3
  done
  printf '%s\n' "${v:-0}"
}

# bogus sends one request with a bogus API key through Kong to query-router
# and prints the status code.
bogus() {
  in_net -o /dev/null -w '%{http_code}\n' -H "apikey: ${anon}" \
    -H 'X-Baas-Api-Key: mbk_m204_not_a_key' http://kong:8000/query/v1/m204/tables
}

kong_seen() { prom_query 'kong_http_requests_total{code="401",service="query-router"}'; }
app_seen() { prom_query 'mini_baas_http_requests_total{status_code="401"}'; }

for c in mini-baas-kong mini-baas-query-router mini-baas-prometheus; do
  running "${c}" || {
    [ "${M204_REQUIRE:-0}" = 1 ] && fail "${c} is not running (M204_REQUIRE=1)"
    printf '  SKIP: %s is not running (make up PACKAGE=max)\n' "${c}"
    exit 0
  }
done

anon="$(grep -E '^ANON_KEY=' .env 2>/dev/null | cut -d= -f2-)"
step "warm up: one rejected request, until Prometheus holds both 401 series"
[ "$(bogus)" = 401 ] || fail "the warm-up request was not answered 401"
[ "$(poll kong_seen)" -ge 1 ] || fail "Prometheus holds no kong 401 series for query-router after 45 s (kong not scraped?)"
[ "$(poll app_seen)" -ge 1 ] || fail "Prometheus holds no query-router 401 series after 45 s (query-router not scraped?)"
ok "both 401 series are scraped"

step "send ${N} requests with a bogus API key through Kong"
since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
k0="$(kong_401)"
r0="$(router_401)"
codes="$(for _ in $(seq 1 "${N}"); do bogus; done | sort | uniq -c | tr -s ' ' | tr '\n' ';')"
[ "${codes}" = " ${N} 401;" ] || fail "expected ${N}×401, got:${codes}"
ok "${N} × 401"

step "(1)(2) counters"
k1="$(kong_401)"
r1="$(router_401)"
[ $((k1 - k0)) -ge "${N}" ] || fail "kong 401 counter grew by $((k1 - k0)), want >= ${N}"
ok "kong_http_requests_total{code=\"401\"} +$((k1 - k0))"
[ $((r1 - r0)) -ge "${N}" ] || fail "query-router 401 counter grew by $((r1 - r0)), want >= ${N} (rejections not counted)"
ok "mini_baas_http_requests_total{status_code=\"401\"} +$((r1 - r0))"

step "(3) http_request log lines"
logged="$(docker logs --since "${since}" mini-baas-query-router 2>&1 |
  grep -c '"status_code":401,.*"event_type":"auth_failure"')"
[ "${logged}" -ge "${N}" ] || fail "${logged} auth_failure log lines, want >= ${N}"
ok "${logged} lines carry event_type=auth_failure"

step "(4) the alert expressions see the scraped series"
kong_rate() { prom_query 'sum by (service) (rate(kong_http_requests_total{code="401"}[5m])) > 0'; }
app_rate() { prom_query 'sum by (service) (rate(mini_baas_http_requests_total{status_code=~"401|403"}[5m])) > 0'; }
[ "$(poll kong_rate)" -ge 1 ] || fail "AuthFailureSpike's expression returns nothing after 45 s"
ok "AuthFailureSpike expression has data"
[ "$(poll app_rate)" -ge 1 ] || fail "AppPlaneAuthRejections' expression returns nothing after 45 s (query-router not scraped?)"
ok "AppPlaneAuthRejections expression has data"

step "(5) Loki selects them by label"
if running mini-baas-loki && running mini-baas-promtail; then
  loki_hits() {
    in_net -G http://loki:3100/loki/api/v1/query_range \
      --data-urlencode 'query={event_type="auth_failure",service="query-router"}' \
      --data-urlencode "start=$(($(date +%s) - 600))000000000" |
      jq '[.data.result[].values | length] | add // 0'
  }
  [ "$(poll loki_hits)" -ge 1 ] || fail "Loki has no {event_type=\"auth_failure\"} lines after 45 s"
  ok "Loki {event_type=\"auth_failure\",service=\"query-router\"} returns lines"
else
  printf '  SKIP: loki/promtail not running (observability plane)\n'
fi

printf '\033[0;32m[M204] OK — a rejected credential shows in Kong, the service, Prometheus and Loki\033[0m\n'
