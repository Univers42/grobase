#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m32-footprint.sh                                   :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/11 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/11 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Gate M32 — per-profile RESOURCE BUDGETS (regression guard).
#
# Each service tier must fit its RAM bar (running sum, via bench-footprint).
# Bars reflect the post-rebucket measured reality + headroom; `basic` is the
# hard Pi-class bar the lean edition promises. A tier that drifts over its bar
# (a new heavy default, a profile re-tagged into the wrong tier) fails CI here.
#
# Requires the stack up (it measures live containers). `make up PACKAGE=<t>`
# first for an exact reading; otherwise services in the set that are down count
# as 0 and the sum is a floor.
set -euo pipefail

green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# tier -> RAM bar (MiB). basic = the Pi-class promise; others guard regression.
TIERS=(basic essential pro max)
declare -A BAR=( [basic]=512 [essential]=1024 [pro]=1500 [max]=3700 )
# max re-baselined 3200→3700 (2026-06-13): fresh-idle measured 3551 — the
# platform grew legitimately (adapter-registry resolve-role budget, postgres
# max_connections=300, loki cap headroom); claims updated in QUICKSTART/
# DEPLOYMENT/RELEASE to ~3.5 GiB in the same commit.

rc=0
for tier in "${TIERS[@]}"; do
  cyan "[M32] ${tier} — budget ${BAR[$tier]} MiB"
  if make -C "${ROOT}" --no-print-directory bench-footprint PACKAGE="${tier}" BAR_MB="${BAR[$tier]}" \
        >/tmp/m32-${tier}.txt 2>&1; then
    grep -E 'TOTAL|budget' /tmp/m32-${tier}.txt
  else
    grep -E 'TOTAL|budget|✗' /tmp/m32-${tier}.txt || cat /tmp/m32-${tier}.txt
    red "[M32] FAIL: ${tier} exceeds its ${BAR[$tier]} MiB budget"
    rc=1
  fi
done

if [[ "${rc}" == "0" ]]; then
  green "[M32] ALL TIERS WITHIN BUDGET — basic ≤512 (Pi-class), essential/pro/max within bars"
else
  red "[M32] one or more tiers over budget"
fi
exit "${rc}"
