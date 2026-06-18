#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    run-security-scans.sh                              :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/31 17:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/31 17:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Unified security scanner — runs SAST, SCA, container scan, and secret scan
# in sequence, all via Docker so the host needs nothing more than `docker`.
#
# Tools wrapped:
#   - Semgrep            (SAST — TypeScript / NestJS / Docker / k8s rules)
#   - npm audit          (SCA — workspace lockfiles)
#   - Trivy              (Container — built BaaS images + filesystem)
#   - TruffleHog         (Secret — git history + working tree)
#
# Usage:
#   bash scripts/security/run-security-scans.sh
#   bash scripts/security/run-security-scans.sh --only=semgrep,trivy
#   bash scripts/security/run-security-scans.sh --skip=trufflehog
#
# Environment knobs:
#   SECURITY_FAIL_LEVEL    high|critical (default: high) — npm audit threshold
#   SECURITY_TRIVY_SEVERITY HIGH,CRITICAL (default)
#   SECURITY_SEMGREP_CONFIG p/owasp-top-ten,p/typescript,p/dockerfile,p/nodejs (default)
#   SECURITY_ARTIFACTS_DIR  artifacts/security (default)
#   SKIP_BUILD              1 to skip baas image build before Trivy scan
#
# Exit code: 0 only when every enabled scanner returns no findings at or above
# the configured severity threshold.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="."
ARTIFACTS_DIR="${SECURITY_ARTIFACTS_DIR:-${BAAS_DIR}/artifacts/security}"
mkdir -p "${ARTIFACTS_DIR}"

# ── colour helpers ───────────────────────────────────────────────────────────
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
amber() { printf '\033[0;33m%s\033[0m\n' "$*"; }
step() { cyan "[sec] ${*}"; }
fail() { red "[sec] FAIL: $*"; }
warn() { amber "[sec] WARN: $*"; }
ok() { green "[sec] OK:   $*"; }

# ── argument parsing ─────────────────────────────────────────────────────────
ONLY=""
SKIP=""
for arg in "$@"; do
  case "${arg}" in
  --only=*) ONLY="${arg#--only=}" ;;
  --skip=*) SKIP="${arg#--skip=}" ;;
  --help | -h)
    sed -n '/^# Usage:/,/^# Exit code:/p' "$0" | sed 's/^# \?//'
    exit 0
    ;;
  esac
done

enabled() {
  local tool="$1"
  if [[ -n "${ONLY}" ]] && [[ ",${ONLY}," != *",${tool},"* ]]; then return 1; fi
  if [[ -n "${SKIP}" ]] && [[ ",${SKIP}," == *",${tool},"* ]]; then return 1; fi
  return 0
}

# ── tool runners (all use Docker, never assume host install) ─────────────────

run_semgrep() {
  step "Semgrep — SAST on TypeScript / Dockerfiles"
  local cfg="${SECURITY_SEMGREP_CONFIG:-p/owasp-top-ten p/typescript p/dockerfile p/nodejs p/javascript}"
  local out="${ARTIFACTS_DIR}/semgrep.json"
  local cfg_args=""
  for c in ${cfg}; do cfg_args="${cfg_args} --config=${c}"; done

  if ! docker run --rm \
    -v "${REPO_ROOT}:/src:ro" \
    -v "${REPO_ROOT}/${ARTIFACTS_DIR}:/out" \
    -w /src \
    returntocorp/semgrep:latest \
    semgrep scan \
    ${cfg_args} \
    --severity=ERROR --severity=WARNING \
    --exclude='**/node_modules' \
    --exclude='**/dist' \
    --exclude='**/.next' \
    --exclude='**/coverage' \
    --exclude='**/.venv' \
    --exclude='**/playwright-report' \
    --exclude='**/test-results' \
    --exclude='vendor' \
    --json-output=/out/semgrep.json \
    --metrics=off \
    --no-rewrite-rule-ids \
    2>&1 | tail -40; then
    fail "Semgrep encountered an error"
    return 1
  fi

  local errors warnings
  errors=$(jq -r '[.results[]? | select(.extra.severity == "ERROR")] | length' "${out}" 2>/dev/null || echo 0)
  warnings=$(jq -r '[.results[]? | select(.extra.severity == "WARNING")] | length' "${out}" 2>/dev/null || echo 0)

  if [[ "${errors}" -gt 0 ]]; then
    fail "Semgrep: ${errors} ERROR + ${warnings} WARNING findings (report: ${out})"
    return 1
  fi
  if [[ "${warnings}" -gt 0 ]]; then
    warn "Semgrep: 0 ERROR but ${warnings} WARNING findings (report: ${out})"
  else
    ok "Semgrep: clean"
  fi
  return 0
}

run_npm_audit() {
  step "npm audit — SCA on workspace lockfiles"
  local level="${SECURITY_FAIL_LEVEL:-high}"
  local rc=0
  local out="${ARTIFACTS_DIR}/npm-audit.txt"
  : >"${out}"

  # Each top-level package.json with a lockfile gets audited inside a
  # node:20-alpine container so we don't trust the host npm.
  local lock_dirs=(
    "src"
    "sdks/js"
  )

  for dir in "${lock_dirs[@]}"; do
    [[ -f "${dir}/package-lock.json" ]] || [[ -f "${dir}/pnpm-lock.yaml" ]] || continue
    echo "── ${dir} ──" | tee -a "${out}"
    if [[ -f "${dir}/package-lock.json" ]]; then
      if ! docker run --rm \
        -v "${REPO_ROOT}/${dir}:/work:ro" \
        -w /work \
        public.ecr.aws/docker/library/node:20-alpine \
        npm audit --audit-level="${level}" --no-fund 2>&1 | tee -a "${out}"; then
        rc=$((rc + 1))
      fi
    elif [[ -f "${dir}/pnpm-lock.yaml" ]]; then
      # pnpm projects: enable corepack so pnpm is available.
      if ! docker run --rm \
        -v "${REPO_ROOT}/${dir}:/work:ro" \
        -w /work \
        public.ecr.aws/docker/library/node:20-alpine \
        sh -ec 'corepack enable >/dev/null 2>&1 && pnpm audit --prod --audit-level='"${level}" 2>&1 | tee -a "${out}"; then
        rc=$((rc + 1))
      fi
    fi
  done

  if [[ ${rc} -gt 0 ]]; then
    fail "npm/pnpm audit: ${rc} workspace(s) reported vulnerabilities at >=${level} (report: ${out})"
    return 1
  fi
  ok "npm/pnpm audit: every workspace clean at >=${level}"
  return 0
}

run_trivy() {
  step "Trivy — Container + filesystem scan"
  local severity="${SECURITY_TRIVY_SEVERITY:-HIGH,CRITICAL}"
  local out_dir="${ARTIFACTS_DIR}/trivy"
  local cache_dir="${out_dir}/cache"
  local ignore_file="${BAAS_DIR}/.trivyignore"
  mkdir -p "${out_dir}"
  mkdir -p "${cache_dir}"
  rm -f "${out_dir}/trivy-fs.json" "${out_dir}"/trivy-image-*.json

  # Filesystem scan first — picks up Dockerfile misconfigs + dep tree CVEs
  # without needing the images to be built yet.
  step "  Trivy filesystem scan"
  if ! docker run --rm \
    -v "${REPO_ROOT}/${BAAS_DIR}:/src:ro" \
    -v "${REPO_ROOT}/${out_dir}:/out" \
    -v "${REPO_ROOT}/${cache_dir}:/root/.cache/trivy" \
    aquasec/trivy:latest \
    fs --quiet \
    --severity "${severity}" \
    --ignore-unfixed \
    --format json \
    --skip-java-db-update \
    --ignorefile /src/.trivyignore \
    --output /out/trivy-fs.json \
    --skip-dirs node_modules,dist,.git,coverage,playwright-report,vendor,target,build \
    /src 2>&1 | tail -10; then
    fail "Trivy filesystem scan failed"
    return 1
  fi

  # Container image scan — only if SKIP_BUILD!=1 and the BaaS image exists.
  if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    step "  Trivy image scan (shipped runtime images on host)"
    # Scan SHIPPED runtime images only — the newman edge-test runner and the
    # rust/node build toolchains are never deployed, so their base CVEs aren't
    # part of the product's attack surface.
    local images
    images=$(docker images --format '{{.Repository}}:{{.Tag}}' |
      grep -E '^mini-baas|^grobase|^dlesieur/realtime' |
      grep -vE '<none>|newman|rust-toolchain|node-build|go-build|toolchain' |
      head -20 || true)
    if [[ -z "${images}" ]]; then
      warn "  no mini-baas images on host — run \`make baas-up\` first to scan images"
    else
      local image_list="${out_dir}/.trivy-images.txt"
      local parallelism="${SECURITY_TRIVY_IMAGE_PARALLELISM:-4}"
      local img_rc=0
      printf '%s\n' "${images}" >"${image_list}"
      if ! xargs -r -P "${parallelism}" -I '{}' bash -c '
        set -euo pipefail
        img="$1"
        repo_root="$2"
        out_dir="$3"
        severity="$4"
        cache_dir="$5"
        ignore_file="$6"
        safe_name=$(printf "%s" "${img}" | tr "/:" "__")
        cache_root="${repo_root}/${cache_dir}"
        printf "\033[0;36m[sec]     scanning %s\033[0m\n" "${img}"
        docker run --rm \
          -v /var/run/docker.sock:/var/run/docker.sock \
          -v "${repo_root}/${out_dir}:/out" \
          -v "${repo_root}/${ignore_file}:/trivyignore:ro" \
          -v "${cache_root}/db:/root/.cache/trivy/db:ro" \
          aquasec/trivy:latest \
          image --quiet \
                --skip-db-update \
                --skip-java-db-update \
                --severity "${severity}" \
                --ignore-unfixed \
                --ignorefile /trivyignore \
                --format json \
                --output "/out/trivy-image-${safe_name}.json" \
                "${img}" 2>&1 | tail -3
      ' _ '{}' "${REPO_ROOT}" "${out_dir}" "${severity}" "${cache_dir}" "${ignore_file}" <"${image_list}"; then
        img_rc=1
      fi
      if [[ ${img_rc} -gt 0 ]]; then
        warn "  one or more image scans failed (reports in ${out_dir})"
        return 1
      fi
    fi
  fi

  # Verdict: aggregate fs vulns + image vulns.
  local total=0
  if [[ -f "${out_dir}/trivy-fs.json" ]]; then
    local n
    n=$(jq -r '[.Results[]?.Vulnerabilities[]?] | length' "${out_dir}/trivy-fs.json" 2>/dev/null || echo 0)
    total=$((total + n))
  fi
  for f in "${out_dir}"/trivy-image-*.json; do
    [[ -f "$f" ]] || continue
    local n
    n=$(jq -r '[.Results[]?.Vulnerabilities[]?] | length' "$f" 2>/dev/null || echo 0)
    total=$((total + n))
  done

  if [[ ${total} -gt 0 ]]; then
    fail "Trivy: ${total} finding(s) at severity >=${severity} (reports in ${out_dir})"
    return 1
  fi
  ok "Trivy: clean at >=${severity}"
  return 0
}

run_trufflehog() {
  step "TruffleHog — secret scan on git history + working tree"
  local out="${ARTIFACTS_DIR}/trufflehog.json"

  # Git history scan — finds verified secrets accidentally committed.
  if ! docker run --rm \
    -v "${REPO_ROOT}:/repo:ro" \
    -w /repo \
    trufflesecurity/trufflehog:latest \
    git file:///repo \
    --no-update \
    --only-verified \
    --json \
    >"${out}" 2>/dev/null; then
    # TruffleHog returns non-zero when it finds secrets; capture+parse below.
    :
  fi

  local count
  count=$(wc -l <"${out}" 2>/dev/null || echo 0)
  count=$(echo "${count}" | tr -d ' ')

  if [[ "${count}" -gt 0 ]]; then
    fail "TruffleHog: ${count} verified secret(s) found in git history (report: ${out})"
    head -5 "${out}" | jq -r '.SourceMetadata.Data.Git.repository + " :: " + .SourceMetadata.Data.Git.file + ":" + (.SourceMetadata.Data.Git.line|tostring) + " :: " + .DetectorName' 2>/dev/null || true
    return 1
  fi
  ok "TruffleHog: no verified secrets in git history"
  return 0
}

# ── orchestration ────────────────────────────────────────────────────────────
fail_count=0

step "Security scan suite started ($(date -u +%FT%TZ))"
step "Artifacts will land under ${ARTIFACTS_DIR}"

if enabled semgrep; then run_semgrep || fail_count=$((fail_count + 1)); fi
if enabled npm-audit; then run_npm_audit || fail_count=$((fail_count + 1)); fi
if enabled trivy; then run_trivy || fail_count=$((fail_count + 1)); fi
if enabled trufflehog; then run_trufflehog || fail_count=$((fail_count + 1)); fi

echo
if [[ ${fail_count} -eq 0 ]]; then
  green "[sec] OK — every enabled scanner is clean. Reports in ${ARTIFACTS_DIR}/"
  exit 0
else
  red "[sec] ${fail_count} scanner(s) reported findings. Inspect ${ARTIFACTS_DIR}/"
  exit 1
fi
