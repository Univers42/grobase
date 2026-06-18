#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    web-privacy-scan.sh                                :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# GDPR / privacy posture check for the Grobase marketing site. Two passes, both
# Docker-first via curlimages/curl — no host install. REQUIRES the live site.
#   (a) SECURITY/PRIVACY HEADERS: CSP, HSTS, X-Content-Type-Options,
#       Referrer-Policy, Permissions-Policy, X-Frame-Options.
#   (b) COOKIE + THIRD-PARTY exposure: any Set-Cookie, and any off-origin URL
#       referenced in the served HTML (fonts/CDN/analytics/trackers).
#
# The Grobase site is strict-CSP, self-hosted fonts, connect-src 'self' — so we
# EXPECT minimal exposure (no cookies, no third-party origins). This scan
# CONFIRMS that and flags any regression (a non-essential cookie or off-origin).
#
# HONESTY: a scanner finding nothing is NOT proof of security/compliance — it
# bounds known classes (here: header presence + statically-referenced origins +
# Set-Cookie). Client-side runtime beacons or a DPA review are out of scope; an
# independent pen test / privacy audit is still required (HUMAN-ATOMS).
#
# Usage:
#   bash apps/baas/mini-baas-infra/scripts/security/audit/web-privacy-scan.sh
#   SITE_URL=http://127.0.0.1:4325 bash .../web-privacy-scan.sh
#
# Environment knobs:
#   SITE_URL            live site URL (default http://127.0.0.1:4325)
#   CURL_IMAGE          override image (default curlimages/curl)
#   AUDIT_ARTIFACTS_DIR apps/baas/mini-baas-infra/artifacts/security-audit (default)
#
# Exit codes: 0 clean / 1 missing required header OR cookie/3rd-party found /
#             2 site unreachable (no-op)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
ARTIFACTS_DIR="${AUDIT_ARTIFACTS_DIR:-${BAAS_DIR}/artifacts/security-audit}"
mkdir -p "${ARTIFACTS_DIR}"

SITE="${SITE_URL:-http://127.0.0.1:4325}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:latest}"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
amber() { printf '\033[0;33m%s\033[0m\n' "$*"; }

REPORT="${ARTIFACTS_DIR}/web-privacy.md"
HDR_RAW="${ARTIFACTS_DIR}/web-privacy.headers.txt"
on_exit() {
  local rc=$?
  echo
  echo "[privacy] report: ${REPORT}  | raw headers: ${HDR_RAW}"
  [[ ${rc} -eq 2 ]] && amber "[privacy] (no-op: live site required)"
  return 0
}
trap on_exit EXIT

cyan "[privacy] GDPR/privacy posture for ${SITE} @ $(date -u +%FT%TZ)"

# helper: run curl inside the official image with host networking so 127.0.0.1
# reaches the host-served site.
dcurl() { docker run --rm --network host "${CURL_IMAGE}" "$@"; }

# ── live-site guard ──────────────────────────────────────────────────────────
# curl's -w prints a 3-digit code even on failure (000); on connect-refused it
# also exits non-zero so the `|| echo` would double it — keep only the last 3.
code="$(dcurl -ksS -o /dev/null -w '%{http_code}' --max-time 5 "${SITE}" 2>/dev/null || true)"
code="${code: -3}"
code="${code:-000}"
if ! printf '%s' "${code}" | grep -qE "^[2-3][0-9][0-9]$"; then
  amber "[privacy] site ${SITE} unreachable (http ${code}) — SKIPPING (make grobase-up)"
  amber "[privacy] this scanner needs the live site; nothing to check, exiting cleanly"
  exit 2
fi
green "[privacy] site responded (${code}) — proceeding"

# ── pass (a): headers ────────────────────────────────────────────────────────
dcurl -ksSI --max-time 10 "${SITE}" >"${HDR_RAW}" 2>/dev/null || true
# also fetch the body for pass (b)
BODY="$(dcurl -ksS --max-time 15 "${SITE}" 2>/dev/null || true)"

has_header() { grep -iq "^$1:" "${HDR_RAW}"; }
header_val() { grep -i "^$1:" "${HDR_RAW}" | head -1 | sed 's/^[^:]*: *//' | tr -d '\r'; }

# Required (GDPR/OWASP secure-header baseline). HSTS is only meaningful over TLS,
# so on an http:// dev URL we down-grade it to a note, not a failure.
declare -a REQUIRED=(
  "Content-Security-Policy"
  "X-Content-Type-Options"
  "Referrer-Policy"
  "Permissions-Policy"
)
declare -a OPTIONAL=(
  "Strict-Transport-Security"
  "X-Frame-Options"
)

{
  echo "# Web privacy / GDPR posture — ${SITE}"
  echo
  echo "_Generated $(date -u +%FT%TZ) — Docker-first (curlimages/curl). A scanner"
  echo "finding nothing is NOT proof of compliance; an independent privacy audit is"
  echo "still required (HUMAN-ATOMS)._"
  echo
  echo "## Security / privacy headers"
  echo
  echo "| Header | Present | Value |"
  echo "|---|---|---|"
} >"${REPORT}"

fail=0
is_tls=0
printf '%s' "${SITE}" | grep -qi '^https' && is_tls=1

for h in "${REQUIRED[@]}"; do
  if has_header "${h}"; then
    v="$(header_val "${h}")"
    [[ ${#v} -gt 70 ]] && v="${v:0:67}..."
    echo "| ${h} | yes | \`${v}\` |" >>"${REPORT}"
    green "[privacy]   ${h}: present"
  else
    echo "| ${h} | **MISSING** | — |" >>"${REPORT}"
    red "[privacy]   ${h}: MISSING"
    fail=$((fail + 1))
  fi
done
for h in "${OPTIONAL[@]}"; do
  if has_header "${h}"; then
    v="$(header_val "${h}")"
    [[ ${#v} -gt 70 ]] && v="${v:0:67}..."
    echo "| ${h} | yes | \`${v}\` |" >>"${REPORT}"
    green "[privacy]   ${h}: present"
  elif [[ "${h}" == "Strict-Transport-Security" && ${is_tls} -eq 0 ]]; then
    echo "| ${h} | n/a (http) | — |" >>"${REPORT}"
    amber "[privacy]   ${h}: n/a on plain http (expected on the TLS prod origin)"
  else
    echo "| ${h} | absent (recommended) | — |" >>"${REPORT}"
    amber "[privacy]   ${h}: absent (recommended, not blocking)"
  fi
done

# ── pass (b): cookies + third-party origins ──────────────────────────────────
{
  echo
  echo "## Cookies"
  echo
} >>"${REPORT}"
cookies="$(grep -i '^Set-Cookie:' "${HDR_RAW}" | sed 's/\r//' || true)"
if [[ -n "${cookies}" ]]; then
  red "[privacy]   Set-Cookie present — GDPR consent territory"
  echo "Non-essential cookies set without consent are a GDPR concern. Found:" >>"${REPORT}"
  echo '```' >>"${REPORT}"
  printf '%s\n' "${cookies}" >>"${REPORT}"
  echo '```' >>"${REPORT}"
  fail=$((fail + 1))
else
  green "[privacy]   no Set-Cookie header (cookieless — ideal for GDPR)"
  echo "No \`Set-Cookie\` header on the landing response (cookieless)." >>"${REPORT}"
fi

{
  echo
  echo "## Third-party origins referenced in HTML"
  echo
} >>"${REPORT}"
# Extract absolute http(s) URLs from the body, take the host, drop our own host.
self_host="$(printf '%s' "${SITE}" | sed -E 's#^https?://([^/]+).*#\1#')"
third=""
if [[ -n "${BODY}" ]]; then
  third="$(printf '%s' "${BODY}" |
    grep -oE 'https?://[a-zA-Z0-9._-]+' |
    sed -E 's#^https?://##' |
    sort -u |
    grep -viE "^(${self_host}|127\.0\.0\.1|localhost)$" || true)"
fi
if [[ -n "${third}" ]]; then
  amber "[privacy]   off-origin reference(s) found — verify each is essential & consented"
  echo "Off-origin hosts referenced in the served HTML (verify each is" >>"${REPORT}"
  echo "first-party / self-hosted; trackers/CDNs without consent are a GDPR concern):" >>"${REPORT}"
  echo '```' >>"${REPORT}"
  printf '%s\n' "${third}" >>"${REPORT}"
  echo '```' >>"${REPORT}"
  printf '%s\n' "${third}" | sed 's/^/  - /'
  # Off-origin alone isn't auto-fail (could be a rel=preconnect to own CDN); WARN.
  amber "[privacy]   (reported as WARN — confirm intent; strict-CSP site expects none)"
else
  green "[privacy]   no third-party origins in HTML (self-contained — ideal)"
  echo "No off-origin hosts referenced in the served HTML (self-contained)." >>"${REPORT}"
fi

# CSP connect-src sanity: strict-CSP site should be connect-src 'self'.
csp="$(header_val 'Content-Security-Policy')"
if [[ -n "${csp}" ]]; then
  {
    echo
    echo "## CSP connect-src note"
    echo
  } >>"${REPORT}"
  if printf '%s' "${csp}" | grep -qiE "connect-src[^;]*'self'"; then
    green "[privacy]   CSP connect-src includes 'self'"
    echo "\`connect-src 'self'\` present — outbound fetch is same-origin by policy." >>"${REPORT}"
  else
    amber "[privacy]   CSP has no explicit connect-src 'self' (review)"
    echo "No explicit \`connect-src 'self'\` seen — review the CSP for egress scope." >>"${REPORT}"
  fi
fi

echo
if [[ ${fail} -gt 0 ]]; then
  red "[privacy] FAIL — ${fail} privacy issue(s): missing required header(s) and/or cookies set"
  exit 1
fi
green "[privacy] OK — required headers present, cookieless; minimal exposure confirmed"
exit 0
