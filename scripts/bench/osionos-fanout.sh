#!/usr/bin/env bash
#
# Workspace-open fan-out bench through the edge (WAF :8443 → Kong → PostgREST).
# Replays the osionos bridge's open in two shapes (k6/fanout.js: n1 vs batched),
# on the local path and through a toxiproxy that adds the round-trip time of the
# Funnel relay hairpin, and records the cgroup CPU throttling each run caused.
# Non-disruptive: it reads, never writes, and measures whatever stack is up.
#
# Inputs (env):
#   WS           workspace uuid (default: the one with the most live pages)
#   EDGE         edge origin (default https://127.0.0.1:8443)
#   RTT_MS       simulated round trip for the toxic leg (default 200, the low end
#                of the measured 200–700 ms warm Funnel cost); 0 skips that leg
#   BURST ITER   concurrent opens and opens per VU for the batched shape
#                (default 50 × 3); n1 runs 5 × 1 locally and 1 × 1 under toxic
#   TAG          artifact suffix (default before) → artifacts/bench/perf-osionos-<TAG>.json
#
# The service_role key and Kong service key are read from .env into a 0600
# env-file in a private temp dir, removed on exit — never argv, never output.
#
# Ponytail: the n1 shape is inferred from kong.yml:195,223 (page rows + a
# membership check per page), not from bridge source; the real bridge may
# fan out less (or more). The toxic leg models RTT only — it does not model the
# 3.5 s cold TLS rebuild, so it under-states the cold path.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BENCH_ROOT="${ROOT}"
# shellcheck source=../lib/lib-bench.sh
. "${ROOT}/scripts/lib/lib-bench.sh"

EDGE="${EDGE:-https://127.0.0.1:8443}"
RTT_MS="${RTT_MS:-200}"
BURST="${BURST:-50}"
ITER="${ITER:-3}"
TAG="${TAG:-before}"
TOXI_IMAGE="${TOXI_IMAGE:-ghcr.io/shopify/toxiproxy:2.12.0}"
TOXI_NAME="osionos-fanout-toxi"
TOXI_PORT=18443
THROTTLE_CONTAINERS="mini-baas-waf mini-baas-kong mini-baas-postgrest mini-baas-postgres"

TMP="$(mktemp -d)"
chmod 700 "${TMP}"

# cleanup removes the credential file and the toxiproxy container.
cleanup() {
  rm -rf "${TMP}"
  docker rm -f "${TOXI_NAME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# env_value prints one key's value from .env without echoing it elsewhere.
env_value() {
  grep -E "^$1=" "${ROOT}/.env" | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//'
}

# write_cred_file writes the k6 credential env-file (0600, private temp dir).
write_cred_file() {
  umask 077
  {
    printf 'ANON=%s\n' "$(env_value KONG_SERVICE_API_KEY)"
    printf 'JWT=%s\n' "$(env_value SERVICE_ROLE_KEY)"
  } >"${TMP}/cred.env"
}

# pick_workspace prints the workspace with the most live pages.
pick_workspace() {
  docker exec mini-baas-postgres psql -U postgres -d postgres -Atc \
    "select workspace_id from osionos_pages where archived_at is null group by 1 order by count(*) desc limit 1"
}

# throttled_usec prints "<container> <throttled_usec>" for each watched container.
throttled_usec() {
  local c id f
  for c in ${THROTTLE_CONTAINERS}; do
    id="$(docker inspect -f '{{.Id}}' "${c}" 2>/dev/null)" || continue
    f="$(find /sys/fs/cgroup -path "*${id}*" -name cpu.stat 2>/dev/null | head -1)"
    printf '%s %s\n' "${c}" "$(awk '/^throttled_usec/{print $2}' "${f}" 2>/dev/null || echo 0)"
  done
}

# throttle_delta_json turns two throttled_usec snapshots into {container: ms}.
throttle_delta_json() {
  join <(sort "$1") <(sort "$2") |
    jq -Rn '[inputs | split(" ") | {(.[0]): (((.[2]|tonumber) - (.[1]|tonumber)) / 1000 | round)}] | add'
}

# run_shape runs one k6 shape against an origin and prints its artifact path.
# @param $1 label  $2 origin  $3 mode  $4 burst  $5 iter
run_shape() {
  local label="$1" origin="$2" mode="$3" burst="$4" iter="$5" out="fanout-${TAG}-$1.json"
  throttled_usec >"${TMP}/t0"
  docker run --rm --network host -u "$(id -u):$(id -g)" \
    -v "${BENCH_DIR}/k6:/scripts:ro" -v "${BENCH_OUT_DIR}:/out" \
    --env-file "${TMP}/cred.env" \
    -e "BASE=${origin}" -e "WS=${WS}" -e "MODE=${mode}" -e "BURST=${burst}" -e "ITER=${iter}" \
    -e "K6_OUT_FILE=/out/${out}" \
    "${K6_IMAGE}" run --quiet /scripts/fanout.js >&2
  throttled_usec >"${TMP}/t1"
  jq --argjson thr "$(throttle_delta_json "${TMP}/t0" "${TMP}/t1")" --arg label "${label}" \
    '. + {label: $label, throttled_ms: $thr}' "${BENCH_OUT_DIR}/${out}" >"${TMP}/r.json"
  mv "${TMP}/r.json" "${BENCH_OUT_DIR}/${out}"
  printf '%s\n' "${BENCH_OUT_DIR}/${out}"
}

# start_toxiproxy proxies 127.0.0.1:TOXI_PORT → the edge with RTT_MS round trip.
start_toxiproxy() {
  local half=$((RTT_MS / 2)) api="http://127.0.0.1:8474"
  docker run -d --rm --name "${TOXI_NAME}" --network host "${TOXI_IMAGE}" >/dev/null
  for _ in $(seq 1 30); do curl -sf "${api}/version" >/dev/null && break; sleep 0.3; done
  curl -sf -XPOST "${api}/proxies" -d "{\"name\":\"edge\",\"listen\":\"127.0.0.1:${TOXI_PORT}\",\"upstream\":\"${EDGE#https://}\"}" >/dev/null
  for stream in upstream downstream; do
    curl -sf -XPOST "${api}/proxies/edge/toxics" \
      -d "{\"name\":\"lat-${stream}\",\"type\":\"latency\",\"stream\":\"${stream}\",\"attributes\":{\"latency\":${half},\"jitter\":$((half / 5))}}" >/dev/null
  done
}

# main runs every leg and assembles artifacts/bench/perf-osionos-<TAG>.json.
main() {
  WS="${WS:-$(pick_workspace)}"
  write_cred_file
  local legs=()
  legs+=("$(run_shape local-batched "${EDGE}" batched "${BURST}" "${ITER}")")
  legs+=("$(run_shape local-n1 "${EDGE}" n1 5 1)")
  if [ "${RTT_MS}" -gt 0 ]; then
    start_toxiproxy
    legs+=("$(run_shape "rtt${RTT_MS}-batched" "https://127.0.0.1:${TOXI_PORT}" batched 1 3)")
    legs+=("$(run_shape "rtt${RTT_MS}-n1" "https://127.0.0.1:${TOXI_PORT}" n1 1 1)")
  fi
  jq -s --argjson env "$(bench_env_json)" --arg ws "${WS}" --arg rtt "${RTT_MS}" \
    --arg cmd "TAG=${TAG} RTT_MS=${RTT_MS} BURST=${BURST} ITER=${ITER} bash scripts/bench/osionos-fanout.sh" \
    '{env: $env, workspace: $ws, rtt_ms: ($rtt|tonumber), reproduce: $cmd, legs: .}' "${legs[@]}" \
    >"${BENCH_OUT_DIR}/perf-osionos-${TAG}.json"
  jq -r '.legs[] | "\(.label)\topen p50=\(.open_ms.med)ms p95=\(.open_ms.p95)ms\trt/open=\(.round_trips_per_open)\twire/open=\(.wire_bytes_per_open)B\terr=\(.err_pct)%\t429=\(.rate_limited)\tthrottled=\(.throttled_ms)"' \
    "${BENCH_OUT_DIR}/perf-osionos-${TAG}.json"
}

main "$@"
