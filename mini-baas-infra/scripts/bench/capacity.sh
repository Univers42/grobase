#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    capacity.sh                                        :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/11 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/11 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Capacity discovery (A2): what can the plane ACTUALLY sustain? Steps the
# canonical CRUD mix up a doubling ladder (30s per stage) until p95 breaks the
# SLO (budgets.json .capacity.slo_p95_ms) or errors exceed the bar, then
# binary-searches between the last good and first bad rate. The result
# parameterises the Phase-C offer formula: advertised tier rps must be a
# measured number × a safety factor, never an invention.
#
# The bench tenant rides `enterprise` (max tier: 2000 rps bucket). If a stage
# fails on 429s rather than latency, the wall is the TIER BUCKET, not the
# plane — reported as limit_hit:"tier_rps" (re-run against a stack with
# PACKAGE_ENFORCEMENT=0 to chase the raw plane ceiling past it).
#
# Inputs (env): PACKAGE (artifact label), LADDER_MAX (default 3200)
# Output: artifacts/bench/capacity-<PACKAGE>.json

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
LADDER_MAX="${LADDER_MAX:-3200}"
# WORKLOAD=read (default) finds the pure READ ceiling — the plane's raw
# throughput, isolated from the write-path outbox tail latency. WORKLOAD=crud
# finds the realistic mixed-workload ceiling. Both are honest; pick the question.
WORKLOAD="${WORKLOAD:-read}"
K6_SCRIPT="${WORKLOAD}.js"
TABLE="bench_items"
SLO_P95="$(bench_budget '.capacity.slo_p95_ms')"
ERR_BAR="$(bench_budget '.capacity.err_pct')"
STAGE_SECS="30s"

cyan "[bench-capacity] ${PACKAGE} — CRUD mix ladder to the wall (SLO p95 ≤ ${SLO_P95}ms, err ≤ ${ERR_BAR}%)"

live_tenant_provision "bench-cap-$(date +%s)" || { red "provision failed (stack up?)"; exit 1; }
trap 'bw_drop_table "${TABLE}"; live_tenant_cleanup' EXIT
bw_setup_table "${TABLE}" || { red "working-set setup failed"; exit 1; }
green "[bench-capacity] working set ready"

# Warmup (METHOD.md rule 3): a fresh bench tenant's first requests are all cold
# — verify-miss (Argon2id ~50ms), mount-miss (adapter-registry), pool-open.
# Without this the first ladder stage measures cold-start, not plane capacity.
cyan "[bench-capacity] 20s warmup (cold caches → warm; discarded)"
bench_k6 "${K6_SCRIPT}" "${BENCH_OUT_DIR}/capacity-warmup.json" \
	-e BASE="${LIVE_KONG_URL}" -e ANON="${LIVE_ANON_APIKEY}" -e APPK="${LIVE_TENANT_API_KEY}" \
	-e DBID="${LIVE_TENANT_DB_ID}" -e TABLE="${TABLE}" -e RATE="25" -e DURATION="20s" >/dev/null 2>&1 || true
rm -f "${BENCH_OUT_DIR}/capacity-warmup.json"

STAGES_JSON="[]"
LIMIT_HIT="none"

# Run one 30s stage at $1 rps; echoes "ok|latency|errors|tier_rps p95 err rps429"
stage() {
	# Separate declarations: a single `local rate=… out=…${rate}…` evaluates
	# the second RHS before `rate` is bound (bash + set -u → unbound var).
	local rate="$1"
	local out="${BENCH_OUT_DIR}/capacity-stage-${rate}.json"
	bench_k6 "${K6_SCRIPT}" "${out}" \
		-e BASE="${LIVE_KONG_URL}" -e ANON="${LIVE_ANON_APIKEY}" -e APPK="${LIVE_TENANT_API_KEY}" \
		-e DBID="${LIVE_TENANT_DB_ID}" -e TABLE="${TABLE}" \
		-e RATE="${rate}" -e DURATION="${STAGE_SECS}" >/dev/null
	local p95 err limited
	p95="$(jq -r '.http.p95 // 99999' "${out}")"
	err="$(jq -r '.err_pct // 100' "${out}")"
	limited="$(jq -r '.rate_limited // 0' "${out}")"
	local verdict="ok"
	if [[ "${limited}" != "0" ]]; then verdict="tier_rps"
	elif awk -v a="${err}" -v b="${ERR_BAR}" 'BEGIN{exit !(a>b)}'; then verdict="errors"
	elif awk -v a="${p95}" -v b="${SLO_P95}" 'BEGIN{exit !(a>b)}'; then verdict="latency"
	fi
	# Echo verdict + the per-stage artifact path; the CALLER accumulates
	# STAGES_JSON (a subshell command-substitution can't mutate it here).
	echo "${verdict} ${p95} ${err} ${limited} ${out}"
}

accumulate() { # $1 stage artifact, $2 rate
	[[ -f "$1" ]] || return 0
	STAGES_JSON="$(jq -c --argjson r "$2" --slurpfile s "$1" '. + [{rate:$r}+$s[0]]' <<<"${STAGES_JSON}")"
}

LAST_GOOD=0
FIRST_BAD=0
RATE=25
while (( RATE <= LADDER_MAX )); do
	cyan "[bench-capacity] stage ${RATE} rps × ${STAGE_SECS}"
	read -r VERDICT P95 ERR LIMITED OUT <<<"$(stage "${RATE}")"
	accumulate "${OUT}" "${RATE}"
	echo "  → ${VERDICT} (p95=${P95}ms err=${ERR}% 429s=${LIMITED})"
	if [[ "${VERDICT}" == "ok" ]]; then
		LAST_GOOD="${RATE}"
		RATE=$(( RATE * 2 ))
	else
		FIRST_BAD="${RATE}"
		LIMIT_HIT="${VERDICT}"
		break
	fi
done

# Binary-search refinement (2 iterations) between last good and first bad.
if (( FIRST_BAD > 0 && LAST_GOOD > 0 )); then
	LO="${LAST_GOOD}"; HI="${FIRST_BAD}"
	for _ in 1 2; do
		MID=$(( (LO + HI) / 2 ))
		(( MID <= LO )) && break
		cyan "[bench-capacity] refine ${MID} rps"
		read -r VERDICT P95 ERR LIMITED OUT <<<"$(stage "${MID}")"
		accumulate "${OUT}" "${MID}"
		echo "  → ${VERDICT} (p95=${P95}ms err=${ERR}% 429s=${LIMITED})"
		if [[ "${VERDICT}" == "ok" ]]; then LO="${MID}"; else HI="${MID}"; fi
	done
	LAST_GOOD="${LO}"
fi

FINAL="${BENCH_OUT_DIR}/capacity-${PACKAGE}.json"
jq -n \
	--arg package "${PACKAGE}" --arg workload "${WORKLOAD}" --arg limit_hit "${LIMIT_HIT}" \
	--argjson max_rps "${LAST_GOOD}" --argjson slo "${SLO_P95}" \
	--argjson stages "${STAGES_JSON}" --argjson env "$(bench_env_json)" \
	'{package:$package, workload:$workload, max_sustained_rps:$max_rps, slo_p95_ms:$slo,
	  limit_hit:$limit_hit, stages:$stages, env:$env}' > "${FINAL}"
rm -f "${BENCH_OUT_DIR}"/capacity-stage-*.json

green "[bench-capacity] max sustained ≈ ${LAST_GOOD} rps (wall: ${LIMIT_HIT}) → ${FINAL#${BENCH_ROOT}/}"
