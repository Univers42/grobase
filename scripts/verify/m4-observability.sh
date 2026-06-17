#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m4-observability.sh                                :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/31 17:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/31 17:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="."
COMPOSE_FILE="${BAAS_DIR}/docker-compose.yml"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
fail()  { red   "[M4] FAIL: $*"; exit 1; }
step()  { cyan  "[M4] ${*}"; }
pass()  { green "[M4] PASS: ${*}"; }

step "checking observability services in compose"
for svc in prometheus grafana loki promtail; do
  grep -qE "^  ${svc}:$" "${COMPOSE_FILE}" \
    || fail "compose does not declare service '${svc}'"
done
pass "prometheus + grafana + loki + promtail declared"

step "checking PrometheusModule.register() is globally exposed through ObservabilityModule"
OBS="${BAAS_DIR}/src/libs/common/src/observability/observability.module.ts"
[[ -f "${OBS}" ]] || fail "${OBS} missing"
grep -q "PrometheusModule.register" "${OBS}" \
  || fail "ObservabilityModule does not call PrometheusModule.register() — /metrics will not be mounted"
missing=0
for app_module in "${BAAS_DIR}"/src/apps/*/src/app.module.ts; do
  grep -q "ObservabilityModule" "${app_module}" || { echo "${app_module}"; missing=1; }
done
[[ "${missing}" -eq 0 ]] || fail "one or more app.module.ts files do not import ObservabilityModule"
pass "ObservabilityModule imports PrometheusModule.register() and every NestJS app imports ObservabilityModule"

step "checking CorrelationIdInterceptor propagates X-Request-ID"
CID="${BAAS_DIR}/src/libs/common/src/interceptors/correlation-id.interceptor.ts"
[[ -f "${CID}" ]] || fail "${CID} missing"
grep -q "X-Request-ID" "${CID}" \
  || fail "${CID} does not propagate X-Request-ID"
pass "correlation-id interceptor present + sets X-Request-ID"

step "checking audit_log carries request_id (M3 outbox traceability)"
MIG="${BAAS_DIR}/scripts/migrations/postgresql/013_audit_log.sql"
[[ -f "${MIG}" ]] || fail "${MIG} missing"
grep -q "request_id" "${MIG}" \
  || fail "audit_log migration does not include request_id column"
pass "audit_log has request_id column — cross-system trace correlation possible"

LIVE=0
for arg in "$@"; do [[ "${arg}" == "--live" ]] && LIVE=1; done

if [[ ${LIVE} -eq 1 ]]; then
  command -v curl >/dev/null 2>&1 || fail "curl required for --live mode"
  command -v jq   >/dev/null 2>&1 || fail "jq required for --live mode"

  PROMETHEUS_PORT="${PROMETHEUS_PORT:-19090}"
  GRAFANA_PORT="${GRAFANA_PORT:-13000}"
  LOKI_PORT="${LOKI_PORT:-13100}"

  step "live: Prometheus /-/ready"
  ready=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PROMETHEUS_PORT}/-/ready" || true)
  [[ "${ready}" == "200" ]] || fail "Prometheus /-/ready returned ${ready} (port ${PROMETHEUS_PORT})"
  pass "Prometheus ready"

  step "live: Prometheus is scraping ≥ 1 target"
  active=$(curl -sS "http://127.0.0.1:${PROMETHEUS_PORT}/api/v1/targets?state=active" \
    | jq -r '[.data.activeTargets[]?.health] | map(select(. == "up")) | length' 2>/dev/null || echo 0)
  [[ "${active}" -gt 0 ]] || fail "Prometheus has 0 active targets up"
  pass "Prometheus scraping ${active} target(s)"

  step "live: Grafana /api/health"
  status=$(curl -sS "http://127.0.0.1:${GRAFANA_PORT}/api/health" | jq -r '.database // ""' 2>/dev/null || true)
  [[ "${status}" == "ok" ]] || fail "Grafana /api/health.database != ok (got '${status}')"
  pass "Grafana healthy"

  step "live: Loki /ready"
  ready=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${LOKI_PORT}/ready" || true)
  [[ "${ready}" == "200" ]] || fail "Loki /ready returned ${ready}"
  pass "Loki ready"

  step "live: query-router /metrics"
  docker compose -f "${COMPOSE_FILE}" exec -T query-router \
    node -e "fetch('http://127.0.0.1:4001/metrics').then(async r => { const t = await r.text(); process.exit(r.ok && t.includes('# HELP') ? 0 : 1); })" \
    || fail "query-router /metrics is not served"
  pass "query-router /metrics served"
fi

green "[M4] OK — all milestone-4 deliverables verified"
