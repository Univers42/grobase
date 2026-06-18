#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    steampipe-compliance.sh                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Cloud compliance-as-code with Steampipe + Powerpipe — wired now, RUNS on cloud.
#
# Steampipe exposes a live cloud account as SQL tables; Powerpipe runs the
# Compliance mods (SOC 2, ISO 27001, GDPR, CIS benchmarks) against them. Like
# Prowler, this audits a LIVE cloud account and needs real credentials, which we
# do NOT have locally.
#
#   THEREFORE: with no credentials, this script PRINTS exactly what it WOULD run
#   (the plugin, the benchmark, the full docker command) and EXITS 0 with a clear
#   "needs live cloud creds" message. It does NOT fail. When credentials are
#   present it installs the plugin + mod and runs the benchmark for real.
#
# This is a second cloud-account engine alongside prowler-scan.sh; the locally
# runnable proxy is infra-compliance-scan.sh (Checkov over Helm). Full split:
# wiki/compliance/infra-compliance-scanning.md.
#
# Docker-first: runs the official Powerpipe + Steampipe images. Host needs only
# `docker`. (Powerpipe is the modern split of Steampipe's benchmark engine; this
# script drives the powerpipe image and points it at a steampipe DB.)
#
# Usage:
#   bash apps/baas/mini-baas-infra/scripts/security/compliance/steampipe-compliance.sh
#   CLOUD=aws BENCHMARK=soc_2          MOD=aws_compliance bash .../steampipe-compliance.sh
#   CLOUD=aws BENCHMARK=iso_27001_2022 MOD=aws_compliance bash .../steampipe-compliance.sh
#   CLOUD=aws BENCHMARK=gdpr           MOD=aws_compliance bash .../steampipe-compliance.sh
#   CLOUD=aws BENCHMARK=cis_v300       MOD=aws_compliance bash .../steampipe-compliance.sh
#   CLOUD=gcp BENCHMARK=cis_v200       MOD=gcp_compliance bash .../steampipe-compliance.sh
#
# Environment knobs:
#   CLOUD        aws|gcp|azure|kubernetes   (default: aws) — selects the steampipe plugin
#   MOD          powerpipe compliance mod    (default: aws_compliance)
#   BENCHMARK    powerpipe benchmark name    (default: soc_2)
#                AWS mod ships: soc_2 · iso_27001_2022 · gdpr · cis_v300 · hipaa_final_omnibus_*
#   STEAMPIPE_IMAGE   default: turbot/steampipe:latest
#   POWERPIPE_IMAGE   default: turbot/powerpipe:latest
#   COMPLIANCE_ARTIFACTS_DIR  default: artifacts/security-audit/compliance
#   AWS_* / GOOGLE_APPLICATION_CREDENTIALS / AZURE_*  — presence triggers a real run
#
# Exit code: 0 when there are no credentials (informational); when creds exist,
# Powerpipe's own exit code is surfaced.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
ARTIFACTS_DIR="${COMPLIANCE_ARTIFACTS_DIR:-${BAAS_DIR}/artifacts/security-audit/compliance}"
mkdir -p "${ARTIFACTS_DIR}"

CLOUD="${CLOUD:-aws}"
MOD="${MOD:-aws_compliance}"
BENCHMARK="${BENCHMARK:-soc_2}"
STEAMPIPE_IMAGE="${STEAMPIPE_IMAGE:-turbot/steampipe:latest}"
POWERPIPE_IMAGE="${POWERPIPE_IMAGE:-turbot/powerpipe:latest}"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
amber() { printf '\033[0;33m%s\033[0m\n' "$*"; }
step() { cyan "[steampipe] ${*}"; }
fail() { red "[steampipe] FAIL: $*"; }
warn() { amber "[steampipe] WARN: $*"; }
ok() { green "[steampipe] OK:   $*"; }

for arg in "$@"; do
  case "${arg}" in
  --help | -h)
    sed -n '/^# Usage:/,/^# Exit code:/p' "$0" | sed 's/^# \?//'
    exit 0
    ;;
  esac
done

# Same credential detection contract as prowler-scan.sh.
have_creds() {
  case "${CLOUD}" in
  aws)
    [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]] && return 0
    [[ -n "${AWS_PROFILE:-}" ]] && return 0
    [[ -f "${HOME}/.aws/credentials" ]] && return 0
    return 1
    ;;
  gcp)
    [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" && -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]] && return 0
    [[ -f "${HOME}/.config/gcloud/application_default_credentials.json" ]] && return 0
    return 1
    ;;
  azure)
    [[ -n "${AZURE_CLIENT_ID:-}" && -n "${AZURE_CLIENT_SECRET:-}" && -n "${AZURE_TENANT_ID:-}" ]] && return 0
    [[ -d "${HOME}/.azure" ]] && return 0
    return 1
    ;;
  kubernetes)
    [[ -n "${KUBECONFIG:-}" && -f "${KUBECONFIG}" ]] && return 0
    [[ -f "${HOME}/.kube/config" ]] && return 0
    return 1
    ;;
  *) return 1 ;;
  esac
}

step "Cloud compliance benchmark — Steampipe + Powerpipe"
step "Target cloud   : ${CLOUD}  (steampipe plugin)"
step "Mod / benchmark: ${MOD} / benchmark.${BENCHMARK}"

if ! have_creds; then
  echo
  amber "════════════════════════════════════════════════════════════════════════"
  amber " NO ${CLOUD^^} CREDENTIALS DETECTED — this is the EXPECTED local state."
  amber "════════════════════════════════════════════════════════════════════════"
  echo
  cyan "Steampipe queries a LIVE ${CLOUD} account as SQL; Powerpipe runs the"
  cyan "compliance benchmarks against it. With no credentials it cannot — and we"
  cyan "do NOT pretend a local run audits 'SOC 2'. Export real ${CLOUD} creds and"
  cyan "re-run this exact script to get a genuine benchmark report."
  echo
  cyan "WHAT IT WOULD RUN:"
  echo "  plugin     : steampipe plugin install ${CLOUD}"
  echo "  mod        : ${MOD}  (Powerpipe compliance mod)"
  echo "  benchmark  : benchmark.${BENCHMARK}"
  echo "  maps to    : SOC 2 TSC / ISO 27001 A.8 / GDPR — LIVE infra half"
  echo "  reports to : ${ARTIFACTS_DIR}/  (powerpipe --output json)"
  echo
  cyan "THE COMMANDS IT WOULD RUN (mount your creds, then this):"
  echo "  # 1. start steampipe as the SQL backend (foreground service container)"
  echo "  docker run -d --name steampipe \\"
  case "${CLOUD}" in
  aws)
    echo "    -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \\"
    echo "    -v \"\$HOME/.aws:/home/steampipe/.aws:ro\" \\"
    ;;
  gcp) echo "    -e GOOGLE_APPLICATION_CREDENTIALS=/creds.json -v \"\$GOOGLE_APPLICATION_CREDENTIALS:/creds.json:ro\" \\" ;;
  azure) echo "    -e AZURE_CLIENT_ID -e AZURE_CLIENT_SECRET -e AZURE_TENANT_ID \\" ;;
  kubernetes) echo "    -v \"\$HOME/.kube:/home/steampipe/.kube:ro\" \\" ;;
  esac
  echo "    ${STEAMPIPE_IMAGE} steampipe service start --foreground"
  echo "  docker exec steampipe steampipe plugin install ${CLOUD}"
  echo
  echo "  # 2. run the benchmark with powerpipe against that steampipe DB"
  echo "  docker run --rm --link steampipe \\"
  echo "    -e STEAMPIPE_DATABASE_HOST=steampipe \\"
  echo "    -v \"${REPO_ROOT}/${ARTIFACTS_DIR}:/out\" \\"
  echo "    ${POWERPIPE_IMAGE} sh -c \\"
  echo "      'powerpipe mod install github.com/turbot/steampipe-mod-${MOD} && \\"
  echo "       powerpipe benchmark run benchmark.${BENCHMARK} \\"
  echo "         --output json > /out/powerpipe-${BENCHMARK}.json'"
  echo
  cyan "List the benchmarks the mod ships:"
  echo "  docker run --rm ${POWERPIPE_IMAGE} sh -c \\"
  echo "    'powerpipe mod install github.com/turbot/steampipe-mod-${MOD} && powerpipe benchmark list'"
  echo
  ok "needs live cloud creds — wired and documented, nothing to fail. Exit 0."
  exit 0
fi

# ── credentialed: run for real ───────────────────────────────────────────────
step "credentials detected for ${CLOUD} — running the benchmark for real."

for img in "${STEAMPIPE_IMAGE}" "${POWERPIPE_IMAGE}"; do
  if ! docker image inspect "${img}" >/dev/null 2>&1; then
    step "pulling ${img} ..."
    if ! docker pull "${img}" >/dev/null 2>&1; then
      fail "could not pull ${img} — rerun when the image is reachable."
      exit 4
    fi
  fi
done

SP_NAME="grobase-steampipe-$$"
cleanup() { docker rm -f "${SP_NAME}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Per-cloud credential mounts for the steampipe service container.
sp_creds=()
case "${CLOUD}" in
aws)
  sp_creds+=(-e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN -e AWS_PROFILE -e AWS_DEFAULT_REGION)
  [[ -d "${HOME}/.aws" ]] && sp_creds+=(-v "${HOME}/.aws:/home/steampipe/.aws:ro")
  ;;
gcp)
  if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
    sp_creds+=(-e GOOGLE_APPLICATION_CREDENTIALS=/creds.json -v "${GOOGLE_APPLICATION_CREDENTIALS}:/creds.json:ro")
  else
    sp_creds+=(-v "${HOME}/.config/gcloud:/home/steampipe/.config/gcloud:ro")
  fi
  ;;
azure)
  sp_creds+=(-e AZURE_CLIENT_ID -e AZURE_CLIENT_SECRET -e AZURE_TENANT_ID -e AZURE_SUBSCRIPTION_ID)
  [[ -d "${HOME}/.azure" ]] && sp_creds+=(-v "${HOME}/.azure:/home/steampipe/.azure:ro")
  ;;
kubernetes)
  sp_creds+=(-v "${HOME}/.kube:/home/steampipe/.kube:ro")
  ;;
esac

step "starting steampipe service container (${SP_NAME})"
docker run -d --name "${SP_NAME}" \
  "${sp_creds[@]}" \
  "${STEAMPIPE_IMAGE}" \
  steampipe service start --foreground >/dev/null

# Give the service a moment, then install the cloud plugin.
docker exec "${SP_NAME}" sh -c "until steampipe query 'select 1' >/dev/null 2>&1; do sleep 1; done" || true
step "installing steampipe plugin: ${CLOUD}"
docker exec "${SP_NAME}" steampipe plugin install "${CLOUD}" 2>&1 | tail -5 || true

step "running powerpipe benchmark.${BENCHMARK} (mod ${MOD})"
set +e
docker run --rm --link "${SP_NAME}:steampipe" \
  -e STEAMPIPE_DATABASE_HOST=steampipe \
  -v "${REPO_ROOT}/${ARTIFACTS_DIR}:/out" \
  "${POWERPIPE_IMAGE}" \
  sh -c "powerpipe mod install github.com/turbot/steampipe-mod-${MOD} >/dev/null 2>&1 && \
         powerpipe benchmark run benchmark.${BENCHMARK} --output json \
           > /out/powerpipe-${BENCHMARK}.json" 2>&1 | tail -40
rc=${PIPESTATUS[0]}
set -e

echo
if [[ ${rc} -eq 0 ]]; then
  ok "Powerpipe benchmark.${BENCHMARK} completed. Report: ${ARTIFACTS_DIR}/powerpipe-${BENCHMARK}.json"
else
  warn "Powerpipe exited ${rc} (findings or error). Inspect ${ARTIFACTS_DIR}/powerpipe-${BENCHMARK}.json"
fi
exit ${rc}
