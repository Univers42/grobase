#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    run-audit.sh                                       :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Open-source security-AUDIT orchestrator for the Grobase BaaS. Extends the
# existing pipeline (run-security-scans.sh = SAST/SCA/secrets/container,
# zap-baseline.sh = DAST) with a complementary, Docker-first audit suite:
#
#   FILE-BASED (always run — no live stack needed):
#     - osv-scan.sh   Google OSV dependency-CVE scan (Node + Go + Rust)
#     - iac-scan.sh   Trivy config + Checkov IaC/Helm/Compose misconfig
#   URL-BASED (run only if their target responds):
#     - nuclei-scan.sh      template DAST vs live Kong gateway
#     - sqlmap-scan.sh      automated SQLi probe vs live data-plane API
#     - web-privacy-scan.sh GDPR header + cookie + third-party check vs site
#
# Every tool runs as its OFFICIAL Docker image — the host needs only `docker`.
#
# HONESTY: a scanner finding nothing is NOT proof of security — it bounds known
# classes; an independent pen test is still required (HUMAN-ATOMS). This suite is
# a continuous safety net, not a certificate.
#
# Usage:
#   bash apps/baas/mini-baas-infra/scripts/security/audit/run-audit.sh
#   bash .../run-audit.sh --only=osv,iac
#   bash .../run-audit.sh --skip=sqlmap,nuclei
#
# Environment knobs (forwarded to children):
#   AUDIT_FAIL_LEVEL    CRITICAL|HIGH|MEDIUM|LOW (default HIGH)
#   TARGET_URL          live gateway for nuclei/sqlmap (default http://127.0.0.1:8000)
#   SITE_URL            live site for web-privacy (default http://127.0.0.1:4325)
#   AUDIT_ARTIFACTS_DIR apps/baas/mini-baas-infra/artifacts/security-audit (default)
#
# Exit code: 0 only when every scanner that RAN is clean at the fail-level.
#            URL-based scanners that no-op (target down) do NOT count as failures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
ARTIFACTS_DIR="${AUDIT_ARTIFACTS_DIR:-${BAAS_DIR}/artifacts/security-audit}"
mkdir -p "${ARTIFACTS_DIR}"

export AUDIT_ARTIFACTS_DIR="${ARTIFACTS_DIR}"
TARGET="${TARGET_URL:-http://127.0.0.1:8000}"
SITE="${SITE_URL:-http://127.0.0.1:4325}"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
amber() { printf '\033[0;33m%s\033[0m\n' "$*"; }

# ── argument parsing (mirror run-security-scans.sh) ──────────────────────────
ONLY=""; SKIP=""
for arg in "$@"; do
  case "${arg}" in
    --only=*) ONLY="${arg#--only=}" ;;
    --skip=*) SKIP="${arg#--skip=}" ;;
    --help|-h) sed -n '/^# Usage:/,/^# Exit code:/p' "${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")" | sed 's/^# \?//'; exit 0 ;;
  esac
done
enabled() {
  local t="$1"
  [[ -n "${ONLY}" ]] && [[ ",${ONLY}," != *",${t},"* ]] && return 1
  [[ -n "${SKIP}" ]] && [[ ",${SKIP}," == *",${t},"* ]] && return 1
  return 0
}

# probe: does a URL answer with any HTTP code?
reachable() {
  curl -ksS -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null \
    | grep -qE "^[2-5][0-9][0-9]$"
}

# ── summary table state (parallel arrays: name | ran? | result) ──────────────
declare -a S_NAME S_RAN S_RESULT
record() { S_NAME+=("$1"); S_RAN+=("$2"); S_RESULT+=("$3"); }

run_one() {
  # $1 tool key, $2 script, $3 friendly label, rest = extra args
  local key="$1" script="$2" label="$3"; shift 3
  if ! enabled "${key}"; then
    record "${label}" "skipped(flag)" "—"
    amber "[audit] ${label}: skipped (--only/--skip)"
    return 0
  fi
  cyan "════════════════════════════════════════════════════════════════════"
  cyan "[audit] ▶ ${label}"
  cyan "════════════════════════════════════════════════════════════════════"
  local rc=0
  bash "${SCRIPT_DIR}/${script}" "$@" || rc=$?
  case "${rc}" in
    0) record "${label}" "yes" "clean";        green "[audit] ${label}: clean" ;;
    2) record "${label}" "no (target down)" "n/a"; amber "[audit] ${label}: no-op (target unreachable)" ;;
    *) record "${label}" "yes" "FINDINGS";     red   "[audit] ${label}: FINDINGS (rc=${rc})" ;;
  esac
  return "${rc}"
}

cyan "[audit] Grobase security-audit suite @ $(date -u +%FT%TZ)"
cyan "[audit] fail-level=${AUDIT_FAIL_LEVEL:-HIGH} | gateway=${TARGET} | site=${SITE}"
cyan "[audit] artifacts → ${ARTIFACTS_DIR}/"
echo

fail_count=0

# ── FILE-BASED: always attempt (no live stack needed) ────────────────────────
run_one osv osv-scan.sh "OSV deps (Node/Go/Rust)" || fail_count=$((fail_count + 1))
run_one iac iac-scan.sh "IaC misconfig (Trivy+Checkov)" || fail_count=$((fail_count + 1))

# ── URL-BASED: only if the target responds (otherwise clean no-op) ───────────
if enabled nuclei; then
  if reachable "${TARGET}"; then
    run_one nuclei nuclei-scan.sh "Nuclei DAST (gateway)" || fail_count=$((fail_count + 1))
  else
    record "Nuclei DAST (gateway)" "no (target down)" "n/a"
    amber "[audit] Nuclei: gateway ${TARGET} down — skipped (bring stack up: make up EDITION=query)"
  fi
fi
if enabled sqlmap; then
  if reachable "${TARGET}"; then
    run_one sqlmap sqlmap-scan.sh "sqlmap SQLi (data plane)" || fail_count=$((fail_count + 1))
  else
    record "sqlmap SQLi (data plane)" "no (target down)" "n/a"
    amber "[audit] sqlmap: gateway ${TARGET} down — skipped"
  fi
fi
if enabled web-privacy; then
  if reachable "${SITE}"; then
    run_one web-privacy web-privacy-scan.sh "Web privacy/GDPR (site)" || fail_count=$((fail_count + 1))
  else
    record "Web privacy/GDPR (site)" "no (target down)" "n/a"
    amber "[audit] web-privacy: site ${SITE} down — skipped (make grobase-up)"
  fi
fi

# ── summary table ────────────────────────────────────────────────────────────
echo
cyan "════════════════════════════════════════════════════════════════════"
cyan "[audit] SUMMARY"
cyan "════════════════════════════════════════════════════════════════════"
printf '%-32s | %-18s | %s\n' "TOOL" "RAN?" "RESULT"
printf '%-32s-+-%-18s-+-%s\n' "--------------------------------" "------------------" "--------"
for i in "${!S_NAME[@]}"; do
  printf '%-32s | %-18s | %s\n' "${S_NAME[$i]}" "${S_RAN[$i]}" "${S_RESULT[$i]}"
done
echo
echo "[audit] full reports under ${ARTIFACTS_DIR}/"

echo
if [[ ${fail_count} -eq 0 ]]; then
  green "[audit] OK — every scanner that RAN is clean. (No-ops do not assert safety.)"
  green "[audit] REMINDER: clean scans bound known classes only — pen test still required (HUMAN-ATOMS)."
  exit 0
fi
red "[audit] ${fail_count} scanner(s) reported findings — inspect ${ARTIFACTS_DIR}/"
exit 1
