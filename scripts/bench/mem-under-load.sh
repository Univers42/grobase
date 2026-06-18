#!/usr/bin/env bash
# **************************************************************************** #
#    mem-under-load.sh — RSS under sustained load (program A3)                 #
# **************************************************************************** #
#
# footprint.sh measures RSS at REST. This measures it UNDER LOAD: it starts a
# sustained k6 CRUD run in the background, samples `docker stats` for the data
# plane every 5s, and reports peak RSS + a drift slope (MiB/h — a positive slope
# under steady load is the leak signal footprint.sh can't see). Pairs with the
# scale metrics (B3): pool/cache growth shows up here as RSS growth.
#
# Env: PACKAGE (label), DURATION (default 30m), RATE (default tier rps), TARGET
#      (container, default mini-baas-data-plane-router-rust)
# Output: artifacts/bench/mem-<PACKAGE>.json
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/lib-bench.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/lib-live-tenant.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/lib-workload.sh"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }

PACKAGE="${PACKAGE:-essential}"
DURATION="${DURATION:-30m}"
RATE="${RATE:-$(bench_budget ".load.${PACKAGE}.rps" 2>/dev/null || echo 50)}"
[[ "${RATE}" == "null" ]] && RATE=50
TARGET="${TARGET:-mini-baas-data-plane-router-rust}"
TABLE="bench_items"
SAMPLE_SECS=5

# Seconds from a Go-style duration (30m, 1800s, 1h).
dur_secs() { case "$1" in *h) echo $((${1%h} * 3600)) ;; *m) echo $((${1%m} * 60)) ;; *s) echo "${1%s}" ;; *) echo "$1" ;; esac }
TOTAL="$(dur_secs "${DURATION}")"

cyan "[bench-mem] ${TARGET} RSS under ${RATE} rps for ${DURATION} (sample ${SAMPLE_SECS}s)"
live_tenant_provision "bench-mem-$(date +%s)" || {
  red "provision failed"
  exit 1
}
trap 'bw_drop_table "${TABLE}"; kill "${K6_PID:-0}" 2>/dev/null || true; live_tenant_cleanup' EXIT
bw_setup_table "${TABLE}" || {
  red "working-set setup failed"
  exit 1
}

# Background load for the whole window.
bench_k6 "crud.js" "mem-load-${PACKAGE}.json" \
  -e BASE="${LIVE_KONG_URL}" -e ANON="${LIVE_ANON_APIKEY}" -e APPK="${LIVE_TENANT_API_KEY}" \
  -e DBID="${LIVE_TENANT_DB_ID}" -e TABLE="${TABLE}" -e RATE="${RATE}" -e DURATION="${TOTAL}s" \
  >/dev/null 2>&1 &
K6_PID=$!

# Sample RSS until the load finishes.
SAMPLES="[]"
t=0
while kill -0 "${K6_PID}" 2>/dev/null && ((t < TOTAL + 10)); do
  rss="$(docker stats --no-stream --format '{{.MemUsage}}' "${TARGET}" 2>/dev/null | awk '{print $1}' | sed 's/MiB//;s/GiB/*1024/' | bc 2>/dev/null | cut -d. -f1)"
  [[ -n "${rss}" ]] && SAMPLES="$(jq -c --argjson t "${t}" --argjson r "${rss:-0}" '. + [{t:$t, rss_mib:$r}]' <<<"${SAMPLES}")"
  sleep "${SAMPLE_SECS}"
  t=$((t + SAMPLE_SECS))
done
wait "${K6_PID}" 2>/dev/null || true
rm -f "${BENCH_OUT_DIR}/mem-load-${PACKAGE}.json"

# Peak + linear drift slope (MiB/h) via least squares over (t, rss).
FINAL="${BENCH_OUT_DIR}/mem-${PACKAGE}.json"
jq -n --arg package "${PACKAGE}" --argjson rate "${RATE}" --arg target "${TARGET}" \
  --argjson samples "${SAMPLES}" --argjson env "$(bench_env_json)" '
	($samples | length) as $n |
	(if $n > 1 then
		($samples | map(.t) | add / $n) as $mt |
		($samples | map(.rss_mib) | add / $n) as $mr |
		($samples | map((.t - $mt) * (.rss_mib - $mr)) | add) as $cov |
		($samples | map((.t - $mt) * (.t - $mt)) | add) as $vt |
		(if $vt > 0 then ($cov / $vt) * 3600 else 0 end)
	else 0 end) as $slope |
	{package:$package, target:$target, rate_rps:$rate,
	 peak_rss_mib: ($samples | map(.rss_mib) | max // 0),
	 first_rss_mib: ($samples[0].rss_mib // 0),
	 last_rss_mib: ($samples[-1].rss_mib // 0),
	 drift_mib_per_h: ($slope | (. * 10 | round) / 10),
	 samples:$samples, env:$env}' >"${FINAL}"

green "[bench-mem] $(jq -r '"peak \(.peak_rss_mib)MiB  drift \(.drift_mib_per_h)MiB/h  (\(.first_rss_mib)→\(.last_rss_mib))"' "${FINAL}") → ${FINAL#${BENCH_ROOT}/}"
