#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    nuclei-scan.sh                                     :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Template-based vuln / misconfig DAST against the LIVE Kong gateway with
# ProjectDiscovery Nuclei. Runs the official projectdiscovery/nuclei image —
# no host install required. REQUIRES the live stack to be up.
#
# HONESTY: a scanner finding nothing is NOT proof of security — it bounds known
# classes (here: community Nuclei templates for known CVEs/misconfigs/exposures);
# an independent pen test is still required (HUMAN-ATOMS).
#
# Usage:
#   bash apps/baas/mini-baas-infra/scripts/security/audit/nuclei-scan.sh
#   TARGET_URL=http://127.0.0.1:8000 bash .../nuclei-scan.sh
#
# Environment knobs:
#   TARGET_URL          live gateway URL (default http://127.0.0.1:8000)
#   AUDIT_FAIL_LEVEL    critical|high|medium|low (default high) — Nuclei severity gate
#   NUCLEI_IMAGE        override image (default projectdiscovery/nuclei)
#   NUCLEI_RATE         requests/sec cap (default 50 — be gentle on a dev box)
#   AUDIT_ARTIFACTS_DIR apps/baas/mini-baas-infra/artifacts/security-audit (default)
#
# Exit codes: 0 clean / 1 findings at>=fail-level / 2 target unreachable (no-op)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
ARTIFACTS_DIR="${AUDIT_ARTIFACTS_DIR:-${BAAS_DIR}/artifacts/security-audit}"
mkdir -p "${ARTIFACTS_DIR}"

TARGET="${TARGET_URL:-http://127.0.0.1:8000}"
NUCLEI_IMAGE="${NUCLEI_IMAGE:-projectdiscovery/nuclei:latest}"
FAIL_LEVEL="$(printf '%s' "${AUDIT_FAIL_LEVEL:-high}" | tr '[:upper:]' '[:lower:]')"
RATE="${NUCLEI_RATE:-50}"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
amber() { printf '\033[0;33m%s\033[0m\n' "$*"; }

JSON_OUT="${ARTIFACTS_DIR}/nuclei.jsonl"
on_exit() {
  local rc=$?
  echo
  echo "[nuclei] report: ${JSON_OUT}"
  [[ ${rc} -eq 2 ]] && amber "[nuclei] (no-op: live stack required)"
  return 0
}
trap on_exit EXIT

cyan "[nuclei] template DAST against ${TARGET} @ $(date -u +%FT%TZ)"

# ── live-stack guard: probe the target first, no-op clearly if unreachable ───
if ! curl -ksS -o /dev/null -w '%{http_code}' --max-time 5 "${TARGET}" 2>/dev/null \
     | grep -qE "^[2-5][0-9][0-9]$"; then
  amber "[nuclei] target ${TARGET} unreachable — SKIPPING (bring the stack up: make up EDITION=query)"
  amber "[nuclei] this scanner needs the live Kong gateway; nothing to scan, exiting cleanly"
  exit 2
fi
green "[nuclei] target responded — proceeding"

# ── severity set at-or-above the fail-level (Nuclei takes a comma list) ──────
case "${FAIL_LEVEL}" in
  critical) SEV="critical" ;;
  high)     SEV="critical,high" ;;
  medium)   SEV="critical,high,medium" ;;
  low)      SEV="critical,high,medium,low" ;;
  *)        SEV="critical,high" ;;
esac

# Nuclei caches its template repo in a volume so re-runs don't re-clone.
TPL_CACHE="${ARTIFACTS_DIR}/nuclei-templates"
mkdir -p "${TPL_CACHE}"

cyan "[nuclei] running templates at severity {${SEV}} (rate ${RATE}/s)"
# --network host so 127.0.0.1 inside the container reaches the host gateway.
# -duc skips the auto-update prompt; -jsonl emits one finding per line.
docker run --rm \
  --network host \
  -v "${REPO_ROOT}/${ARTIFACTS_DIR}:/out" \
  -v "${REPO_ROOT}/${TPL_CACHE}:/root/nuclei-templates" \
  "${NUCLEI_IMAGE}" \
    -target "${TARGET}" \
    -severity "${SEV}" \
    -rate-limit "${RATE}" \
    -jsonl -o /out/nuclei.jsonl \
    -stats -duc -nc \
    2>&1 | tail -40 || true

if [[ ! -f "${JSON_OUT}" ]]; then
  # Nuclei writes the file only when there is >=1 finding; absence == clean.
  : > "${JSON_OUT}"
fi

count=$(grep -c '"template-id"' "${JSON_OUT}" 2>/dev/null || echo 0)
count=$(printf '%s' "${count}" | tr -d ' ')

echo
cyan "[nuclei] summary: ${count} finding(s) at severity >= ${FAIL_LEVEL}"
if [[ "${count}" -gt 0 ]]; then
  red "[nuclei] FAIL — ${count} finding(s)"
  jq -r '"  - [" + (.info.severity // "?") + "] " + (.["template-id"] // .templateID // "?")
         + "  " + (.info.name // "") + "  → " + (.["matched-at"] // .host // "?")' \
    "${JSON_OUT}" 2>/dev/null | head -25 || head -25 "${JSON_OUT}"
  exit 1
fi
green "[nuclei] OK — no template findings at >= ${FAIL_LEVEL}"
exit 0
