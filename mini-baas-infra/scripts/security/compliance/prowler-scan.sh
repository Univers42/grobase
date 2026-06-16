#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    prowler-scan.sh                                    :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Cloud compliance-as-code with Prowler — wired now, RUNS when a cloud exists.
#
# Prowler audits a LIVE cloud/k8s account (AWS / GCP / Azure / Kubernetes)
# against its built-in SOC 2 / ISO 27001 / GDPR / CIS frameworks. That is the
# real "infra compliance" half — but it needs real cloud credentials, which we
# do NOT have locally.
#
#   THEREFORE: with no credentials, this script PRINTS exactly what it WOULD
#   audit (the cloud, the framework, the full docker command) and EXITS 0 with a
#   clear "needs live cloud creds" message. It does NOT fail. When credentials
#   are present it runs Prowler for real and writes the report.
#
# This is the cloud-account counterpart to infra-compliance-scan.sh, which is the
# locally-runnable IaC proxy. See wiki/compliance/infra-compliance-scanning.md.
#
# Docker-first: runs the official Prowler image. Host needs only `docker`.
#
# Usage:
#   bash apps/baas/mini-baas-infra/scripts/security/compliance/prowler-scan.sh
#   CLOUD=aws   FRAMEWORK=soc2_aws        bash .../prowler-scan.sh
#   CLOUD=aws   FRAMEWORK=iso27001_2013_aws bash .../prowler-scan.sh
#   CLOUD=aws   FRAMEWORK=gdpr_aws        bash .../prowler-scan.sh
#   CLOUD=aws   FRAMEWORK=cis_3.0_aws     bash .../prowler-scan.sh
#   CLOUD=gcp   FRAMEWORK=cis_2.0_gcp     bash .../prowler-scan.sh
#   CLOUD=azure FRAMEWORK=cis_2.0_azure   bash .../prowler-scan.sh
#   CLOUD=kubernetes                       bash .../prowler-scan.sh
#
# Environment knobs:
#   CLOUD        aws|gcp|azure|kubernetes   (default: aws)
#   FRAMEWORK    Prowler --compliance value (default: soc2_aws)
#                AWS: soc2_aws · iso27001_2013_aws · gdpr_aws · cis_3.0_aws · hipaa_aws
#                GCP/Azure/K8s: see `prowler <cloud> --list-compliance`
#   PROWLER_IMAGE     default: toniblyx/prowler:latest
#   COMPLIANCE_ARTIFACTS_DIR  default: artifacts/security-audit/compliance
#   AWS_* / GOOGLE_APPLICATION_CREDENTIALS / AZURE_*  — presence triggers a real run
#
# Exit code: 0 when there are no credentials (informational); when creds exist,
# Prowler's own exit code is surfaced.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
ARTIFACTS_DIR="${COMPLIANCE_ARTIFACTS_DIR:-${BAAS_DIR}/artifacts/security-audit/compliance}"
mkdir -p "${ARTIFACTS_DIR}"

CLOUD="${CLOUD:-aws}"
FRAMEWORK="${FRAMEWORK:-soc2_aws}"
PROWLER_IMAGE="${PROWLER_IMAGE:-toniblyx/prowler:latest}"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
amber() { printf '\033[0;33m%s\033[0m\n' "$*"; }
step()  { cyan  "[prowler] ${*}"; }
fail()  { red   "[prowler] FAIL: $*"; }
warn()  { amber "[prowler] WARN: $*"; }
ok()    { green "[prowler] OK:   $*"; }

for arg in "$@"; do
  case "${arg}" in
    --help|-h)
      sed -n '/^# Usage:/,/^# Exit code:/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
  esac
done

# ── credential detection per cloud ───────────────────────────────────────────
# We only consider a run "credentialed" if the provider's standard auth is
# present in the environment / well-known files. Anything short of that → guard.
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
    *)
      return 1
      ;;
  esac
}

# Assemble the prowler invocation (used both for the dry-run print and the run).
prowler_cmd=(prowler "${CLOUD}")
if [[ "${CLOUD}" != "kubernetes" && -n "${FRAMEWORK}" ]]; then
  prowler_cmd+=(--compliance "${FRAMEWORK}")
fi
prowler_cmd+=(--output-formats json-ocsf html csv --output-directory /out)

step "Cloud compliance scan — Prowler (${PROWLER_IMAGE})"
step "Target cloud   : ${CLOUD}"
step "Framework      : ${FRAMEWORK}"

if ! have_creds; then
  echo
  amber "════════════════════════════════════════════════════════════════════════"
  amber " NO ${CLOUD^^} CREDENTIALS DETECTED — this is the EXPECTED local state."
  amber "════════════════════════════════════════════════════════════════════════"
  echo
  cyan  "Prowler audits a LIVE ${CLOUD} account against its built-in compliance"
  cyan  "frameworks. With no credentials it cannot — and we do NOT pretend a local"
  cyan  "run audits 'SOC 2'. When you have a real ${CLOUD} account, export creds and"
  cyan  "re-run this exact script; it will then produce a genuine framework report."
  echo
  cyan  "WHAT IT WOULD AUDIT:"
  echo  "  cloud      : ${CLOUD}  (its full account: IAM, storage, network, logging, KMS, ...)"
  echo  "  framework  : ${FRAMEWORK}"
  echo  "  maps to    : SOC 2 TSC (CC6 access · CC7 ops) / ISO 27001 A.8 / GDPR — LIVE infra half"
  echo  "  reports to : ${ARTIFACTS_DIR}/  (json-ocsf + html + csv)"
  echo
  cyan  "THE COMMAND IT WOULD RUN (mount your creds, then this):"
  case "${CLOUD}" in
    aws)
      echo "  docker run --rm \\"
      echo "    -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \\"
      echo "    -v \"\$HOME/.aws:/home/prowler/.aws:ro\" \\"
      echo "    -v \"${REPO_ROOT}/${ARTIFACTS_DIR}:/out\" \\"
      echo "    ${PROWLER_IMAGE} \\"
      echo "    ${prowler_cmd[*]}"
      ;;
    gcp)
      echo "  docker run --rm \\"
      echo "    -e GOOGLE_APPLICATION_CREDENTIALS=/creds.json \\"
      echo "    -v \"\$GOOGLE_APPLICATION_CREDENTIALS:/creds.json:ro\" \\"
      echo "    -v \"${REPO_ROOT}/${ARTIFACTS_DIR}:/out\" \\"
      echo "    ${PROWLER_IMAGE} \\"
      echo "    ${prowler_cmd[*]}"
      ;;
    azure)
      echo "  docker run --rm \\"
      echo "    -e AZURE_CLIENT_ID -e AZURE_CLIENT_SECRET -e AZURE_TENANT_ID \\"
      echo "    -v \"${REPO_ROOT}/${ARTIFACTS_DIR}:/out\" \\"
      echo "    ${PROWLER_IMAGE} \\"
      echo "    ${prowler_cmd[*]}"
      ;;
    kubernetes)
      echo "  docker run --rm \\"
      echo "    -v \"\$HOME/.kube:/home/prowler/.kube:ro\" \\"
      echo "    -v \"${REPO_ROOT}/${ARTIFACTS_DIR}:/out\" \\"
      echo "    ${PROWLER_IMAGE} \\"
      echo "    ${prowler_cmd[*]}"
      ;;
  esac
  echo
  cyan  "List the frameworks Prowler ships for this cloud:"
  echo  "  docker run --rm ${PROWLER_IMAGE} prowler ${CLOUD} --list-compliance"
  echo
  ok    "needs live cloud creds — wired and documented, nothing to fail. Exit 0."
  exit 0
fi

# ── credentialed: run for real ───────────────────────────────────────────────
step "credentials detected for ${CLOUD} — running Prowler for real."

# Pre-pull so a registry failure is reported clearly.
if ! docker image inspect "${PROWLER_IMAGE}" >/dev/null 2>&1; then
  step "pulling ${PROWLER_IMAGE} ..."
  if ! docker pull "${PROWLER_IMAGE}" >/dev/null 2>&1; then
    fail "could not pull ${PROWLER_IMAGE} — rerun when the image is reachable."
    exit 4
  fi
fi

# Per-cloud credential mounts.
docker_creds=()
case "${CLOUD}" in
  aws)
    docker_creds+=(-e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN -e AWS_PROFILE -e AWS_DEFAULT_REGION)
    [[ -d "${HOME}/.aws" ]] && docker_creds+=(-v "${HOME}/.aws:/home/prowler/.aws:ro")
    ;;
  gcp)
    if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
      docker_creds+=(-e GOOGLE_APPLICATION_CREDENTIALS=/creds.json -v "${GOOGLE_APPLICATION_CREDENTIALS}:/creds.json:ro")
    else
      docker_creds+=(-v "${HOME}/.config/gcloud:/home/prowler/.config/gcloud:ro")
    fi
    ;;
  azure)
    docker_creds+=(-e AZURE_CLIENT_ID -e AZURE_CLIENT_SECRET -e AZURE_TENANT_ID -e AZURE_SUBSCRIPTION_ID)
    [[ -d "${HOME}/.azure" ]] && docker_creds+=(-v "${HOME}/.azure:/home/prowler/.azure:ro")
    ;;
  kubernetes)
    docker_creds+=(-v "${HOME}/.kube:/home/prowler/.kube:ro")
    ;;
esac

set +e
docker run --rm \
  "${docker_creds[@]}" \
  -v "${REPO_ROOT}/${ARTIFACTS_DIR}:/out" \
  "${PROWLER_IMAGE}" \
  "${prowler_cmd[@]}" 2>&1 | tail -60
rc=${PIPESTATUS[0]}
set -e

echo
if [[ ${rc} -eq 0 ]]; then
  ok "Prowler completed clean for ${CLOUD}/${FRAMEWORK}. Reports in ${ARTIFACTS_DIR}/"
else
  warn "Prowler exited ${rc} for ${CLOUD}/${FRAMEWORK} (findings or error). Inspect ${ARTIFACTS_DIR}/"
fi
exit ${rc}
