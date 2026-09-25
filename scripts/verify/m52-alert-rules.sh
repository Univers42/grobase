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
# Static (Docker-first, no running stack needed): promtool from the pinned prom
# image checks the committed rules and config, then runs the rule unit tests
# (tests/platform.test.yml) — each alert fires on the synthetic series it is
# meant for and stays quiet on the rest. When a prometheus container IS
# running, also asserts the rules loaded and that no target is a service the
# edition never started (a DNS failure = a permanent, meaningless TargetDown).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
step() { cyan "[M52] $*"; }
pass() { green "[M52] PASS: $*"; }
fail() {
  red "[M52] FAIL: $*"
  exit 1
}

PROM_IMG="prom/prometheus:v2.52.0"
CFG="${M52_CFG:-${BAAS_DIR}/infra/config/prometheus}"

[ -f "${CFG}/prometheus.yml" ] || fail "prometheus.yml missing"
[ -d "${CFG}/rules" ] || fail "rules/ dir missing"

# ── 1) rules parse + expressions compile ─────────────────────────────────────
step "promtool check rules"
docker run --rm --entrypoint promtool -v "${CFG}":/cfg "${PROM_IMG}" \
  check rules /cfg/rules/platform.yml >/tmp/m52-rules.txt 2>&1 ||
  {
    cat /tmp/m52-rules.txt
    fail "rule validation failed"
  }
grep -q 'SUCCESS' /tmp/m52-rules.txt || {
  cat /tmp/m52-rules.txt
  fail "no SUCCESS in promtool output"
}
RULES_N="$(grep -oE '[0-9]+ rules found' /tmp/m52-rules.txt | grep -oE '[0-9]+' | head -1)"
[ "${RULES_N:-0}" -ge 1 ] || fail "no rules found"
pass "${RULES_N} alert rules valid"

# ── 2) full config (rule_files glob resolves) ────────────────────────────────
step "promtool check config"
docker run --rm --entrypoint promtool -v "${CFG}":/etc/prometheus "${PROM_IMG}" \
  check config /etc/prometheus/prometheus.yml >/tmp/m52-cfg.txt 2>&1 ||
  {
    cat /tmp/m52-cfg.txt
    fail "config validation failed"
  }
grep -q 'rule files found' /tmp/m52-cfg.txt || fail "prometheus.yml does not load any rule files (rule_files missing?)"
pass "prometheus config valid + rule_files wired"

# ── 3) rule unit tests ──────────────────────────────────────────────────────
step "promtool test rules"
docker run --rm --entrypoint promtool -v "${CFG}":/cfg -w /cfg/tests "${PROM_IMG}" \
  test rules platform.test.yml >/tmp/m52-test.txt 2>&1 ||
  {
    cat /tmp/m52-test.txt
    fail "rule unit tests failed"
  }
pass "rule unit tests pass"

# ── 4) live: rules loaded, no phantom targets (only when prometheus is up) ────
prom_api() {
  docker exec mini-baas-prometheus /bin/busybox wget -qO- "http://localhost:9090/api/v1/$1"
}
if docker inspect -f '{{.State.Running}}' mini-baas-prometheus 2>/dev/null | grep -q true; then
  step "live: rules loaded into running prometheus"
  want="$(grep -c '^  - name: platform-' "${CFG}/rules/platform.yml")"
  groups="$(prom_api rules | jq '[.data.groups[].name | select(startswith("platform-"))] | length')"
  [ "${groups:-0}" -eq "${want}" ] || fail "prometheus loaded ${groups:-0} platform rule groups, the file has ${want} (restart it to reload the mounted rules)"
  pass "prometheus has ${groups} platform rule groups loaded"
  step "live: every target resolves"
  phantom="$(prom_api targets | jq -r '.data.activeTargets[] | select(.lastError | test("lookup .* (server misbehaving|no such host)")) | .scrapeUrl')"
  [ -z "${phantom}" ] || fail "targets for services this edition does not run (move them to dns_sd_configs): ${phantom}"
  pass "no target points at a service the edition never started"
else
  printf '  SKIP live half: mini-baas-prometheus is not running\n'
fi

green "[M52] ALL GATES GREEN — Prometheus config + ${RULES_N} platform alert rules validate"
