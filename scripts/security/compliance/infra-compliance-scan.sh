#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    infra-compliance-scan.sh                          :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# IaC compliance-as-code over the Grobase Helm charts — RUNNABLE NOW.
#
# Runs Checkov (bridgecrew/checkov) against deploy/helm/* with the Kubernetes +
# Helm policy packs. This is the LOCAL PROXY for infrastructure compliance: it
# audits the deployment CONFIG we ship (security contexts, capabilities, network
# policy, secret handling), which is the infra-config half of:
#
#   ISO/IEC 27001:2022  A.8.9  Configuration management
#                       A.8.20 Networks security
#                       A.8.22 Segregation of networks
#                       A.8.24 Use of cryptography (TLS/secret posture)
#   SOC 2 (TSC)         CC6.1  Logical access provisioning
#                       CC6.6  Boundary / network protection
#                       CC7.1  Vulnerability / misconfiguration detection
#
# HONEST SCOPE — read this:
#   This audits our IaC ARTIFACTS (Helm charts). It does NOT audit a live cloud
#   account against the built-in SOC 2 / ISO 27001 / GDPR frameworks — that is
#   what prowler-scan.sh and steampipe-compliance.sh do, and they need real
#   cloud credentials we do not have locally. A green run here is NOT a SOC 2 /
#   ISO / GDPR pass; it is "our deployment config has no flagged misconfigs."
#   See wiki/compliance/infra-compliance-scanning.md for the full split.
#
# Docker-first: runs the official Checkov image. The host needs only `docker`.
#
# Usage:
#   bash apps/baas/mini-baas-infra/scripts/security/compliance/infra-compliance-scan.sh
#   COMPLIANCE_FAIL_LEVEL=error bash .../infra-compliance-scan.sh   # gate hard
#   COMPLIANCE_HELM_DIRS="deploy/helm/grobase" bash .../infra-compliance-scan.sh
#
# Environment knobs:
#   COMPLIANCE_FAIL_LEVEL   off|warn|error (default: warn)
#       off   — always exit 0 (informational scan; CI never blocks on it)
#       warn  — exit 0 but print failed checks loudly (default; honest baseline)
#       error — exit 1 if Checkov reports ANY failed check (use once charts pass)
#   COMPLIANCE_HELM_DIRS    space-separated chart dirs (default: all under deploy/helm)
#   COMPLIANCE_FRAMEWORK    Checkov --framework value (default: kubernetes,helm)
#   COMPLIANCE_ARTIFACTS_DIR   default: artifacts/security-audit/compliance
#   COMPLIANCE_CHECKOV_IMAGE   default: bridgecrew/checkov:latest
#   COMPLIANCE_SKIP_CHECKS  comma list of check IDs to suppress (e.g. CKV_K8S_43)
#
# Exit code: see COMPLIANCE_FAIL_LEVEL above.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/security/compliance -> mini-baas-infra -> apps/baas -> apps -> repo root
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
ARTIFACTS_DIR="${COMPLIANCE_ARTIFACTS_DIR:-${BAAS_DIR}/artifacts/security-audit/compliance}"
mkdir -p "${ARTIFACTS_DIR}"

CHECKOV_IMAGE="${COMPLIANCE_CHECKOV_IMAGE:-bridgecrew/checkov:latest}"
FRAMEWORK="${COMPLIANCE_FRAMEWORK:-kubernetes,helm}"
FAIL_LEVEL="${COMPLIANCE_FAIL_LEVEL:-warn}"
SKIP_CHECKS="${COMPLIANCE_SKIP_CHECKS:-}"

# Default: every chart dir under deploy/helm that has a Chart.yaml.
if [[ -n "${COMPLIANCE_HELM_DIRS:-}" ]]; then
  read -r -a HELM_DIRS <<< "${COMPLIANCE_HELM_DIRS}"
else
  HELM_DIRS=()
  while IFS= read -r chart; do
    HELM_DIRS+=("$(dirname "${chart}")")
  done < <(find "${BAAS_DIR}/deploy/helm" -maxdepth 2 -name Chart.yaml 2>/dev/null | sort)
fi

# ── colour helpers (mirror run-security-scans.sh) ────────────────────────────
cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
amber() { printf '\033[0;33m%s\033[0m\n' "$*"; }
step()  { cyan  "[iac] ${*}"; }
fail()  { red   "[iac] FAIL: $*"; }
warn()  { amber "[iac] WARN: $*"; }
ok()    { green "[iac] OK:   $*"; }

# ── help ─────────────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "${arg}" in
    --help|-h)
      sed -n '/^# Usage:/,/^# Exit code:/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
  esac
done

step "IaC compliance scan started ($(date -u +%FT%TZ))"
step "Tool: Checkov (${CHECKOV_IMAGE}) · framework=${FRAMEWORK} · fail-level=${FAIL_LEVEL}"
amber "[iac] SCOPE: this audits Helm chart CONFIG (IaC), NOT a live cloud account."
amber "[iac]        It is the local proxy for ISO 27001 A.8.9/A.8.20 + SOC2 CC6/CC7."
amber "[iac]        It is NOT a SOC 2 / ISO / GDPR pass. See infra-compliance-scanning.md."

if [[ ${#HELM_DIRS[@]} -eq 0 ]]; then
  fail "no Helm charts found under ${BAAS_DIR}/deploy/helm"
  exit 2
fi

# Pre-pull so a registry failure is reported clearly (not as a Checkov error).
if ! docker image inspect "${CHECKOV_IMAGE}" >/dev/null 2>&1; then
  step "pulling ${CHECKOV_IMAGE} ..."
  if ! docker pull "${CHECKOV_IMAGE}" >/dev/null 2>&1; then
    fail "could not pull ${CHECKOV_IMAGE} — the script is the deliverable; rerun when the image is reachable."
    fail "(offline? set COMPLIANCE_CHECKOV_IMAGE to a mirrored tag, or load the image manually.)"
    exit 4
  fi
fi

# Optional skip args, shared across every chart run.
skip_args=()
if [[ -n "${SKIP_CHECKS}" ]]; then
  skip_args+=(--skip-check "${SKIP_CHECKS}")
fi

total_failed=0
total_passed=0
scanned=0

for dir in "${HELM_DIRS[@]}"; do
  [[ -d "${dir}" ]] || { warn "skip missing chart dir ${dir}"; continue; }
  chart_name="$(basename "${dir}")"
  out_json="${ARTIFACTS_DIR}/checkov-${chart_name}.json"
  step "scanning chart: ${dir}"

  # Checkov writes JSON to stdout when -o json. We mount the chart read-only and
  # the artifacts dir read-write, then redirect stdout to the report file. Checkov
  # exits non-zero on failed checks; we always capture the report and decide later.
  set +e
  docker run --rm \
    -v "${REPO_ROOT}/${dir}:/chart:ro" \
    -v "${REPO_ROOT}/${ARTIFACTS_DIR}:/out" \
    "${CHECKOV_IMAGE}" \
    --directory /chart \
    --framework "${FRAMEWORK}" \
    --compact \
    --quiet \
    "${skip_args[@]}" \
    -o json \
    > "${out_json}" 2>"${ARTIFACTS_DIR}/checkov-${chart_name}.stderr"
  rc=$?
  set -e

  if [[ ! -s "${out_json}" ]]; then
    fail "Checkov produced no report for ${dir} (rc=${rc}); stderr tail:"
    tail -5 "${ARTIFACTS_DIR}/checkov-${chart_name}.stderr" 2>/dev/null | sed 's/^/    /' || true
    total_failed=$((total_failed + 1))
    continue
  fi

  # Checkov JSON: top object (or array of objects for multi-framework). Sum the
  # passed/failed counts robustly across either shape.
  passed=$(jq -r '[(if type=="array" then .[] else . end) | .summary.passed // 0] | add // 0' "${out_json}" 2>/dev/null || echo 0)
  failed=$(jq -r '[(if type=="array" then .[] else . end) | .summary.failed // 0] | add // 0' "${out_json}" 2>/dev/null || echo 0)
  passed=${passed:-0}; failed=${failed:-0}
  scanned=$((scanned + 1))
  total_passed=$((total_passed + passed))
  total_failed=$((total_failed + failed))

  if [[ "${failed}" -gt 0 ]]; then
    warn "${chart_name}: ${passed} passed, ${failed} FAILED checks (report: ${out_json})"
    # Show the top failed checks: id + name + resource (honest, glanceable).
    jq -r '
      [(if type=="array" then .[] else . end)
        | .results.failed_checks[]?
        | "    - \(.check_id) \(.check_name) :: \(.resource)"] | unique | .[]
    ' "${out_json}" 2>/dev/null | head -15 || true
  else
    ok "${chart_name}: ${passed} passed, 0 failed (report: ${out_json})"
  fi
done

echo
step "summary: ${scanned} chart(s) scanned · ${total_passed} passed · ${total_failed} FAILED checks"
echo "[iac] reports: ${ARTIFACTS_DIR}/checkov-*.json"

case "${FAIL_LEVEL}" in
  off)
    ok "fail-level=off — informational scan, exit 0 regardless of findings."
    exit 0
    ;;
  warn)
    if [[ ${total_failed} -gt 0 ]]; then
      warn "fail-level=warn — ${total_failed} failed check(s) reported but NOT blocking."
      warn "Flip COMPLIANCE_FAIL_LEVEL=error once the charts are clean to gate hard."
    else
      ok "no failed checks across all charts."
    fi
    exit 0
    ;;
  error)
    if [[ ${total_failed} -gt 0 ]]; then
      fail "fail-level=error — ${total_failed} failed check(s). Inspect ${ARTIFACTS_DIR}/"
      exit 1
    fi
    ok "fail-level=error — every chart clean."
    exit 0
    ;;
  *)
    fail "unknown COMPLIANCE_FAIL_LEVEL='${FAIL_LEVEL}' (want off|warn|error)"
    exit 2
    ;;
esac
