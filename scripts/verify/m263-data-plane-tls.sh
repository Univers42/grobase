#!/usr/bin/env bash
# m263-data-plane-tls.sh — the data plane's TLS port under one opt-in overlay (G5, ADR 0031).
#
# Static (no stack): make composes docker-compose.engine-tls-data-plane.yml only when
# ENGINE_TLS_ENGINES lists data-plane, never in PROD_FILES or on the monolith; without it the
# default, CLOUD=1, NETSEG=1 and ENGINE_TLS=1 renders carry none of it (DT8); with it only
# the router and its two signing callers change, 4012 is published nowhere, clients mount
# ca.pem only, trust is additive (no SSL_CERT_FILE, NODE_OPTIONS and DATA_PLANE_TLS_INSECURE
# as the base), and beside the cloud MinIO overlay tenant-control trusts both CAs (DT14).
# Live (M263_LIVE=1, docker): scripts/lib/lib-m263-data-plane-live.sh — scratch containers
# named m263-<pid>-*, ports on 127.0.0.1 only for the probes.
#
# Caveat: static checks read renders and the Makefile, not a running stack, and run with the
# host's env: an exported RUST_DATA_PLANE_URL changes the renders and fails the https leg.
# Needs the .env and localhost cert compose interpolates (scripts/env/assemble-env.sh,
# scripts/certs/generate-localhost-cert.sh). Env: M263_LIVE · M263_DPR_IMAGE · M263_TC_IMAGE ·
# M263_QR_IMAGE · M263_PORT_BASE.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OVERLAY="orchestrators/compose/docker-compose.engine-tls-data-plane.yml"
MINIO_OVERLAY="orchestrators/compose/docker-compose.engine-tls-minio.yml"
CLOUD_TLS="orchestrators/compose/docker-compose.cloud-minio-tls.yml"
ADR="docs/adr/0031-g5-data-plane-tls-accept-mode.md"
CALLERS='["query-router","tenant-control"]'
CHANGED='["data-plane-router-rust","query-router","tenant-control"]'
WORK=""

step() { printf '\033[0;36m[M263] %s\033[0m\n' "$*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M263] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

# shellcheck source=../lib/lib-overlay-render.sh
. "${ROOT}/scripts/lib/lib-overlay-render.sh"
marks() { jq '[.. | strings | select(test("DATA_PLANE_ROUTER_TLS|/etc/data-plane-(ca|tls)|:4012"))] | length' "${WORK}/$1"; }

static_opt_in() {
  make_var DC | grep -q engine-tls-data-plane && fail "make composes the data-plane overlay by default"
  make_var DC ENGINE_TLS_ENGINES=data-plane | grep -q "${OVERLAY}" || fail "ENGINE_TLS_ENGINES=data-plane does not compose ${OVERLAY}"
  make_var DC CLOUD=1 "ENGINE_TLS_ENGINES=minio data-plane" |
    grep -q "engine-tls-minio.yml -f ${OVERLAY} -f ${CLOUD_TLS}" || fail "the cloud MinIO companion is not composed after ${OVERLAY}"
  make_var PROD_FILES ENGINE_TLS_ENGINES=data-plane | grep -q data-plane && fail "PROD_FILES composes the data-plane overlay"
  # make stops here, so its status is not pipefail'd into grep.
  local mono
  mono="$(make_var DC ENGINE_TLS_ENGINES=data-plane COMPOSE_FILE=orchestrators/compose/docker-compose.monolith.yml || true)"
  [[ "${mono}" == *"ENGINE_TLS_ENGINES=data-plane supports only COMPOSE_FILE=docker-compose.yml"* ]] ||
    fail "make composes the data-plane overlay on the monolith"
  ok "opt-in only, before the cloud MinIO companion, never in PROD_FILES or on the monolith"
}

static_default() {
  local cloud name
  cloud="$(cloud_stub)"
  render base.json
  render cloud.json "${cloud}"
  render netseg.json orchestrators/compose/docker-compose.netseg.yml
  render engine-tls.json orchestrators/compose/docker-compose.engine-tls.yml
  for name in base cloud netseg engine-tls; do
    [[ "$(marks "${name}.json")" == 0 ]] || fail "the ${name} render carries part of the data-plane overlay (DT8)"
    jq -e --argjson c "${CALLERS}" '[.services[$c[]].environment.RUST_DATA_PLANE_URL]
      | all(. == "http://data-plane-router-rust:4011")' "${WORK}/${name}.json" >/dev/null ||
      fail "the ${name} render does not keep both callers on http://data-plane-router-rust:4011"
  done
  ok "DT8: default, CLOUD=1, NETSEG=1 and ENGINE_TLS=1 renders: no TLS port, both callers on plaintext 4011"
}

static_overlay() {
  render tls.json "${OVERLAY}"
  render netseg-tls.json orchestrators/compose/docker-compose.netseg.yml "${OVERLAY}"
  jq -e --slurpfile b "${WORK}/base.json" --argjson c "${CHANGED}" \
    '(.services | delpaths($c | map([.]))) == ($b[0].services | delpaths($c | map([.])))' "${WORK}/tls.json" >/dev/null ||
    fail "the overlay changes a service other than the router and its two callers"
  jq -e '.services["data-plane-router-rust"] | .pull_policy == "build" and .environment.DATA_PLANE_ROUTER_TLS_PORT == "4012"
    and .environment.DATA_PLANE_ROUTER_TLS_CERT_FILE == "/etc/data-plane-tls/engine.pem"
    and .environment.DATA_PLANE_ROUTER_TLS_KEY_FILE == "/etc/data-plane-tls/engine-key.pem"
    and ([.volumes[] | select(.target == "/etc/data-plane-tls") | .read_only] == [true])' "${WORK}/tls.json" >/dev/null ||
    fail "the router lacks its TLS env, a read-only cert mount or pull_policy: build"
  local f
  for f in tls.json netseg-tls.json; do
    jq -e --argjson c "${CALLERS}" '[.services[$c[]].environment.RUST_DATA_PLANE_URL]
      | all(. == "https://data-plane-router-rust:4012")' "${WORK}/${f}" >/dev/null ||
      fail "${f}: a caller does not dial https://data-plane-router-rust:4012"
    jq -e '[.services[] | .ports // [] | .[] | select(.target == 4012 or (.published | tostring) == "4012")] == []' \
      "${WORK}/${f}" >/dev/null || fail "${f}: a service publishes 4012"
  done
  jq -e '.services["query-router"].environment.NODE_EXTRA_CA_CERTS == "/etc/data-plane-ca/ca.pem"
    and .services["tenant-control"].environment.SSL_CERT_DIR == "/etc/data-plane-ca:/etc/ssl/certs"' \
    "${WORK}/tls.json" >/dev/null || fail "a caller lacks its additive trust knob"
  ok "only the router and its callers change; both dial https://…:4012 (also under NETSEG=1); 4012 published nowhere"
}

static_trust() {
  local cloud pair f b
  cloud="${WORK}/cloud.yml"
  render combo.json "${cloud}" "${MINIO_OVERLAY}" "${OVERLAY}" "${CLOUD_TLS}"
  render cloud-minio.json "${cloud}" "${MINIO_OVERLAY}" "${CLOUD_TLS}"
  for pair in tls.json:base.json combo.json:cloud-minio.json; do
    f="${pair%:*}" b="${pair#*:}"
    jq -e '[.services[] | .environment // {} | has("SSL_CERT_FILE")] | any | not' "${WORK}/${f}" >/dev/null ||
      fail "${f}: a service sets SSL_CERT_FILE, which replaces the system roots"
    jq -e --slurpfile b "${WORK}/${b}" '[.services | to_entries[] | .key as $s | .value.environment // {} as $e
      | ($b[0].services[$s].environment // {}) as $o
      | $e.NODE_OPTIONS == $o.NODE_OPTIONS and $e.DATA_PLANE_TLS_INSECURE == $o.DATA_PLANE_TLS_INSECURE] | all' \
      "${WORK}/${f}" >/dev/null || fail "${f}: NODE_OPTIONS or DATA_PLANE_TLS_INSECURE differs from ${b}"
    jq -e --arg d "${ENGINE_TLS_DATA_PLANE_CERT_DIR}" '[.services | to_entries[] | select(.key != "data-plane-router-rust")
      | .value.volumes // [] | .[] | .source // "" | select(startswith($d) or test("engine-key|ca-key"))]
      | all(endswith("/ca.pem"))' "${WORK}/${f}" >/dev/null || fail "${f}: a client mounts more than ca.pem"
  done
  jq -e '.services["tenant-control"] | .environment.SSL_CERT_DIR == "/etc/minio-ca:/etc/data-plane-ca:/etc/ssl/certs"
    and ([.volumes[].target] | index("/etc/minio-ca/ca.pem") != null and index("/etc/data-plane-ca/ca.pem") != null)' \
    "${WORK}/combo.json" >/dev/null || fail "beside the cloud MinIO overlay, tenant-control does not trust both CAs (DT14)"
  ok "no SSL_CERT_FILE; NODE_OPTIONS and DATA_PLANE_TLS_INSECURE as the base; clients mount ca.pem only; DT14 both CAs"
}

static_records() {
  [[ -f "${ROOT}/${ADR}" ]] || fail "${ADR} is missing"
  local scope
  for scope in Kong nano monolith helm fly VM; do
    grep -q "${scope}" "${ROOT}/${ADR}" || fail "${ADR} does not record ${scope} as out of scope"
  done
  grep -q 'data-plane)' "${ROOT}/scripts/certs/generate-engine-cert.sh" || fail "generate-engine-cert.sh has no data-plane case"
  ok "ADR 0031 records what stays out of scope; the cert script issues data-plane"
}

cleanup() {
  [[ -z "${WORK}" ]] && return
  [[ "$(type -t live_cleanup)" == function ]] && live_cleanup
  rm -rf "${WORK}"
}

main() {
  WORK="$(mktemp -d "${M263_TMP:-${TMPDIR:-/tmp}}/m263.XXXXXX")"
  trap cleanup EXIT
  export ENGINE_TLS_DATA_PLANE_CERT_DIR="${WORK}/data-plane" ENGINE_TLS_MINIO_CERT_DIR="${WORK}/minio"
  step "static: opt-in, default renders, overlay, trust, records"
  static_opt_in
  static_default
  static_overlay
  static_trust
  static_records
  [[ "${M263_LIVE:-0}" == 1 ]] || {
    step "live legs skipped (M263_LIVE=1 runs them)"
    return
  }
  # shellcheck source=../lib/lib-m263-data-plane-live.sh
  . "${ROOT}/scripts/lib/lib-m263-data-plane-live.sh"
  live_main
  step "PASS"
}

main "$@"
