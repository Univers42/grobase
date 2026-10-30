#!/usr/bin/env bash
# m262-minio-https.sh — MinIO serves HTTPS only under one opt-in overlay (G5, ADR 0030, MH1–MH16).
#
# Static (no stack): make composes docker-compose.engine-tls-minio.yml only when
# ENGINE_TLS_ENGINES lists minio, its cloud companion only with CLOUD=1 too, never in prod or
# on the monolith (MH1, MH10, MH15); the overlay and cloud renders hold zero plaintext MinIO
# endpoints (MH7) and change nothing but the scheme in mc-init and trino's catalog; clients
# mount ca.pem only (MH6); trust is additive (MH5); DATA_PLANE_TLS_INSECURE is untouched
# (MH14); kong.yml renders byte-identical without KONG_MINIO_CA_FILE and refuses a key or a
# missing url with it (MH1, MH8); the host scripts read the overlay's CA (MH11).
# Live (M262_LIVE=1, docker): scripts/lib/lib-m262-minio-live.sh and lib-m262-minio-probes.sh,
# throwaway boots under compose project m262 (M262_PROJECT), every container renamed.
#
# Caveat: static checks read renders and the Makefile, not a running stack; the clients the
# live legs boot are the shipped :latest images (M262_IMAGE builds minio from this commit), so
# a client image change in the same commit is not exercised until it is published.
# Needs the .env and localhost cert compose interpolates (scripts/env/assemble-env.sh,
# scripts/certs/generate-localhost-cert.sh). Env: M262_LIVE · M262_PROJECT · M262_IMAGE.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OVERLAY="orchestrators/compose/docker-compose.engine-tls-minio.yml"
CLOUD_TLS="orchestrators/compose/docker-compose.cloud-minio-tls.yml"
CLOUD_BASE="orchestrators/compose/docker-compose.cloud.yml"
PROBES="${ROOT}/scripts/verify/m262-minio-https"
PROJECT="${M262_PROJECT:-m262}"
WORK=""

step() { printf '\033[0;36m[M262] %s\033[0m\n' "$*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M262] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

# render OUT FILE... — every profile's config as JSON, with the cert dir under WORK.
render() {
  local out="$1" f
  local -a files=(-f "${ROOT}/docker-compose.yml")
  shift
  for f in "$@"; do files+=(-f "${ROOT}/${f}"); done
  ENGINE_TLS_MINIO_CERT_DIR="${WORK}/minio" docker compose --project-directory "${ROOT}" "${files[@]}" \
    --profile '*' config --format json >"${WORK}/${out}" 2>"${WORK}/render.err" ||
    fail "compose cannot render ${out}: $(head -c 300 "${WORK}/render.err")"
}
# make_var NAME [MAKE_ARGS...] — a variable as the Makefile expands it.
make_var() {
  local name="$1"
  shift
  make -s --no-print-directory -C "${ROOT}" ENGINE_TLS_ENGINES= CLOUD= "$@" \
    --eval "m262-var: ; @echo \$(${name})" m262-var 2>&1
}
plain_count() { jq '[.. | strings | select(test("http://(mini-baas-)?minio:9000"))] | length' "${WORK}/$1"; }

static_opt_in() {
  make_var DC | grep -q engine-tls-minio && fail "make composes the minio overlay by default"
  make_var DC ENGINE_TLS_ENGINES=minio | grep -q "${OVERLAY}" || fail "ENGINE_TLS_ENGINES=minio does not compose ${OVERLAY}"
  make_var DC ENGINE_TLS_ENGINES=minio | grep -q cloud-minio-tls && fail "the cloud companion is composed without CLOUD=1"
  make_var DC CLOUD=1 | grep -q cloud-minio-tls && fail "CLOUD=1 alone composes the cloud companion"
  make_var DC CLOUD=1 ENGINE_TLS_ENGINES=minio | grep -q "${CLOUD_TLS}" || fail "CLOUD=1 + minio lacks ${CLOUD_TLS}"
  make_var DC "ENGINE_TLS_ENGINES=redis minio" | grep -q 'engine-tls-redis.yml.*engine-tls-minio.yml' ||
    fail "minio does not compose beside another engine overlay"
  make_var PROD_FILES ENGINE_TLS_ENGINES=minio | grep -q minio && fail "PROD_FILES composes a minio overlay (MH10)"
  # make stops here, so its status is not pipefail'd into grep.
  local mono
  mono="$(make_var DC ENGINE_TLS_ENGINES=minio COMPOSE_FILE=orchestrators/compose/docker-compose.monolith.yml || true)"
  [[ "${mono}" == *"supports only COMPOSE_FILE=docker-compose.yml"* ]] || fail "make composes the minio overlay on the monolith (MH15)"
  ok "MH1/MH10/MH15: opt-in only, cloud companion only with CLOUD=1, never in PROD_FILES or on the monolith"
}

static_renders() {
  render base.json
  render tls.json "${OVERLAY}"
  render cloud-base.json "${CLOUD_BASE}"
  render cloud-tls.json "${CLOUD_BASE}" "${OVERLAY}" "${CLOUD_TLS}"
  render both.json "${OVERLAY}" orchestrators/compose/docker-compose.engine-tls-redis.yml
  [[ "$(plain_count base.json)" -gt 0 && "$(plain_count cloud-base.json)" -gt "$(plain_count base.json)" ]] ||
    fail "the base renders name no plaintext minio endpoint: the count below is vacuous"
  [[ "$(plain_count tls.json)" == 0 && "$(plain_count cloud-tls.json)" == 0 ]] ||
    fail "plaintext minio endpoints left: overlay $(plain_count tls.json), cloud $(plain_count cloud-tls.json)"
  jq -e '[.. | strings | select(test("/etc/minio-ca|engine-tls-drop|KONG_MINIO_CA_FILE"))] | length == 0' \
    "${WORK}/base.json" >/dev/null || fail "the default render carries part of the minio overlay"
  ok "MH7: plaintext minio endpoints base $(plain_count base.json) / cloud $(plain_count cloud-base.json) → 0 / 0 under the overlays"
}

static_scheme_only() {
  jq -e --slurpfile b "${WORK}/base.json" '.services["minio-iceberg-init"].entrypoint ==
    ($b[0].services["minio-iceberg-init"].entrypoint | if type == "array" then map(gsub("http://minio"; "https://minio"))
    else gsub("http://minio"; "https://minio") end)' "${WORK}/tls.json" >/dev/null ||
    fail "minio-iceberg-init's entrypoint differs from the base beyond the scheme"
  local props="${ROOT}/infra/docker/services/trino/conf/catalog"
  diff <(sed -e '/^#/d' -e 's|http://minio:9000|https://minio:9000|' "${props}/iceberg.properties") \
    <(sed '/^#/d' "${props}/iceberg-minio-tls.properties") >/dev/null || fail "iceberg-minio-tls.properties differs from iceberg.properties beyond the scheme"
  jq -e '.services.minio.healthcheck.test[1] | test("--cacert .*https://localhost:9000")' "${WORK}/tls.json" >/dev/null ||
    fail "the minio healthcheck is not https with --cacert (MH4)"
  jq -e '.services.trino.healthcheck.test[1] | test("--cacert /certificates/minio-ca.crt https://minio:9000")' \
    "${WORK}/tls.json" >/dev/null || fail "trino's healthcheck does not verify minio with its CA (MH9)"
  ok "mc-init and trino's catalog change only the scheme; minio and trino health verify the CA (MH4, MH9)"
}

static_trust() {
  local pair f b
  for pair in tls.json:base.json cloud-tls.json:cloud-base.json both.json:base.json; do
    f="${pair%:*}" b="${pair#*:}"
    jq -e '[.services[] | .environment // {} | has("SSL_CERT_FILE")] | any | not' "${WORK}/${f}" >/dev/null ||
      fail "${f}: a service sets SSL_CERT_FILE, which replaces the system roots (MH5)"
    jq -e --slurpfile b "${WORK}/${b}" '[.services | to_entries[] | .key as $s | .value.environment // {} as $e
      | ($b[0].services[$s].environment // {}) as $o
      | $e.NODE_OPTIONS == $o.NODE_OPTIONS and $e.DATA_PLANE_TLS_INSECURE == $o.DATA_PLANE_TLS_INSECURE] | all' \
      "${WORK}/${f}" >/dev/null || fail "${f}: NODE_OPTIONS or DATA_PLANE_TLS_INSECURE differs from ${b} (MH5, MH14)"
    jq -e --arg d "${WORK}/minio" '[.services | to_entries[] | select(.key != "minio") | .value.volumes // [] | .[]
      | .source // "" | select(startswith($d) or test("engine-key|ca-key"))] | all(endswith("/ca.pem"))' \
      "${WORK}/${f}" >/dev/null || fail "${f}: a client mounts more than ca.pem from the minio cert dir (MH6)"
  done
  ok "MH5/MH6/MH14: no SSL_CERT_FILE, NODE_OPTIONS and DATA_PLANE_TLS_INSECURE as the base, clients mount ca.pem only"
}

# kong_render OUT SCRIPT [CA] — render-kong-config.sh on the repo template with dummy keys.
kong_render() {
  env -i PATH="${PATH}" KONG_PUBLIC_API_KEY=a KONG_SERVICE_API_KEY=s KONG_CORS_ORIGIN_APP=https://x \
    KONG_CORS_ORIGIN_PLAYGROUND=https://x KONG_CORS_ORIGIN_STUDIO=https://x KONG_CORS_ORIGIN_FRONTEND=https://x \
    JWT_SECRET=j GOTRUE_JWT_ISS=https://x KONG_ANON_UUID=u ${3:+KONG_MINIO_CA_FILE="$3"} \
    sh "$2" "${KONG_TMPL:-${ROOT}/infra/docker/services/kong/conf/kong.yml}" "${WORK}/$1"
}

static_kong() {
  local script="${ROOT}/infra/docker/services/kong/render-kong-config.sh"
  # The script as it was before MH8: its KONG_MINIO_CA_FILE block cut out.
  awk '/^# KONG_MINIO_CA_FILE/ { cut = 1 } !cut { print } cut && /^fi$/ { cut = 0 }' "${script}" >"${WORK}/render-old.sh"
  kong_render off.yml "${script}" && kong_render old.yml "${WORK}/render-old.sh"
  cmp -s "${WORK}/off.yml" "${WORK}/old.yml" || fail "kong.yml without KONG_MINIO_CA_FILE differs from the old render"
  printf 'CA\n' >"${WORK}/ca.pem" && kong_render on.yml "${script}" "${WORK}/ca.pem"
  awk '/^ca_certificates:$/ { exit } /^    (tls_verify: true|ca_certificates: \[)/ { next }
    { sub("url: https://minio:9000", "url: http://minio:9000"); print }' "${WORK}/on.yml" | cmp -s - "${WORK}/off.yml" ||
    fail "with KONG_MINIO_CA_FILE, kong.yml changes more than the storage hop and the CA entity"
  [[ "$(grep -c '^    tls_verify: true$' "${WORK}/on.yml")" == 1 ]] || fail "the storage hop lacks tls_verify: true (MH8)"
  printf -- '-----BEGIN PRIVATE KEY-----\n' >"${WORK}/key.pem"
  kong_render key.yml "${script}" "${WORK}/key.pem" 2>/dev/null && fail "render accepted a private key as the CA"
  kong_render none.yml "${script}" "${WORK}/missing.pem" 2>/dev/null && fail "render accepted a missing CA"
  grep -v 'url: http://minio:9000' "${ROOT}/infra/docker/services/kong/conf/kong.yml" >"${WORK}/nourl.tmpl"
  KONG_TMPL="${WORK}/nourl.tmpl" kong_render nourl.yml "${script}" "${WORK}/ca.pem" 2>/dev/null &&
    fail "render accepted a template without the storage url"
  ok "MH1/MH8: kong.yml byte-identical without the CA; with it only https + tls_verify + the CA; key, missing CA, no url refused"
}

static_records() {
  local f
  for f in scripts/ops/vault-restore.sh scripts/ops/vault-seed.sh scripts/ops/stack-health-requests.sh \
    scripts/test/phase/phase9-storage-operations-test.sh; do
    grep -q '/run/engine-tls/certs' "${ROOT}/${f}" || fail "${f} does not handle the overlay's MinIO (MH11)"
  done
  grep -q 'https://minio' "${ROOT}/orchestrators/compose/docker-compose.monolith.yml" && fail "the monolith was half-switched"
  grep -rq 'https://minio' "${ROOT}/deploy/helm" && fail "helm was half-switched"
  grep -qi 'monolith and helm .*unsupported' "${ROOT}/docs/adr/0030-g5-minio-https-hard-cutover-overlay.md" ||
    fail "ADR 0030 does not record monolith and helm as unsupported (MH15)"
  ok "MH11/MH15: four host scripts read the overlay CA; monolith and helm untouched and recorded unsupported"
  local spike=wiki/architecture/minio-https-trust-matrix.md
  [[ -f "${ROOT}/${spike}" ]] && grep -qF "${spike}" "${ROOT}/docs/adr/0030-g5-minio-https-hard-cutover-overlay.md" ||
    fail "ADR 0030 does not link the spike doc ${spike} (MH16)"
  ok "MH16: ADR 0030 links the spike doc"
}

cleanup() {
  [[ -z "${WORK}" ]] && return
  [[ "$(type -t live_cleanup)" == function ]] && live_cleanup
  rm -rf "${WORK}"
}

main() {
  WORK="$(mktemp -d "${M262_TMP:-${TMPDIR:-/tmp}}/m262.XXXXXX")"
  trap cleanup EXIT
  step "static: opt-in, renders, trust, kong, records"
  static_opt_in
  static_renders
  static_scheme_only
  static_trust
  static_kong
  static_records
  [[ "${M262_LIVE:-0}" == 1 ]] || {
    step "live legs skipped (M262_LIVE=1 runs them)"
    return
  }
  # shellcheck source=../lib/lib-m262-minio-live.sh
  . "${ROOT}/scripts/lib/lib-m262-minio-live.sh"
  # shellcheck source=../lib/lib-m262-minio-probes.sh
  . "${ROOT}/scripts/lib/lib-m262-minio-probes.sh"
  live_main
  step "PASS"
}

main "$@"
