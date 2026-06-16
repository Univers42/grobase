#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m38-load.sh                                        :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/11 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/11 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Load gate (program phase A6): a 60s k6 smoke of the canonical CRUD mix at the
# tier's advertised rps must hold p95 + error rate inside budgets.json. Locks
# the bench numbers into CI — a regression that makes /data/v1 slower or starts
# dropping requests at the advertised rate fails here, not in production.
#
# verify-all auto-discovers this; it must stay CHEAP — one 60s run on whatever
# package is up (PACKAGE=essential default), and SKIP (exit 0) when the stack
# is down (the m32/m36 precedent: a gate can't measure an absent stack).
#
# MODE=full (3×300s) and other PACKAGEs are the on-demand deep runs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

green(){ printf '\033[0;32m[M38] %s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m[M38] FAIL: %s\033[0m\n' "$*"; }
cyan(){ printf '\033[0;36m[M38] %s\033[0m\n' "$*"; }
skip(){ printf '\033[1;33m[M38] SKIP: %s\033[0m\n' "$*"; exit 0; }

PACKAGE="${PACKAGE:-essential}"
WORKLOAD="${WORKLOAD:-crud}"
BUDGETS="${ROOT}/scripts/bench/budgets.json"

# Stack-up guard: the data plane + kong + tenant-control must be live.
docker inspect mini-baas-data-plane-router-rust >/dev/null 2>&1 || skip "data plane not up (make up PACKAGE=${PACKAGE})"
[[ "$(docker inspect --format '{{.State.Health.Status}}' mini-baas-kong 2>/dev/null)" == "healthy" ]] || skip "kong not healthy"
[[ "$(docker inspect --format '{{.State.Health.Status}}' mini-baas-tenant-control 2>/dev/null)" == "healthy" ]] || skip "tenant-control not healthy"

P95_BAR="$(jq -r ".load.${PACKAGE}.p95_ms" "${BUDGETS}")"
ERR_BAR="$(jq -r ".load.${PACKAGE}.err_pct" "${BUDGETS}")"
RATE="$(jq -r ".load.${PACKAGE}.rps" "${BUDGETS}")"
[[ "${P95_BAR}" != "null" ]] || skip "no load budget for package ${PACKAGE}"

cyan "60s load smoke: ${PACKAGE}/${WORKLOAD} @ ${RATE} rps (bars: p95 ≤ ${P95_BAR}ms, err ≤ ${ERR_BAR}%)"

# One 60s measured run (MODE=short runs 3×; here we just need one for the gate).
ART="${ROOT}/artifacts/bench/load-${PACKAGE}-${WORKLOAD}.json"
PACKAGE="${PACKAGE}" WORKLOAD="${WORKLOAD}" MODE=short RATE="${RATE}" \
	bash "${ROOT}/scripts/bench/load.sh" >/tmp/m38-load.txt 2>&1 || { cat /tmp/m38-load.txt; red "load run failed"; exit 1; }
tail -2 /tmp/m38-load.txt

[[ -f "${ART}" ]] || { red "no artifact at ${ART}"; exit 1; }
P95="$(jq -r '.median.http.p95' "${ART}")"
ERRP="$(jq -r '.median.err_pct' "${ART}")"

fail=0
awk -v a="${P95}" -v b="${P95_BAR}" 'BEGIN{exit !(a>b)}' && { red "p95 ${P95}ms > ${P95_BAR}ms"; fail=1; }
awk -v a="${ERRP}" -v b="${ERR_BAR}" 'BEGIN{exit !(a>b)}' && { red "error rate ${ERRP}% > ${ERR_BAR}%"; fail=1; }
[[ "${fail}" == 0 ]] || exit 1

green "PASS — ${PACKAGE} sustains ${RATE} rps: p95 ${P95}ms ≤ ${P95_BAR}, err ${ERRP}% ≤ ${ERR_BAR}% (${ART#${ROOT}/})"
