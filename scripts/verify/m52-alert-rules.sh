#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m52-alert-rules.sh                                 :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M52 — the Prometheus config + platform alert rules are valid (Track-2 E2).
#
# Pure static check (Docker-first, no running stack needed): runs promtool from
# the pinned prom image against the committed config + rules. Catches a broken
# rule expression / bad YAML before it silently disables alerting at deploy.
# When a prometheus container IS running, also asserts the rules actually loaded.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M52] $*"; }
pass()  { green "[M52] PASS: $*"; }
fail()  { red "[M52] FAIL: $*"; exit 1; }

PROM_IMG="prom/prometheus:v2.52.0"
CFG="${BAAS_DIR}/config/prometheus"

[ -f "${CFG}/prometheus.yml" ] || fail "prometheus.yml missing"
[ -d "${CFG}/rules" ] || fail "rules/ dir missing"

# ── 1) rules parse + expressions compile ─────────────────────────────────────
step "promtool check rules"
docker run --rm --entrypoint promtool -v "${CFG}":/cfg "${PROM_IMG}" \
  check rules /cfg/rules/platform.yml >/tmp/m52-rules.txt 2>&1 \
  || { cat /tmp/m52-rules.txt; fail "rule validation failed"; }
grep -q 'SUCCESS' /tmp/m52-rules.txt || { cat /tmp/m52-rules.txt; fail "no SUCCESS in promtool output"; }
RULES_N="$(grep -oE '[0-9]+ rules found' /tmp/m52-rules.txt | grep -oE '[0-9]+' | head -1)"
[ "${RULES_N:-0}" -ge 1 ] || fail "no rules found"
pass "${RULES_N} alert rules valid"

# ── 2) full config (rule_files glob resolves) ────────────────────────────────
step "promtool check config"
docker run --rm --entrypoint promtool -v "${CFG}":/etc/prometheus "${PROM_IMG}" \
  check config /etc/prometheus/prometheus.yml >/tmp/m52-cfg.txt 2>&1 \
  || { cat /tmp/m52-cfg.txt; fail "config validation failed"; }
grep -q 'rule files found' /tmp/m52-cfg.txt || fail "prometheus.yml does not load any rule files (rule_files missing?)"
pass "prometheus config valid + rule_files wired"

# ── 3) live: rules actually loaded (only when prometheus is up) ───────────────
if docker inspect -f '{{.State.Running}}' mini-baas-prometheus 2>/dev/null | grep -q true; then
  step "live: rules loaded into running prometheus"
  port="$(docker port mini-baas-prometheus 9090/tcp 2>/dev/null | head -1 | sed 's/.*://')"
  if [ -n "${port}" ]; then
    groups="$(curl -s "http://127.0.0.1:${port}/api/v1/rules" 2>/dev/null | grep -o '"name":"platform-' | wc -l)"
    [ "${groups}" -ge 1 ] || fail "prometheus is up but loaded 0 platform rule groups (reload needed?)"
    pass "prometheus has the platform rule groups loaded"
  fi
fi

green "[M52] ALL GATES GREEN — Prometheus config + ${RULES_N} platform alert rules validate"
