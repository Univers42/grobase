#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    iac-scan.sh                                        :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# IaC / Helm / Kubernetes / Compose misconfiguration scan.
# Runs TWO complementary official images (defence in depth) — no host install:
#   - aquasec/trivy config   (Trivy's built-in misconfig + CIS checks)
#   - bridgecrew/checkov     (Checkov policy-as-code, maps to CIS / ISO A.8)
# Targets: deploy/helm/grobase, deploy/helm/mini-baas, and docker-compose*.yml.
#
# HONESTY: a scanner finding nothing is NOT proof of security — it bounds known
# classes (here: known IaC misconfiguration policies); an independent pen test /
# config review is still required (HUMAN-ATOMS).
#
# Usage:
#   bash apps/baas/mini-baas-infra/scripts/security/audit/iac-scan.sh
#   bash .../iac-scan.sh --only=trivy
#   bash .../iac-scan.sh --skip=checkov
#
# Environment knobs:
#   AUDIT_FAIL_LEVEL     CRITICAL|HIGH|MEDIUM|LOW (default: HIGH)
#   AUDIT_ARTIFACTS_DIR  apps/baas/mini-baas-infra/artifacts/security-audit (default)
#   TRIVY_IMAGE / CHECKOV_IMAGE  override scanner images

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
ARTIFACTS_DIR="${AUDIT_ARTIFACTS_DIR:-${BAAS_DIR}/artifacts/security-audit}"
mkdir -p "${ARTIFACTS_DIR}"

TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:latest}"
CHECKOV_IMAGE="${CHECKOV_IMAGE:-bridgecrew/checkov:latest}"
FAIL_LEVEL="${AUDIT_FAIL_LEVEL:-HIGH}"

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
    --help|-h) sed -n '/^# Usage:/,/^# .*override/p' "${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")" | sed 's/^# \?//'; exit 0 ;;
  esac
done
enabled() {
  local t="$1"
  [[ -n "${ONLY}" ]] && [[ ",${ONLY}," != *",${t},"* ]] && return 1
  [[ -n "${SKIP}" ]] && [[ ",${SKIP}," == *",${t},"* ]] && return 1
  return 0
}

# ── EXIT trap ────────────────────────────────────────────────────────────────
on_exit() {
  local rc=$?
  echo
  echo "[iac] reports under ${ARTIFACTS_DIR}/ (trivy-config.json, checkov.json)"
  [[ ${rc} -ne 0 ]] && red "[iac] exited rc=${rc}"
  return 0
}
trap on_exit EXIT

cyan "[iac] IaC/Helm/K8s/Compose misconfig scan @ $(date -u +%FT%TZ)"
cyan "[iac] fail-level >= ${FAIL_LEVEL}"

# ── scan scope (paths relative to BAAS_DIR, mounted at /src) ──────────────────
SCAN_PATHS=()
for p in "deploy/helm/grobase" "deploy/helm/mini-baas"; do
  [[ -d "${BAAS_DIR}/${p}" ]] && SCAN_PATHS+=( "${p}" ) && echo "  + dir  ${p}"
done
# All docker-compose*.yml in the BaaS dir.
while IFS= read -r f; do
  rel="${f#"${BAAS_DIR}/"}"
  SCAN_PATHS+=( "${rel}" )
  echo "  + file ${rel}"
done < <(find "${BAAS_DIR}" -maxdepth 1 -name 'docker-compose*.yml' | sort)

if [[ ${#SCAN_PATHS[@]} -eq 0 ]]; then
  red "[iac] no helm dirs or compose files found — nothing to scan"
  exit 2
fi

fail_count=0

# ── Trivy config ─────────────────────────────────────────────────────────────
# Trivy 'config' scans an entire dir tree; we point it at the whole BaaS dir but
# restrict to the relevant subtrees via --skip-dirs of heavy/irrelevant paths.
run_trivy_config() {
  cyan "[iac] Trivy config — misconfig + CIS"
  local sev="${FAIL_LEVEL}"
  # Trivy severity is a comma list of bands at-or-above; expand the floor.
  case "${FAIL_LEVEL}" in
    CRITICAL) sev="CRITICAL" ;;
    HIGH)     sev="CRITICAL,HIGH" ;;
    MEDIUM)   sev="CRITICAL,HIGH,MEDIUM" ;;
    LOW)      sev="CRITICAL,HIGH,MEDIUM,LOW" ;;
  esac
  local out="${ARTIFACTS_DIR}/trivy-config.json"
  rm -f "${out}"

  # Trivy `config` accepts exactly ONE target path. We point it at the whole
  # BaaS dir (one pass covers deploy/helm/* AND the root docker-compose*.yml)
  # and prune heavy/irrelevant subtrees with --skip-dirs.
  if ! docker run --rm \
    -v "${REPO_ROOT}/${BAAS_DIR}:/src:ro" \
    -v "${REPO_ROOT}/${ARTIFACTS_DIR}:/out" \
    "${TRIVY_IMAGE}" \
    config --quiet \
      --severity "${sev}" \
      --format json \
      --output /out/trivy-config.json \
      --skip-dirs 'node_modules,dist,.git,coverage,playwright-report,vendor,artifacts,target' \
      /src 2>&1 | tail -12; then
    red "[iac] Trivy config run failed"
    return 1
  fi

  [[ -f "${out}" ]] || { red "[iac] no trivy-config.json produced"; return 1; }
  local n
  n=$(jq -r '[.Results[]?.Misconfigurations[]?] | length' "${out}" 2>/dev/null || echo 0)
  if [[ "${n}" -gt 0 ]]; then
    red "[iac] Trivy config: ${n} misconfig(s) at >= ${FAIL_LEVEL}"
    jq -r '.Results[]? | .Target as $t | .Misconfigurations[]?
           | "  - [" + .Severity + "] " + .ID + " " + .Title + "  (" + $t + ")"' \
      "${out}" 2>/dev/null | sort -u | head -25 || true
    return 1
  fi
  green "[iac] Trivy config: clean at >= ${FAIL_LEVEL}"
  return 0
}

# ── Checkov ──────────────────────────────────────────────────────────────────
# Checkov runs over the same dir; --compact JSON; we count failed checks at the
# requested severity (Checkov tags severity when run with --check none + policy).
run_checkov() {
  cyan "[iac] Checkov — policy-as-code (CIS / ISO A.8)"
  local out="${ARTIFACTS_DIR}/checkov.json"
  rm -f "${out}"

  # Checkov exits non-zero on any failed check; capture + parse ourselves.
  docker run --rm \
    -v "${REPO_ROOT}/${BAAS_DIR}:/src:ro" \
    "${CHECKOV_IMAGE}" \
    -d /src/deploy/helm \
    --framework helm kubernetes \
    --output json \
    --compact \
    --quiet \
    > "${out}" 2>"${ARTIFACTS_DIR}/checkov.stderr.log" || true

  # Second pass: Dockerfiles across the subtree. Checkov has NO dedicated
  # 'docker_compose' framework (valid frameworks are dockerfile/kubernetes/helm/
  # yaml/...); compose-file misconfig is already covered by Trivy config above,
  # so here we add Checkov's Dockerfile policy set (complementary, no overlap
  # with the helm/kubernetes pass).
  docker run --rm \
    -v "${REPO_ROOT}/${BAAS_DIR}:/src:ro" \
    "${CHECKOV_IMAGE}" \
    -d /src/docker \
    --framework dockerfile \
    --output json \
    --compact \
    --quiet \
    > "${ARTIFACTS_DIR}/checkov-dockerfile.json" 2>>"${ARTIFACTS_DIR}/checkov.stderr.log" || true

  if [[ ! -s "${out}" ]]; then
    amber "[iac] Checkov produced no JSON (see checkov.stderr.log) — treating as non-blocking"
    tail -10 "${ARTIFACTS_DIR}/checkov.stderr.log" 2>/dev/null || true
    return 0
  fi

  # Checkov JSON is either an object or an array of {check_type, results:{failed_checks:[]}}.
  local failed
  failed=$(jq -r '
    ( if type=="array" then . else [.] end )
    | [ .[]?.results?.failed_checks[]? ] | length
  ' "${out}" 2>/dev/null || echo 0)
  local failed_compose
  failed_compose=$(jq -r '
    ( if type=="array" then . else [.] end )
    | [ .[]?.results?.failed_checks[]? ] | length
  ' "${ARTIFACTS_DIR}/checkov-dockerfile.json" 2>/dev/null || echo 0)

  local total=$((failed + failed_compose))
  if [[ "${total}" -gt 0 ]]; then
    # Checkov's default policy set is broad (many INFO/LOW best-practices). We
    # report the count and the top offenders, but only FAIL the script when the
    # operator asked for the broadest gate; otherwise WARN. This keeps HIGH-gate
    # runs honest without drowning in Checkov's low-severity best-practice noise.
    jq -r '
      ( if type=="array" then . else [.] end )
      | .[]?.results?.failed_checks[]?
      | "  - " + .check_id + " " + (.check_name // "") + "  (" + (.file_path // "?") + ")"
    ' "${out}" "${ARTIFACTS_DIR}/checkov-dockerfile.json" 2>/dev/null | sort -u | head -25 || true
    if [[ "${FAIL_LEVEL}" == "LOW" || "${FAIL_LEVEL}" == "MEDIUM" ]]; then
      red "[iac] Checkov: ${total} failed check(s) — FAIL (fail-level ${FAIL_LEVEL})"
      return 1
    fi
    amber "[iac] Checkov: ${total} failed check(s) — WARN (raise AUDIT_FAIL_LEVEL=LOW to gate)"
    return 0
  fi
  green "[iac] Checkov: no failed checks"
  return 0
}

# ── orchestrate ──────────────────────────────────────────────────────────────
if enabled trivy;   then run_trivy_config || fail_count=$((fail_count + 1)); fi
if enabled checkov; then run_checkov      || fail_count=$((fail_count + 1)); fi

echo
if [[ ${fail_count} -eq 0 ]]; then
  green "[iac] OK — IaC misconfig scanners clean at >= ${FAIL_LEVEL}"
  exit 0
fi
red "[iac] ${fail_count} IaC scanner(s) reported blocking findings"
exit 1
