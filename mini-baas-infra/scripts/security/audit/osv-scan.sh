#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    osv-scan.sh                                        :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Unified dependency-CVE scan with Google OSV-Scanner across the THREE language
# planes — Node (TS app + SDK), Go (control plane), Rust (data plane + realtime).
# Runs the official ghcr.io/google/osv-scanner image — no host install required.
#
# HONESTY: a scanner finding nothing is NOT proof of security — it bounds known
# classes (here: published vulns in the OSV.dev database keyed off lockfiles); an
# independent pen test is still required (HUMAN-ATOMS).
#
# Usage:
#   bash apps/baas/mini-baas-infra/scripts/security/audit/osv-scan.sh
#
# Environment knobs:
#   AUDIT_FAIL_LEVEL   CRITICAL|HIGH|MEDIUM|LOW (default: HIGH) — min severity
#                      at which the script exits non-zero
#   OSV_IMAGE          override the scanner image (default ghcr.io/google/osv-scanner)
#   AUDIT_ARTIFACTS_DIR  apps/baas/mini-baas-infra/artifacts/security-audit (default)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
ARTIFACTS_DIR="${AUDIT_ARTIFACTS_DIR:-${BAAS_DIR}/artifacts/security-audit}"
mkdir -p "${ARTIFACTS_DIR}"

OSV_IMAGE="${OSV_IMAGE:-ghcr.io/google/osv-scanner:latest}"
FAIL_LEVEL="${AUDIT_FAIL_LEVEL:-HIGH}"

# ── colour helpers (mirror zap-baseline.sh) ──────────────────────────────────
cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
amber() { printf '\033[0;33m%s\033[0m\n' "$*"; }

# ── EXIT trap so a partial run still tells the operator where artifacts are ───
JSON_OUT="${ARTIFACTS_DIR}/osv.json"
TABLE_OUT="${ARTIFACTS_DIR}/osv.txt"
on_exit() {
  local rc=$?
  echo
  echo "[osv] reports:"
  echo "  - JSON:  ${JSON_OUT}"
  echo "  - TABLE: ${TABLE_OUT}"
  [[ ${rc} -ne 0 ]] && red "[osv] exited rc=${rc}"
  return 0
}
trap on_exit EXIT

cyan "[osv] OSV-Scanner — dependency CVE scan (Node + Go + Rust) @ $(date -u +%FT%TZ)"
cyan "[osv] fail-level >= ${FAIL_LEVEL} | image ${OSV_IMAGE}"

# ── the lockfiles to scan (each is a distinct ecosystem manifest) ────────────
# Paths are relative to BAAS_DIR (mounted at /src inside the container).
# NOTE on Go: OSV-Scanner's lockfile extractor parses `go.mod` (the resolved
# module graph), NOT `go.sum` (which is only a checksum DB and has no extractor
# — it aborts the run). go.mod sits beside go.sum, so we target go.mod.
LOCKFILES=(
  "pnpm-lock.yaml"
  "package-lock.json"
  "src/package-lock.json"
  "go/control-plane/go.mod"
  "docker/services/data-plane-router/Cargo.lock"
  "docker/services/realtime/realtime-agnostic/Cargo.lock"
)

LOCK_ARGS=()
present=0
for lf in "${LOCKFILES[@]}"; do
  if [[ -f "${BAAS_DIR}/${lf}" ]]; then
    LOCK_ARGS+=( "--lockfile=/src/${lf}" )
    present=$((present + 1))
    echo "  + ${lf}"
  else
    amber "  - ${lf} (absent — skipped)"
  fi
done

if [[ ${present} -eq 0 ]]; then
  red "[osv] no lockfiles found under ${BAAS_DIR} — nothing to scan"
  exit 2
fi

# ── run #1 : machine-readable JSON (the durable artifact) ────────────────────
# osv-scanner exits 1 when it finds *any* vuln; we capture that and re-derive a
# severity-gated verdict ourselves so AUDIT_FAIL_LEVEL is honoured.
cyan "[osv] scanning ${present} lockfile(s) → JSON"
docker run --rm \
  -v "${REPO_ROOT}/${BAAS_DIR}:/src:ro" \
  "${OSV_IMAGE}" \
  scan source \
    --format=json \
    "${LOCK_ARGS[@]}" \
  > "${JSON_OUT}" 2>"${ARTIFACTS_DIR}/osv.stderr.log" || true

if [[ ! -s "${JSON_OUT}" ]]; then
  red "[osv] no JSON produced — scanner aborted (see ${ARTIFACTS_DIR}/osv.stderr.log)"
  tail -20 "${ARTIFACTS_DIR}/osv.stderr.log" 2>/dev/null || true
  exit 3
fi

# ── run #2 : human-readable table (best-effort, non-fatal) ───────────────────
cyan "[osv] re-rendering → table"
docker run --rm \
  -v "${REPO_ROOT}/${BAAS_DIR}:/src:ro" \
  "${OSV_IMAGE}" \
  scan source \
    --format=table \
    "${LOCK_ARGS[@]}" \
  > "${TABLE_OUT}" 2>/dev/null || true

# ── verdict: count vulns by severity from the JSON ───────────────────────────
# OSV severity lives per-package; we read the worst CVSS band per vuln. The OSV
# JSON groups: results[].packages[].vulnerabilities[].severity[] (CVSS vectors)
# and results[].packages[].groups[].max_severity (a numeric CVSS score string).
# We map numeric CVSS → band: >=9 CRITICAL, >=7 HIGH, >=4 MEDIUM, >0 LOW.
band_at_or_above() {
  # $1 = threshold band → returns the jq numeric floor
  case "$1" in
    CRITICAL) echo 9.0 ;;
    HIGH)     echo 7.0 ;;
    MEDIUM)   echo 4.0 ;;
    LOW)      echo 0.1 ;;
    *)        echo 7.0 ;;
  esac
}
floor="$(band_at_or_above "${FAIL_LEVEL}")"

# Total vulns (any severity) and gated count (>= floor by max_severity).
total=$(jq -r '
  [ .results[]?.packages[]?.vulnerabilities[]? ] | length
' "${JSON_OUT}" 2>/dev/null || echo 0)

gated=$(jq -r --argjson floor "${floor}" '
  [ .results[]?.packages[]?.groups[]?
    | (.max_severity // "0")
    | (try tonumber catch 0)
    | select(. >= $floor)
  ] | length
' "${JSON_OUT}" 2>/dev/null || echo 0)

# Some advisories carry no CVSS score (max_severity ""/absent) — surface those
# separately so "0 gated" is never silently hiding unscored highs.
unscored=$(jq -r '
  [ .results[]?.packages[]?.groups[]?
    | (.max_severity // "")
    | select(. == "" or . == "0")
  ] | length
' "${JSON_OUT}" 2>/dev/null || echo 0)

echo
cyan "[osv] summary: ${total} total advisor(y/ies) across ${present} lockfile(s)"
cyan "[osv]          ${gated} at CVSS >= ${FAIL_LEVEL} (${floor}); ${unscored} unscored group(s)"

if [[ "${gated}" -gt 0 ]]; then
  red "[osv] FAIL — ${gated} vulnerabilit(y/ies) at or above ${FAIL_LEVEL}"
  jq -r '
    .results[]? as $r
    | $r.packages[]?
    | . as $p
    | $p.groups[]?
    | select(((.max_severity // "0") | (try tonumber catch 0)) >= '"${floor}"')
    | "  - " + ($p.package.ecosystem // "?") + ":" + ($p.package.name // "?")
      + " @ " + ($p.package.version // "?")
      + "  CVSS " + (.max_severity // "?")
      + "  [" + ((.ids // []) | join(",")) + "]"
  ' "${JSON_OUT}" 2>/dev/null | sort -u | head -25 || true
  exit 1
fi

if [[ "${total}" -gt 0 ]]; then
  amber "[osv] WARN — ${total} advisory(ies) present but none >= ${FAIL_LEVEL} (not blocking)"
  exit 0
fi

green "[osv] OK — no known vulnerabilities in any lockfile"
exit 0
