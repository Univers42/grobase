#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    zap-baseline.sh                                    :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/31 17:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/31 17:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# DAST baseline scan with OWASP ZAP against the live WAF / Kong stack.
# Runs the official zaproxy/zap-stable image — no host install required.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
ARTIFACTS_DIR="${BAAS_DIR}/artifacts/security"
mkdir -p "${ARTIFACTS_DIR}"

TARGET="${1:-}"
if [[ -z "${TARGET}" ]]; then
  TARGET="https://127.0.0.1:${WAF_HTTPS_PORT:-18443}"
fi

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
amber() { printf '\033[0;33m%s\033[0m\n' "$*"; }

cyan "[zap] DAST baseline against ${TARGET}"

if ! curl -ksS -o /dev/null -w '%{http_code}' --max-time 5 "${TARGET}" | grep -qE "^[2-5][0-9][0-9]$"; then
  red "[zap] target ${TARGET} unreachable — bring the stack up first"
  exit 2
fi

docker run --rm \
  --network host \
  -v "${REPO_ROOT}/${ARTIFACTS_DIR}:/zap/wrk:rw" \
  zaproxy/zap-stable:latest \
  zap-baseline.py \
    -t "${TARGET}" \
    -J zap-baseline.json \
    -r zap-baseline.html \
    -w zap-baseline.md \
    -I \
    -m 2 \
    -d 2>&1 | tail -80 || true

report="${ARTIFACTS_DIR}/zap-baseline.json"
if [[ ! -f "${report}" ]]; then
  red "[zap] no report produced at ${report} — ZAP run aborted"
  exit 3
fi

high_count=$(jq -r '[.site[]?.alerts[]? | select((.riskcode // "0" | tonumber) >= 3)] | length' "${report}" 2>/dev/null || echo 0)
medium_count=$(jq -r '[.site[]?.alerts[]? | select((.riskcode // "0" | tonumber) == 2)] | length' "${report}" 2>/dev/null || echo 0)
low_count=$(jq -r '[.site[]?.alerts[]? | select((.riskcode // "0" | tonumber) == 1)] | length' "${report}" 2>/dev/null || echo 0)

echo
cyan "[zap] summary: ${high_count} high, ${medium_count} medium, ${low_count} low"
echo "[zap] full reports:"
echo "  - JSON: ${report}"
echo "  - HTML: ${ARTIFACTS_DIR}/zap-baseline.html"
echo "  - MD:   ${ARTIFACTS_DIR}/zap-baseline.md"

if [[ "${high_count}" -gt 0 ]]; then
  red "[zap] FAIL — ${high_count} High-risk finding(s)"
  jq -r '.site[]?.alerts[]? | select((.riskcode // "0" | tonumber) >= 3) | "  - \(.name) :: \(.riskdesc) :: \(.url)"' "${report}" 2>/dev/null | head -10 || true
  exit 1
fi

if [[ "${medium_count}" -gt 0 ]]; then
  amber "[zap] WARN — ${medium_count} Medium-risk finding(s) (not blocking)"
fi

green "[zap] OK — no High-risk findings"
