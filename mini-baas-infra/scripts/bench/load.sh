#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    load.sh                                            :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/11 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/11 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Sustained-load benchmark of the PRODUCT PATH (Kong → /data/v1 → Rust plane →
# postgres) under the canonical CRUD mix (METHOD.md). Non-disruptive like
# footprint.sh: measures whatever stack shape is up — `make up PACKAGE=<t>`
# first for an exact-tier reading.
#
# The bench tenant rides the `enterprise` plan (lib-live-tenant default) so the
# tier token bucket never interferes BELOW the probed rate: this script
# measures the PLANE at a tier's advertised rate; mask honesty (403/429 walls)
# is m28's job. Note for Phase C: tenants.plan CHECK only admits
# free|pro|enterprise — `basic` is not even assignable today (offer finding).
#
# Inputs (env):
#   PACKAGE    tier label for the artifact + default RATE from budgets.json
#   WORKLOAD   crud | aggregate | batch        (default crud)
#   MODE       short = 3×60s | full = 3×300s   (default short)
#   RATE       override req/s (default: budgets.json .load.<PACKAGE>.rps)
#
# Output: artifacts/bench/load-<PACKAGE>-<WORKLOAD>.json  (3 runs + median + env)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-bench.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../verify/lib-live-tenant.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-workload.sh"

cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }

PACKAGE="${PACKAGE:-essential}"
WORKLOAD="${WORKLOAD:-crud}"
MODE="${MODE:-short}"
RATE="${RATE:-$(bench_budget ".load.${PACKAGE}.rps" 2>/dev/null || echo 50)}"
[[ "${RATE}" == "null" ]] && RATE=50
DURATION="60s"; [[ "${MODE}" == "full" ]] && DURATION="300s"
TABLE="bench_items"
LABEL="load-${PACKAGE}-${WORKLOAD}"

case "${WORKLOAD}" in crud|aggregate|batch) ;; *) red "unknown WORKLOAD ${WORKLOAD}"; exit 2;; esac

cyan "[bench-load] ${PACKAGE}/${WORKLOAD} — rate ${RATE} rps × 3×${DURATION} (+30s warmup) through Kong /data/v1"

# ── bench tenant + mount (fresh, cleaned on exit) ───────────────────────────
live_tenant_provision "bench-load-$(date +%s)" || { red "provision failed (stack up?)"; exit 1; }
trap 'bw_drop_table "${TABLE}"; live_tenant_cleanup' EXIT
KONG="${LIVE_KONG_URL}"

# ── table + 500-row working set (METHOD.md canonical shape) ─────────────────
cyan "[bench-load] creating ${TABLE} + seeding 500 rows"
bw_setup_table "${TABLE}" || { red "working-set setup failed"; exit 1; }
green "[bench-load] seeded"

# ── k6: 30s warmup (discarded) + 3 measured runs ────────────────────────────
run_k6() { # $1 out-file $2 duration
	bench_k6 "${WORKLOAD}.js" "$1" \
		-e BASE="${KONG}" -e ANON="${LIVE_ANON_APIKEY}" -e APPK="${LIVE_TENANT_API_KEY}" \
		-e DBID="${LIVE_TENANT_DB_ID}" -e TABLE="${TABLE}" \
		-e RATE="${RATE}" -e DURATION="$2"
}

cyan "[bench-load] warmup 30s (discarded)"
run_k6 "${LABEL}-warmup.json" "30s" >/dev/null

RUNS=()
for n in 1 2 3; do
	cyan "[bench-load] run ${n}/3 (${DURATION})"
	run_k6 "${LABEL}-run${n}.json" "${DURATION}"
	RUNS+=("${BENCH_OUT_DIR}/${LABEL}-run${n}.json")
done

MEDIAN="$(bench_median3_by '.rps_achieved' "${RUNS[@]}")"

# ── final artifact: 3 runs + median + env ───────────────────────────────────
FINAL="${BENCH_OUT_DIR}/${LABEL}.json"
jq -n \
	--arg package "${PACKAGE}" --arg workload "${WORKLOAD}" --arg mode "${MODE}" \
	--argjson rate "${RATE}" \
	--slurpfile r1 "${RUNS[0]}" --slurpfile r2 "${RUNS[1]}" --slurpfile r3 "${RUNS[2]}" \
	--slurpfile median "${MEDIAN}" \
	--argjson env "$(bench_env_json)" \
	'{package:$package, workload:$workload, mode:$mode, rate_target:$rate,
	  median:$median[0], runs:[$r1[0],$r2[0],$r3[0]], env:$env}' \
	> "${FINAL}"
rm -f "${BENCH_OUT_DIR}/${LABEL}-warmup.json"

green "[bench-load] artifact: ${FINAL#${BENCH_ROOT}/}"
jq -r '"  median: rps=\(.median.rps_achieved) p50=\(.median.http.med)ms p95=\(.median.http.p95)ms p99=\(.median.http.p99)ms err=\(.median.err_pct)% 429s=\(.median.rate_limited)"' "${FINAL}"
