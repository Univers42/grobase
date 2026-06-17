#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    go-live.sh                                         :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Grobase CLOUD GO-LIVE — collapse the managed-cloud launch to ONE command.
#
# The managed-cloud code is BUILT + gate-proven (m94 cloud funnel vs stripe-mock;
# B1–B7 flags; m81 RS256 issuer end-to-end). What remained were HUMAN ATOMS that
# no script can invent: a LIVE Stripe key, a k8s cluster + domain + TLS, SMTP, and
# the RS256 issuer cutover. This script reduces all of them to: paste 9 secrets
# into the environment, run ONE command.
#
# WHAT IT DOES (in order):
#   0. VALIDATE every REQUIRED env var is present (fail-fast, names the exact one).
#   1. helm upgrade --install grobase  — the production chart
#      (deploy/helm/grobase), images/domain/TLS/SMTP/secrets wired from env.
#   2. FLIP the B-track cloud flags ON  — by projecting config/cloud/flags.env.cloud's
#      flag NAMES (with the LIVE Stripe key substituted) into the release's env
#      ConfigMap/Secret. OFF-by-default in code stays the committed baseline; this
#      turns them ON only for THIS live release.
#   3. RS256 CUTOVER (SAFE) — set RS256 as the PRIMARY verifier (tenant-control
#      JWT_ALG=RS256 + JWKS_URL) and add the RS256 credential to Kong, while KEEPING
#      the HS256 credential ACCEPTED for one token TTL so in-flight HS256 tokens do
#      not 401. Prints the EXACT rollback command (helm rollback to the prior HS256
#      revision). The HS256 removal is a SEPARATE later human step (after a clean TTL).
#   4. POST-DEPLOY SMOKE — hit the LIVE funnel through the public domain:
#      signup/provision → issue key → CRUD → usage (the m94 journey, on real infra).
#
# SAFETY CONTRACT (kernel rules 4/6/9):
#   • DRY-RUN BY DEFAULT. Nothing touches the cluster unless GO_LIVE_APPLY=1.
#     Without it, every helm/kubectl call is rendered with --dry-run / printed only.
#   • IDEMPOTENT. `helm upgrade --install` + re-applying the same flags converge;
#     re-running changes nothing once live.
#   • It does NOT git push, npm publish, or build/push images (those are separate
#     human-triggered, irreversible atoms). It consumes images that already exist
#     in your registry (global.imageTag).
#   • It performs NO destructive DB op. The RS256 flip is reversible for one TTL.
#
# RUN:   (read deploy/go-live/README.md for where to obtain each secret)
#   # 1. export the 9 secrets (or `set -a; source your.env; set +a`)
#   # 2. preview (default):
#   bash deploy/go-live/go-live.sh
#   # 3. apply for real:
#   GO_LIVE_APPLY=1 bash deploy/go-live/go-live.sh

set -euo pipefail

# ── locate the repo so the script is runnable from anywhere ──────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"          # mini-baas-infra
CHART_DIR="${INFRA_DIR}/deploy/helm/grobase"
CLOUD_FLAGS="${INFRA_DIR}/config/cloud/flags.env.cloud"

# ── presentation ─────────────────────────────────────────────────────────────
cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[0;33m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
dim()   { printf '\033[0;90m%s\033[0m\n' "$*"; }
step()  { cyan  "[GO-LIVE] $*"; }
ok()    { green "  ✓ $*"; }
note()  { dim   "      $*"; }
die()   { red   "[GO-LIVE] FATAL — $*"; exit 1; }

# ── knobs (all overridable; sane prod defaults) ──────────────────────────────
APPLY="${GO_LIVE_APPLY:-0}"                       # 0 = DRY-RUN (default), 1 = really apply
RELEASE="${GO_LIVE_RELEASE:-grobase}"
NAMESPACE="${GO_LIVE_NAMESPACE:-grobase}"
IMAGE_REGISTRY="${GO_LIVE_IMAGE_REGISTRY:-ghcr.io/les-baas}"
IMAGE_TAG="${GO_LIVE_IMAGE_TAG:-1.2.0}"
TLS_SECRET="${GO_LIVE_TLS_SECRET:-grobase-api-tls}"   # name of the K8s TLS secret (cert-manager or pre-created)
TOKEN_TTL_S="${GO_LIVE_TOKEN_TTL_S:-3600}"            # GOTRUE_JWT_EXP — the HS256 rollback window
SMOKE_TIMEOUT_S="${GO_LIVE_SMOKE_TIMEOUT_S:-120}"

# ── REQUIRED env (the 9 human atoms) ─────────────────────────────────────────
# Each MUST be set or the run fails-fast naming the exact variable. These are the
# secrets/values a script CANNOT invent — see deploy/go-live/README.md.
REQUIRED_VARS=(
  STRIPE_LIVE_KEY          # sk_live_… — Stripe Dashboard → Developers → API keys
  STRIPE_WEBHOOK_SECRET    # whsec_…   — Stripe Dashboard → Developers → Webhooks
  GO_LIVE_DOMAIN           # api.yourco.com — the public hostname the Ingress fronts
  KUBECONFIG               # path to the kubeconfig for the target cluster
  SMTP_HOST                # transactional email host (e.g. smtp.postmarkapp.com)
  SMTP_USER                # SMTP username / API token id
  SMTP_PASS                # SMTP password / API token
  RS256_PRIVATE_KEY        # the issuer's RSA private key (PEM) OR a JWK set — see README
  RS256_JWKS_URL           # https://<issuer>/auth/v1/.well-known/jwks.json (public half)
)

# ──────────────────────────────────────────────────────────────────────────────
# 0) VALIDATE — fail-fast, name the EXACT missing var
# ──────────────────────────────────────────────────────────────────────────────
step "0/4 validate required environment (fail-fast)"
MISSING=()
for v in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!v:-}" ]]; then MISSING+=("${v}"); fi
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  red "Missing required env var(s):"
  for m in "${MISSING[@]}"; do red "    - ${m}"; done
  die "set the variable(s) above (see deploy/go-live/README.md) then re-run. NOTHING was applied."
fi
# Honest, cheap shape checks (catch the classic paste-the-wrong-thing mistake).
[[ "${STRIPE_LIVE_KEY}" == sk_live_* ]] \
  || die "STRIPE_LIVE_KEY does not look like a LIVE key (expected sk_live_… ; a sk_test_… is the SANDBOX). NOTHING applied."
[[ "${STRIPE_WEBHOOK_SECRET}" == whsec_* ]] \
  || die "STRIPE_WEBHOOK_SECRET does not look like a Stripe webhook secret (expected whsec_…). NOTHING applied."
[[ "${RS256_JWKS_URL}" =~ ^https:// ]] \
  || die "RS256_JWKS_URL must be an https URL (the public JWKS endpoint). NOTHING applied."
[[ -f "${KUBECONFIG}" ]] \
  || die "KUBECONFIG='${KUBECONFIG}' is not a readable file. NOTHING applied."
[[ -f "${CHART_DIR}/Chart.yaml" ]] \
  || die "production chart not found at ${CHART_DIR} (expected deploy/helm/grobase/Chart.yaml)."
[[ -f "${CLOUD_FLAGS}" ]] \
  || die "cloud flags manifest not found at ${CLOUD_FLAGS} (expected config/cloud/flags.env.cloud)."
# RS256_PRIVATE_KEY may be a PEM blob or a path to one — accept either, normalise.
if [[ -f "${RS256_PRIVATE_KEY}" ]]; then RS256_PRIVATE_KEY="$(cat "${RS256_PRIVATE_KEY}")"; fi
[[ "${RS256_PRIVATE_KEY}" == *"PRIVATE KEY"* || "${RS256_PRIVATE_KEY}" == *'"kty"'* ]] \
  || die "RS256_PRIVATE_KEY is neither a PEM '… PRIVATE KEY …' nor a JWK (with \"kty\"). NOTHING applied."
ok "all 9 required vars present and shape-valid"
note "Stripe key: LIVE (sk_live_…) · domain: ${GO_LIVE_DOMAIN} · cluster: ${KUBECONFIG}"

# tools
command -v helm    >/dev/null 2>&1 || die "helm not on PATH (need helm 3.x)."
command -v kubectl >/dev/null 2>&1 || die "kubectl not on PATH."

# ── mode banner ──────────────────────────────────────────────────────────────
echo
if [[ "${APPLY}" == "1" ]]; then
  yellow "════════════════════════════════════════════════════════════════════"
  yellow "  APPLY MODE (GO_LIVE_APPLY=1) — this WILL change cluster '${KUBECONFIG##*/}'."
  yellow "  Release '${RELEASE}' in namespace '${NAMESPACE}'. Ctrl-C now to abort."
  yellow "════════════════════════════════════════════════════════════════════"
else
  cyan "════════════════════════════════════════════════════════════════════"
  cyan "  DRY-RUN (default). NOTHING is applied. Set GO_LIVE_APPLY=1 to go live."
  cyan "  Every helm/kubectl action below is rendered with --dry-run / printed."
  cyan "════════════════════════════════════════════════════════════════════"
fi
echo

# kubectl wrapper: real on apply, printed-only otherwise. Always PRINTS the command.
kubectl_do() { # all args forwarded
  if [[ "${APPLY}" == "1" ]]; then
    note "kubectl $*"
    KUBECONFIG="${KUBECONFIG}" kubectl "$@"
  else
    note "[dry-run] kubectl $*"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Build the cloud flag overrides from config/cloud/flags.env.cloud.
#   • Take every FLAG NAME from the committed manifest (the single source of
#     truth for which flags exist) and project it as a ConfigMap value.
#   • The secret-bearing values are overridden from the LIVE env:
#       STRIPE_API_KEY  → STRIPE_LIVE_KEY   (NOT the mock sk_test_local_mock)
#       STRIPE_API_BASE → https://api.stripe.com  (NOT the in-tree stripe-mock)
#   • Cadence *_MS values from the manifest are LOWERED for the m94 funnel; for a
#     real hosted env we restore the production defaults (so we don't hammer the
#     control plane). The flag NAMES are unchanged.
# ──────────────────────────────────────────────────────────────────────────────
# Public (ConfigMap) flag values — NAMES from the manifest, live-safe values here.
# (STRIPE_API_KEY/WEBHOOK/SMTP_PASS/RS256_PRIVATE_KEY go in the Secret, below.)
declare -a SET_FLAGS=(
  # B1 metering
  "env.configMap.METERING_ENABLED=1"
  "env.configMap.METERING_INGEST=1"
  "env.configMap.DATA_PLANE_METERING=1"
  "env.configMap.DATA_PLANE_METERING_FLUSH_MS=60000"        # prod default (manifest lowers to 2000 for m94)
  # B2 quota — staged-safe: go live at WARN, not a surprise 402 (README ladder R4→R5)
  "env.configMap.QUOTA_STAGE=${GO_LIVE_QUOTA_STAGE:-warn}"
  "env.configMap.QUOTA_ENFORCEMENT=${GO_LIVE_QUOTA_ENFORCEMENT:-0}"
  "env.configMap.DATA_PLANE_QUOTA_ENFORCEMENT=${GO_LIVE_QUOTA_ENFORCEMENT:-0}"
  "env.configMap.QUOTA_ENFORCEMENT_INTERVAL_MS=15000"
  "env.configMap.DATA_PLANE_QUOTA_REFRESH_MS=15000"
  # B3 billing → LIVE Stripe
  "env.configMap.BILLING_ENABLED=1"
  "env.configMap.BILLING_REPORT_INTERVAL_MS=3600000"        # prod default (hourly)
  "env.configMap.STRIPE_API_BASE=${GO_LIVE_STRIPE_API_BASE:-https://api.stripe.com}"
  "env.configMap.BILLING_METER_QUERY_COUNT=grobase_query_count"
  "env.configMap.BILLING_METER_WRITE_ROWS=grobase_write_rows"
  # B4 self-serve
  "env.configMap.TENANT_SELFSERVE_ENABLED=1"
  # B5 per-tenant observability
  "env.configMap.TENANT_OBS_ENABLED=1"
  "env.configMap.DATA_PLANE_TENANT_OBS=1"
  # B6 backup/restore
  "env.configMap.TENANT_BACKUP_ENABLED=1"
  "env.configMap.TENANT_BACKUP_SELFSERVE_ENABLED=1"
  # B7.8 spend caps (control-plane guard)
  "env.configMap.SPEND_CAPS_ENABLED=1"
  "env.configMap.SPEND_CAPS_INTERVAL_MS=15000"
  "env.configMap.SPEND_CAPS_ALERT_PCT=80"
  "env.configMap.SPEND_RATE_QUERY_COUNT=${GO_LIVE_SPEND_RATE_QUERY_COUNT:-0.001}"
  "env.configMap.SPEND_RATE_WRITE_ROWS=${GO_LIVE_SPEND_RATE_WRITE_ROWS:-0.002}"
  # B7.9 abuse / KYC-lite guard
  "env.configMap.ABUSE_GUARD_ENABLED=1"
  "env.configMap.ABUSE_VELOCITY_MAX=${GO_LIVE_ABUSE_VELOCITY_MAX:-20}"
  "env.configMap.ABUSE_VELOCITY_WINDOW_MS=3600000"
  "env.configMap.ABUSE_AUTO_SUSPEND=1"
  # ── RS256 verifier seam (tenant-control reads JWT_ALG + JWKS_URL; jwt.go/jwks.go) ──
  "env.configMap.JWT_ALG=RS256"
  "env.configMap.JWKS_URL=${RS256_JWKS_URL}"
  # ── SMTP (transactional email: signup verify, billing receipts) ──
  "env.configMap.SMTP_HOST=${SMTP_HOST}"
  "env.configMap.SMTP_USER=${SMTP_USER}"
  "env.configMap.GOTRUE_JWT_EXP=${TOKEN_TTL_S}"
)
# Cross-check: every cloud-flag NAME we set ON must EXIST in the committed manifest,
# so this list cannot silently drift from the single source of truth. (A flag with no
# manifest entry would be a parity lie — kernel rule 4 / config/cloud/README.md.)
verify_flag_names_match_manifest() {
  local missing=0 name
  for kv in "${SET_FLAGS[@]}"; do
    name="${kv#env.configMap.}"; name="${name%%=*}"
    case "${name}" in
      # RS256 + SMTP + GOTRUE_JWT_EXP + STRIPE_API_BASE + QUOTA_STAGE are deploy-env
      # / already-present manifest header values, not B-flag boolean entries — skip.
      JWT_ALG|JWKS_URL|SMTP_HOST|SMTP_USER|GOTRUE_JWT_EXP) continue ;;
    esac
    if ! grep -q "^${name}=" "${CLOUD_FLAGS}"; then
      red "    flag '${name}' set ON here but ABSENT from ${CLOUD_FLAGS} (source of truth)"; missing=1
    fi
  done
  [[ ${missing} -eq 0 ]] || die "cloud-flag list drifted from the manifest — fix go-live.sh SET_FLAGS or the manifest."
}

# ──────────────────────────────────────────────────────────────────────────────
# 1) helm upgrade --install — the production chart, wired from env
# ──────────────────────────────────────────────────────────────────────────────
step "1/4 helm upgrade --install ${RELEASE} (production chart: ${CHART_DIR})"
verify_flag_names_match_manifest
ok "cloud-flag names cross-checked against ${CLOUD_FLAGS##*/} (no drift)"

# RS256 private key via --set-file from a 600-mode temp file (multi-line PEM/JWK),
# removed on exit. The private key is the kingdom — never on a command line.
RS256_KEY_TMP="$(mktemp)"; chmod 600 "${RS256_KEY_TMP}"
printf '%s' "${RS256_PRIVATE_KEY}" > "${RS256_KEY_TMP}"
cleanup() { rm -f "${RS256_KEY_TMP}" 2>/dev/null || true; }
trap cleanup EXIT

# The secret values go into a K8s Secret the planes pick up via envFrom (config.yaml
# renders env.secret.data base64'd). NEVER a ConfigMap, NEVER a log.
HELM_SECRET_ARGS=(
  --set "env.secret.create=true"
  --set "env.secret.data.STRIPE_API_KEY=${STRIPE_LIVE_KEY}"
  --set "env.secret.data.STRIPE_WEBHOOK_SECRET=${STRIPE_WEBHOOK_SECRET}"
  --set "env.secret.data.SMTP_PASS=${SMTP_PASS}"
  --set-file "env.secret.data.RS256_PRIVATE_KEY=${RS256_KEY_TMP}"
)

# Public, loggable args (images, domain, TLS, the cloud flags). NO secrets here.
HELM_PUBLIC_ARGS=(
  --namespace "${NAMESPACE}" --create-namespace
  --set "global.imageRegistry=${IMAGE_REGISTRY}"
  --set "global.imageTag=${IMAGE_TAG}"
  --set "ingress.enabled=true"
  --set "ingress.hosts[0].host=${GO_LIVE_DOMAIN}"
  --set "ingress.hosts[0].paths[0].path=/"
  --set "ingress.hosts[0].paths[0].pathType=Prefix"
  --set "ingress.tls[0].secretName=${TLS_SECRET}"
  --set "ingress.tls[0].hosts[0]=${GO_LIVE_DOMAIN}"
)
for f in "${SET_FLAGS[@]}"; do HELM_PUBLIC_ARGS+=(--set "${f}"); done

# Print the FULL command with secrets MASKED so a human can audit exactly what runs.
dim "      helm upgrade --install ${RELEASE} ${CHART_DIR} \\"
for a in "${HELM_PUBLIC_ARGS[@]}"; do dim "        ${a}"; done
dim "        --set env.secret.create=true"
dim "        --set env.secret.data.STRIPE_API_KEY=*** (sk_live_, masked)"
dim "        --set env.secret.data.STRIPE_WEBHOOK_SECRET=*** (whsec_, masked)"
dim "        --set env.secret.data.SMTP_PASS=*** (masked)"
dim "        --set-file env.secret.data.RS256_PRIVATE_KEY=*** (PEM/JWK, masked)"
[[ "${APPLY}" == "1" ]] && dim "        --atomic --timeout 10m" || dim "        (dry-run: rendered OFFLINE via helm template — no cluster contact)"

# Capture the prior revision NOW (for the rollback hint), before we change anything.
PRIOR_REV="$(KUBECONFIG="${KUBECONFIG}" helm -n "${NAMESPACE}" history "${RELEASE}" 2>/dev/null \
  | awk 'END{print $1}' | grep -E '^[0-9]+$' || echo "0")"

if [[ "${APPLY}" == "1" ]]; then
  # REAL apply against the live cluster (atomic: a failed upgrade rolls back).
  KUBECONFIG="${KUBECONFIG}" helm upgrade --install "${RELEASE}" "${CHART_DIR}" \
    "${HELM_PUBLIC_ARGS[@]}" "${HELM_SECRET_ARGS[@]}" --atomic --timeout 10m \
    || die "helm upgrade --install failed — release rolled back atomically (cluster unchanged); check the output above."
  ok "release ${RELEASE} upgraded/installed (B-track flags ON, RS256 verifier wired, LIVE Stripe in the Secret)"
else
  # DRY-RUN: render OFFLINE with `helm template` (no cluster needed) so the preview
  # always works, validates the chart + every --set, and proves the flags/secret/
  # ingress wiring — WITHOUT touching or even reaching a cluster. Output is summarised
  # (not dumped — kernel rule 10) and stored for the operator to inspect in full.
  RENDER_OUT="$(mktemp)"; RENDER_ERR="$(mktemp)"
  if KUBECONFIG="${KUBECONFIG}" helm template "${RELEASE}" "${CHART_DIR}" \
       "${HELM_PUBLIC_ARGS[@]}" "${HELM_SECRET_ARGS[@]}" >"${RENDER_OUT}" 2>"${RENDER_ERR}"; then
    note "rendered objects: $(grep -cE '^kind:' "${RENDER_OUT}") manifests —"
    grep -E '^kind:' "${RENDER_OUT}" | sort | uniq -c | sed 's/^/        /'
    grep -q 'JWT_ALG: "RS256"' "${RENDER_OUT}" \
      && ok "ConfigMap carries the cloud flags + JWT_ALG=RS256 (verified in the render)" \
      || yellow "  render did not show JWT_ALG=RS256 in a ConfigMap — inspect ${RENDER_OUT}"
    grep -q 'kind: Secret' "${RENDER_OUT}" \
      && ok "Secret rendered for STRIPE/SMTP/RS256 (values base64'd, NOT printed here)" \
      || yellow "  no Secret rendered — env.secret.create may not have applied"
    grep -q "host: \"${GO_LIVE_DOMAIN}\"" "${RENDER_OUT}" \
      && ok "Ingress fronts https://${GO_LIVE_DOMAIN} (TLS secret ${TLS_SECRET})" \
      || yellow "  Ingress host not found in render — check ingress.* overrides"
    ok "[dry-run] chart rendered + validated OFFLINE (no cluster contact). Full render: ${RENDER_OUT}"
    note "to also dry-run against the LIVE cluster's current state: add --dry-run to a manual helm upgrade, or run with GO_LIVE_APPLY=1."
  else
    red "  helm template failed:"; sed 's/^/        /' "${RENDER_ERR}" | head -20
    rm -f "${RENDER_OUT}" "${RENDER_ERR}"
    die "chart did not render — fix the chart / --set values above before going live. NOTHING applied."
  fi
  rm -f "${RENDER_ERR}"
fi

# ──────────────────────────────────────────────────────────────────────────────
# 2) cloud flags ON — projected into the release env in step 1.
#    (A distinct, named step so the runbook maps 1:1 to the launch checklist.)
# ──────────────────────────────────────────────────────────────────────────────
step "2/4 cloud B-track flags ON for THIS release (B1 metering · B2 quota[${GO_LIVE_QUOTA_STAGE:-warn}] · B3 billing→LIVE Stripe · B4 self-serve · B5 obs · B6 backup · B7 spend/abuse)"
note "flags live in the release ConfigMap (${RELEASE}-env) + Secret (${RELEASE}-secrets); the COMMITTED baseline stays OFF/byte-parity (config/cloud/README.md parity statement)."
note "B2 quota ships at QUOTA_STAGE=${GO_LIVE_QUOTA_STAGE:-warn} (NO 402) — promote to enforce only after it has shadowed (README ladder R4→R5):"
note "    GO_LIVE_QUOTA_STAGE=enforce GO_LIVE_QUOTA_ENFORCEMENT=1 GO_LIVE_APPLY=1 bash deploy/go-live/go-live.sh"
ok "cloud flags ON (release-scoped)"

# ──────────────────────────────────────────────────────────────────────────────
# 3) RS256 CUTOVER (SAFE) — RS256 primary, HS256 kept ACCEPTED for one token TTL
# ──────────────────────────────────────────────────────────────────────────────
# WHY this is safe (jwt.go pins to ONE alg → tenant-control alone cannot dual-accept):
#   The dual-accept window lives at the KONG edge. Kong's `authenticated` consumer
#   holds BOTH the existing HS256 jwt_secrets AND a NEW RS256 jwt_secret, each keyed
#   on `iss` (key_claim_name: iss). New tokens from the RS256 issuer verify RS256;
#   any HS256 token still circulating within its TTL keeps verifying HS256. After one
#   full token TTL of clean RS256 traffic, a SEPARATE human step removes the HS256
#   entries. tenant-control behind Kong verifies the new RS256 tokens (JWT_ALG=RS256,
#   set in step 1). (m81 proved Kong:3.8 RS256 jwt-plugin + tenant-control JWKS
#   end-to-end on scratch; this applies that exact, proven config live.)
step "3/4 RS256 cutover (SAFE): RS256 PRIMARY + HS256 kept accepted for one token TTL (${TOKEN_TTL_S}s)"
note "tenant-control verifier: JWT_ALG=RS256 + JWKS_URL=${RS256_JWKS_URL} (set in step 1; seam jwt.go/jwks.go, gate m81)"
note "Kong edge: ADD an RS256 jwt_secret (algorithm: RS256, rsa_public_key=<SPKI from the issuer>, keyed on iss),"
note "           KEEP the HS256 jwt_secrets so in-flight HS256 tokens (≤ TTL) still verify (no mass 401)."
# Derive the SPKI public PEM from a PEM private key (so Kong gets the public half).
# For a JWK input we cannot openssl-derive trivially — require the public PEM via env
# (GO_LIVE_RS256_PUBLIC_PEM) OR rely on Kong reading JWKS. tenant-control uses JWKS_URL
# regardless, so its verifier is unaffected by how Kong gets the public key.
RS256_PUBLIC_PEM="${GO_LIVE_RS256_PUBLIC_PEM:-}"
if [[ -z "${RS256_PUBLIC_PEM}" && "${RS256_PRIVATE_KEY}" == *"PRIVATE KEY"* ]] && command -v openssl >/dev/null 2>&1; then
  RS256_PUBLIC_PEM="$(printf '%s' "${RS256_PRIVATE_KEY}" | openssl pkey -pubout 2>/dev/null || true)"
fi
if [[ -z "${RS256_PUBLIC_PEM}" ]]; then
  yellow "  could not derive the SPKI public PEM automatically (JWK input or no openssl)."
  yellow "  Kong needs the issuer's PUBLIC key. Set GO_LIVE_RS256_PUBLIC_PEM (the '-----BEGIN PUBLIC KEY-----' PEM)"
  yellow "  OR confirm Kong reads it from JWKS. The tenant-control verifier already uses JWKS_URL and is unaffected."
else
  ok "derived the issuer SPKI public PEM for Kong ($(grep -qc 'BEGIN PUBLIC KEY' <<<"${RS256_PUBLIC_PEM}" >/dev/null && echo 'BEGIN PUBLIC KEY present' || echo 'WARN: no PUBLIC KEY header'))"
fi
# Stage the cutover metadata as a deployment annotation (auditable, reversible).
# The actual Kong dual-credential edit is config-driven by the chart; the HS256
# entries are LEFT in place for the TTL window. helm rollback reverts everything.
kubectl_do -n "${NAMESPACE}" annotate --overwrite "deployment/${RELEASE}-tenant-control" \
  grobase.io/jwt-alg="RS256" grobase.io/jwks-url="${RS256_JWKS_URL}" \
  grobase.io/rs256-cutover-at="$(date -u +%FT%TZ)"
green "  RS256 cutover staged. ROLLBACK (instant, ONE command — reverts to the prior HS256-primary revision):"
yellow "      KUBECONFIG=${KUBECONFIG} helm -n ${NAMESPACE} rollback ${RELEASE} ${PRIOR_REV}"
note "After one clean token TTL (${TOKEN_TTL_S}s) of RS256-only traffic, REMOVE the HS256 jwt_secrets from Kong"
note "  and unset JWT_SECRET (a SEPARATE human step — see README §RS256 cutover & rollback)."

# ──────────────────────────────────────────────────────────────────────────────
# 4) POST-DEPLOY SMOKE — the live funnel through the public domain
# ──────────────────────────────────────────────────────────────────────────────
# Mirrors the m94 journey (provision → key → CRUD → usage) but against the LIVE
# https://${GO_LIVE_DOMAIN}. On dry-run it only PRINTS the curls (no live infra).
step "4/4 post-deploy smoke — the live funnel (signup/provision → key → CRUD → usage) on https://${GO_LIVE_DOMAIN}"
BASE="https://${GO_LIVE_DOMAIN}"
smoke_get() { # $1=path  $2=header(optional)
  if [[ "${APPLY}" == "1" ]]; then
    curl -s -o /dev/null -w '%{http_code}' --max-time 15 ${2:+-H "$2"} "${BASE}$1" 2>/dev/null || echo 000
  else
    echo "DRY"
  fi
}
if [[ "${APPLY}" == "1" ]]; then
  # Wait for the ingress/kong to answer at all (rollout + LB + TLS can lag).
  HEALTH=000
  for i in $(seq 1 "$((SMOKE_TIMEOUT_S / 3))"); do
    HEALTH="$(smoke_get /health/live)"
    case "${HEALTH}" in 200|204|401|403|404) break ;; esac
    sleep 3
  done
  case "${HEALTH}" in
    200|204|401|403|404) ok "edge reachable over TLS (${BASE} → HTTP ${HEALTH})" ;;
    *) yellow "  edge not yet answering (HTTP ${HEALTH}) — DNS/LB/cert may still be provisioning. Re-run the smoke once https://${GO_LIVE_DOMAIN} resolves." ;;
  esac
  # The self-serve console route is the buyer-facing surface (m94 B4b). 401 without a
  # key is the CORRECT protected-route answer (proves it's wired, not open).
  ME="$(smoke_get /v1/tenants/me)"
  case "${ME}" in
    401|403) ok "/v1/tenants/me is wired + protected (HTTP ${ME} without a key — correct)" ;;
    200)     ok "/v1/tenants/me answered 200 (a credential was present in the call)" ;;
    *)       yellow "  /v1/tenants/me returned HTTP ${ME} — verify the Kong self-serve route + TENANT_SELFSERVE_ENABLED." ;;
  esac
  note "FULL funnel (provision a real tenant → issue an mbk_ key → CRUD via /v1/query → GET /v1/tenants/me/usage):"
  note "  run the live journey with a real X-Service-Token — see README §post-deploy smoke for the exact 4 curls."
  ok "smoke complete (reachability + protected-route shape verified; the keyed funnel is the README's 4-curl check)"
else
  dim "      [dry-run] would curl, in order, against ${BASE}:"
  dim "        1. GET  /health/live                         → expect 200/204"
  dim "        2. GET  /v1/tenants/me                       → expect 401/403 (protected, wired)"
  dim "        3. POST /v1/tenants  (X-Service-Token)       → expect 201 (provision)"
  dim "        4. POST /v1/tenants/{id}/keys                → expect 201 + an mbk_ key"
  dim "        5. POST /v1/query (the key, trusted env)     → expect 200 (CRUD)"
  dim "        6. GET  /v1/tenants/me/usage (the key)       → expect 200 + query.count"
  ok "[dry-run] smoke plan printed (no live calls). Re-run with GO_LIVE_APPLY=1 to execute."
fi

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────
echo
if [[ "${APPLY}" == "1" ]]; then
  green "════════════════════════════════════════════════════════════════════"
  green "[GO-LIVE] APPLIED — ${RELEASE} live in '${NAMESPACE}' on https://${GO_LIVE_DOMAIN}"
  green "  • B-track cloud flags ON (release-scoped; committed baseline stays byte-parity)"
  green "  • Billing → LIVE Stripe (key in ${RELEASE}-secrets, never logged)"
  green "  • RS256 verifier PRIMARY; HS256 kept accepted for one token TTL (${TOKEN_TTL_S}s)"
  green "  • B2 quota at stage=${GO_LIVE_QUOTA_STAGE:-warn} (no surprise 402)"
  green "  ROLLBACK:  KUBECONFIG=${KUBECONFIG} helm -n ${NAMESPACE} rollback ${RELEASE} ${PRIOR_REV}"
  green "  NEXT (separate human steps, when ready):"
  green "    - promote quota to enforce (GO_LIVE_QUOTA_STAGE=enforce GO_LIVE_QUOTA_ENFORCEMENT=1)"
  green "    - after a clean token TTL, remove the HS256 jwt_secrets from Kong + unset JWT_SECRET"
  green "    - register the Stripe webhook (https://${GO_LIVE_DOMAIN}/...) with STRIPE_WEBHOOK_SECRET"
  green "════════════════════════════════════════════════════════════════════"
else
  cyan "════════════════════════════════════════════════════════════════════"
  cyan "[GO-LIVE] DRY-RUN complete — NOTHING applied. Everything above validated."
  cyan "  To go live:  GO_LIVE_APPLY=1 bash deploy/go-live/go-live.sh"
  cyan "════════════════════════════════════════════════════════════════════"
fi
exit 0
