#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m5-security.sh                                     :+:      :+:    :+:    #
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
fail()  { red   "[M5] FAIL: $*"; exit 1; }
step()  { cyan  "[M5] ${*}"; }
pass()  { green "[M5] PASS: ${*}"; }

step "checking WAF Dockerfile + CRS setup files"
WAF_DOCKERFILE="${BAAS_DIR}/infra/docker/services/waf/Dockerfile"
[[ -f "${WAF_DOCKERFILE}" ]] || fail "${WAF_DOCKERFILE} missing"
grep -q "owasp/modsecurity-crs" "${WAF_DOCKERFILE}" \
  || fail "${WAF_DOCKERFILE} does not base on owasp/modsecurity-crs"
grep -q "^HEALTHCHECK" "${WAF_DOCKERFILE}" || fail "${WAF_DOCKERFILE} missing HEALTHCHECK"
pass "WAF Dockerfile present + based on owasp/modsecurity-crs + has HEALTHCHECK"

step "checking Kong rate-limiting plugin in declarative config"
KONG_CONF="${BAAS_DIR}/infra/docker/services/kong/conf/kong.yml"
[[ -f "${KONG_CONF}" ]] || fail "${KONG_CONF} missing"
grep -q "name: rate-limiting" "${KONG_CONF}" \
  || fail "Kong config does not declare the rate-limiting plugin"
pass "Kong rate-limiting plugin declared"

step "checking security response headers in Kong"
for header in Strict-Transport-Security X-Content-Type-Options X-Frame-Options Referrer-Policy; do
  grep -q "${header}" "${KONG_CONF}" \
    || fail "Kong does not add response header ${header}"
done
pass "Kong adds HSTS / X-Content-Type-Options / X-Frame-Options / Referrer-Policy"

step "checking Vault wiring for JWT_SECRET"
grep -qE "JWT_SECRET" "${COMPOSE_FILE}" \
  || fail "compose does not propagate JWT_SECRET to services"
[[ -d "${BAAS_DIR}/infra/docker/services/vault" ]] || fail "vault service dir missing"
pass "JWT_SECRET propagated via compose, vault service present"

step "checking SAST orchestrator script"
SCAN_SCRIPT="${BAAS_DIR}/scripts/security/run-security-scans.sh"
[[ -x "${SCAN_SCRIPT}" ]] || fail "${SCAN_SCRIPT} missing or not executable"
for tool in semgrep "npm audit" trivy trufflehog; do
  grep -qi "${tool}" "${SCAN_SCRIPT}" \
    || fail "run-security-scans.sh does not wrap ${tool}"
done
pass "SAST orchestrator wraps Semgrep + npm audit + Trivy + TruffleHog"

step "checking GitHub Actions security workflow"
WORKFLOW=".github/workflows/mini-baas-security.yml"
[[ -f "${WORKFLOW}" ]] || fail "${WORKFLOW} missing"
[[ -s "${WORKFLOW}" ]] || fail "${WORKFLOW} is empty"
grep -qE "semgrep|trivy|trufflehog" "${WORKFLOW}" \
  || fail "${WORKFLOW} does not invoke any of semgrep/trivy/trufflehog"
pass "mini-baas-security.yml present and wired to scanners"

LIVE=0
for arg in "$@"; do [[ "${arg}" == "--live" ]] && LIVE=1; done

if [[ ${LIVE} -eq 1 ]]; then
  command -v jq >/dev/null 2>&1 || fail "jq required for --live mode"
  command -v curl >/dev/null 2>&1 || fail "curl required for --live mode"

  WAF_HTTP_PORT="${WAF_HTTP_PORT:-18880}"
  WAF_HTTPS_PORT="${WAF_HTTPS_PORT:-18443}"
  KONG_RATE_LIMIT_URL="${KONG_RATE_LIMIT_URL:-https://127.0.0.1:${WAF_HTTPS_PORT}/auth/v1/health}"
  KONG_RATE_LIMIT_REQUESTS="${KONG_RATE_LIMIT_REQUESTS:-320}"
  KONG_PUBLIC_API_KEY="${KONG_PUBLIC_API_KEY:-}"
  if [[ -z "${KONG_PUBLIC_API_KEY}" && -f "${BAAS_DIR}/.env" ]]; then
    KONG_PUBLIC_API_KEY=$(awk -F= '$1 == "KONG_PUBLIC_API_KEY" {print substr($0, index($0, "=") + 1); exit}' "${BAAS_DIR}/.env")
  fi

  step "live: WAF /waf-health responds"
  if ! curl -ksS -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:${WAF_HTTP_PORT}/waf-health" | grep -qE "^(200|204)$"; then
    fail "WAF /waf-health unreachable on :${WAF_HTTP_PORT}"
  fi
  pass "WAF /waf-health returns 2xx"

  step "live: CRS blocks an SQLi probe with HTTP 403"
  status=$(curl -ksS -o /dev/null -w '%{http_code}' \
    "https://127.0.0.1:${WAF_HTTPS_PORT}/rest/v1/x?id=1%27%20OR%20%271%27=%271" || true)
  [[ "${status}" == "403" ]] \
    || fail "expected 403 from CRS on SQLi probe, got ${status} — CRS not enforcing"
  pass "CRS blocks SQLi probe with 403"

  step "live: Kong rate-limiting enforces 429"
  export KONG_PUBLIC_API_KEY KONG_RATE_LIMIT_URL
  hits=$(seq 1 "${KONG_RATE_LIMIT_REQUESTS}" | xargs -r -P 16 -n 1 bash -c '
    if [[ -n "${KONG_PUBLIC_API_KEY}" ]]; then
      curl -ksS -H "apikey: ${KONG_PUBLIC_API_KEY}" -o /dev/null -w "%{http_code}\n" "${KONG_RATE_LIMIT_URL}" || true
    else
      curl -ksS -o /dev/null -w "%{http_code}\n" "${KONG_RATE_LIMIT_URL}" || true
    fi
  ' _ | sort | uniq -c | awk '/429/{print $1}' || true)
  hits="${hits:-0}"
  [[ "${hits}" -gt 0 ]] \
    || fail "Kong rate-limit did not return any 429 over ${KONG_RATE_LIMIT_REQUESTS} requests"
  pass "Kong rate-limit fired (${hits} requests blocked with 429)"

  step "live: security response headers present"
  hdrs=$(curl -ksSI "https://127.0.0.1:${WAF_HTTPS_PORT}/" 2>/dev/null || true)
  for h in "Strict-Transport-Security" "X-Content-Type-Options" "X-Frame-Options" "Referrer-Policy"; do
    echo "${hdrs}" | grep -iq "^${h}:" \
      || fail "missing response header ${h}"
  done
  pass "HSTS / X-Content-Type-Options / X-Frame-Options / Referrer-Policy returned by WAF"

  step "live: Vault is unsealed"
  vault_status=$(docker compose -f "${COMPOSE_FILE}" exec -T vault \
    vault status -address=http://127.0.0.1:8200 2>&1 || true)
  echo "${vault_status}" | grep -q "Sealed.*false" \
    || fail "Vault is sealed — JWT signing chain broken"
  pass "Vault unsealed and operational"
fi

green "[M5] OK — all milestone-5 deliverables verified"
