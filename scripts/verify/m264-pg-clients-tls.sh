#!/usr/bin/env bash
# m264-pg-clients-tls.sh — the nine Node services that dial the central Postgres verify its
# certificate under one opt-in overlay (G5, ADR 0032, devil NP1–NP12 and W1–W6).
#
# Static (no stack): make composes docker-compose.engine-tls-pg-clients.yml only when
# ENGINE_TLS_ENGINES lists pg-clients beside ENGINE_TLS=1, never on the monolith or in
# PROD_FILES, and up / bench-startup / cutover-% run the preflight first (NP1); the services
# it changes are the ones whose source dials Postgres (NP2); each of them changes only its
# DATABASE_URL, by the suffix, and gains one read-only ca.pem bind, with no PGSSLMODE,
# AUDIT_DATABASE_URL or NODE_EXTRA_CA_CERTS (NP3, NP5, NP10); no other configuration composes
# it, and beside the data-plane overlay query-router keeps both trusts (NP11); the preflight
# refuses a `?`/`#` DSN, an AUDIT_DATABASE_URL, a cert ca.pem did not sign, expiring within 30
# days or not naming the DSN host (NP4, NP6).
# Live (M264_LIVE=1, docker): scripts/lib/lib-m264-pg-clients-live.sh — scratch project
# m264-<pid>, no published ports.
#
# Caveat: the dialer set is a grep for PostgresModule, AuditModule and the 'pg' import under
# src/apps; an app dialing through a library module of another name is missed, and the render
# check then fails it as "changes a service source does not dial" only if the overlay lists
# it. Static checks read renders, not a running stack, with the host's .env (DATABASE_URL
# must be set; scripts/env/assemble-env.sh). Env: M264_LIVE · M264_TMP · M264_REUSE_IMAGES.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OVERLAY="orchestrators/compose/docker-compose.engine-tls-pg-clients.yml"
ENGINE_TLS_OVERLAY="orchestrators/compose/docker-compose.engine-tls.yml"
DP_OVERLAY="orchestrators/compose/docker-compose.engine-tls-data-plane.yml"
CHECK="scripts/certs/check-pg-clients-tls.sh"
ADR="docs/adr/0032-g5-node-pg-clients-verify-full.md"
SUFFIX="?sslmode=verify-full&sslrootcert=/etc/engine-pg-ca/ca.pem"
CA_TARGET="/etc/engine-pg-ca/ca.pem"
WORK=""

step() { printf '\033[0;36m[M264] %s\033[0m\n' "$*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M264] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

# shellcheck source=../lib/lib-overlay-render.sh
. "${ROOT}/scripts/lib/lib-overlay-render.sh"
# mk NAME ARGS... — make_var with the .env.local switches blanked too.
mk() { make_var "$1" ENGINE_TLS= NETSEG= REDIS_ACL= "${@:2}"; }

static_opt_in() {
  mk DC ENGINE_TLS=1 | grep -q pg-clients && fail "ENGINE_TLS=1 alone composes the pg-clients overlay"
  mk DC ENGINE_TLS=1 ENGINE_TLS_ENGINES=pg-clients | grep -q -- "-f ${ENGINE_TLS_OVERLAY} -f ${OVERLAY}" ||
    fail "ENGINE_TLS_ENGINES=pg-clients does not compose ${OVERLAY} after ${ENGINE_TLS_OVERLAY}"
  mk PROD_FILES ENGINE_TLS=1 ENGINE_TLS_ENGINES=pg-clients | grep -q pg-clients && fail "PROD_FILES composes pg-clients"
  # make stops on $(error), so its status is not pipefail'd into the match.
  local out
  out="$(mk DC ENGINE_TLS_ENGINES=pg-clients || true)"
  [[ "${out}" == *"ENGINE_TLS_ENGINES=pg-clients needs ENGINE_TLS=1"* ]] || fail "make composes pg-clients without ENGINE_TLS=1"
  out="$(mk DC ENGINE_TLS=1 ENGINE_TLS_ENGINES=pg-clients COMPOSE_FILE=orchestrators/compose/docker-compose.monolith.yml || true)"
  [[ "${out}" == *"ENGINE_TLS_ENGINES=pg-clients supports only COMPOSE_FILE=docker-compose.yml"* ]] ||
    fail "make composes pg-clients on the monolith"
  local target
  for target in up bench-startup cutover-%; do
    grep -qE "^${target}:.* _pg-clients-tls( |$)" "${ROOT}"/orchestrators/makes/*.mk ||
      fail "make ${target} does not run the _pg-clients-tls preflight"
  done
  ok "NP1: opt-in beside ENGINE_TLS=1 only, never on the monolith or in PROD_FILES; up, bench-startup, cutover-% preflight"
}

# The services whose DATABASE_URL the overlay changes, sorted, one per line.
changed_services() {
  jq -r --slurpfile b "${WORK}/engine-tls.json" '.services | to_entries[]
    | select(.value.environment.DATABASE_URL != $b[0].services[.key].environment.DATABASE_URL) | .key' \
    "${WORK}/pgc.json" | sort
}

static_dialers() {
  render engine-tls.json "${ENGINE_TLS_OVERLAY}"
  render pgc.json "${ENGINE_TLS_OVERLAY}" "${OVERLAY}"
  local derived
  derived="$(cd "${ROOT}/src" && grep -rlE "PostgresModule|AuditModule|from 'pg'|require\('pg'\)" --include='*.ts' apps |
    grep -v '\.spec\.ts$' | cut -d/ -f2 | sort -u)"
  [[ "$(wc -l <<<"${derived}")" == 9 ]] || fail "source has $(wc -l <<<"${derived}") Postgres-dialing apps, ADR 0032 records 9"
  [[ "$(changed_services)" == "${derived}" ]] ||
    fail "the overlay changes [$(changed_services | tr '\n' ' ')], source dials from [$(tr '\n' ' ' <<<"${derived}")]"
  NINE="$(jq -Rn '[inputs]' <<<"${derived}")"
  ok "NP2: the overlay changes exactly the 9 services whose source dials Postgres"
}

static_overlay() {
  jq -e --slurpfile b "${WORK}/engine-tls.json" --argjson s "${NINE}" --arg suf "${SUFFIX}" --arg t "${CA_TARGET}" '
    def norm: del(.environment.DATABASE_URL) | .volumes = ((.volumes // []) | map(select(.target != $t)));
    (.services | delpaths($s | map([.]))) == ($b[0].services | delpaths($s | map([.])))
    and ([$s[] as $n | .services[$n] as $p | $b[0].services[$n] as $o
      | ($o.environment.DATABASE_URL | type) == "string"
        and $p.environment.DATABASE_URL == $o.environment.DATABASE_URL + $suf
        and ($p | norm) == ($o | norm)
        and ([$p.volumes[] | select(.target == $t)] | length == 1 and .[0].read_only == true
          and (.[0].source | endswith("/ca.pem")))] | all)' "${WORK}/pgc.json" >/dev/null ||
    fail "the overlay changes more than the 9 services' DATABASE_URL suffix and one read-only ca.pem bind"
  jq -e '[.services[] | .environment // {} | has("PGSSLMODE") or has("PGSSLROOTCERT")] | any | not' \
    "${WORK}/pgc.json" >/dev/null || fail "a service sets PGSSLMODE or PGSSLROOTCERT (process-wide in pg)"
  grep -v '^[[:space:]]*#' "${ROOT}/${OVERLAY}" | grep -qE 'AUDIT_DATABASE_URL|NODE_EXTRA_CA_CERTS|PGSSL' &&
    fail "${OVERLAY} names AUDIT_DATABASE_URL, NODE_EXTRA_CA_CERTS or PGSSL*"
  grep -q '^# Caveat:' "${ROOT}/${OVERLAY}" || fail "${OVERLAY} has no Caveat line (NP9)"
  ok "NP3/NP5/NP9/NP10: only the suffix and a ca.pem bind; tenant-control, gotrue and the rest byte-identical"
}

static_no_drift() {
  local config
  local -a args
  for config in "" "ENGINE_TLS=1" "CLOUD=1" "NETSEG=1" "REDIS_ACL=1" "ENGINE_TLS_ENGINES=data-plane" \
    "ENGINE_TLS_ENGINES=minio" "ENGINE_TLS=1 ENGINE_TLS_ENGINES=mongo"; do
    read -ra args <<<"${config}"
    mk DC "${args[@]}" | grep -q pg-clients && fail "make DC ${config:-(default)} composes the pg-clients overlay"
  done
  mk DC ENGINE_TLS=1 "ENGINE_TLS_ENGINES=data-plane pg-clients" | grep -q -- "-f ${DP_OVERLAY} -f ${OVERLAY}" ||
    fail "ENGINE_TLS_ENGINES=\"data-plane pg-clients\" does not compose both overlays"
  render dp-pgc.json "${ENGINE_TLS_OVERLAY}" "${DP_OVERLAY}" "${OVERLAY}"
  render pgc-dp.json "${ENGINE_TLS_OVERLAY}" "${OVERLAY}" "${DP_OVERLAY}"
  local f
  for f in dp-pgc.json pgc-dp.json; do
    jq -e --arg suf "${SUFFIX}" --arg t "${CA_TARGET}" '.services["query-router"]
      | .environment.NODE_EXTRA_CA_CERTS == "/etc/data-plane-ca/ca.pem"
        and (.environment.DATABASE_URL | endswith($suf))
        and ([.volumes[].target] | index("/etc/data-plane-ca/ca.pem") != null and index($t) != null)' \
      "${WORK}/${f}" >/dev/null || fail "${f}: query-router loses the data-plane trust or the Postgres CA"
  done
  ok "NP11: 8 other configurations never compose it; beside data-plane (either order) query-router keeps both trusts"
}

# check_case LABEL WANT ENV... — the preflight under ENV; WANT is "ok" or a stderr fragment.
check_case() {
  local label="$1" want="$2" out rc=0
  shift 2
  out="$(env -u AUDIT_DATABASE_URL ENGINE_TLS_CERT_DIR="${WORK}/engines" "$@" bash "${ROOT}/${CHECK}" 2>&1)" || rc=$?
  if [[ "${want}" == ok ]]; then
    [[ "${rc}" == 0 ]] || fail "preflight refused the ${label} case: ${out}"
  else
    [[ "${rc}" != 0 && "${out}" == *"${want}"* ]] || fail "preflight did not refuse the ${label} case (rc ${rc})"
  fi
}

static_preflight() {
  local good="postgres://m264:m264@postgres:5432/postgres" dir="${WORK}/engines"
  check_case ok ok DATABASE_URL="${good}"
  check_case query "query string or fragment" DATABASE_URL="${good}?application_name=x"
  check_case fragment "query string or fragment" DATABASE_URL="${good}#f"
  check_case empty "DATABASE_URL is unset" DATABASE_URL=
  check_case audit "AUDIT_DATABASE_URL is set" DATABASE_URL="${good}" AUDIT_DATABASE_URL="${good}"
  check_case san "host pgalias is not in" DATABASE_URL="postgres://m264:m264@pgalias:5432/postgres"
  cp "${dir}/ca.pem" "${WORK}/ca.keep"
  cp "${WORK}/other-ca.pem" "${dir}/ca.pem"
  check_case wrong-ca "is not signed by" DATABASE_URL="${good}"
  cp "${WORK}/ca.keep" "${dir}/ca.pem"
  cp "${dir}/engine.pem" "${WORK}/engine.keep"
  cp "${WORK}/short.pem" "${dir}/engine.pem"
  check_case expiry "expires within 30 days" DATABASE_URL="${good}"
  cp "${WORK}/engine.keep" "${dir}/engine.pem"
  check_case missing "is missing" DATABASE_URL="${good}" ENGINE_TLS_CERT_DIR="${WORK}/absent"
  local out
  out="$(DATABASE_URL="${good}?a=1" make -s --no-print-directory -C "${ROOT}" ENGINE_TLS=1 ENGINE_TLS_ENGINES=pg-clients \
    CLOUD= NETSEG= REDIS_ACL= _pg-clients-tls 2>&1 || true)"
  [[ "${out}" == *"query string or fragment"* ]] || fail "make _pg-clients-tls does not run the preflight"
  ok "NP4/NP6: ok, ?/#, empty, AUDIT, SAN, wrong CA, 10-day cert, missing dir, and through make"
}

# A scratch local CA and its postgres cert from the real scripts; an unrelated CA and a
# 10-day leaf it signed for the refusal cases.
mint() {
  mkdir -p "${WORK}/ca"
  TRACK_BINOCLE_CERT_DIR="${WORK}/ca" MINI_BAAS_WAF_TLS_GID=none GROBASE_PUBLIC_ADDRESSES='' \
    sh "${ROOT}/scripts/certs/generate-localhost-cert.sh" >/dev/null || fail "the scratch local CA was not minted"
  TRACK_BINOCLE_CERT_DIR="${WORK}/ca" ENGINE_TLS_CERT_DIR="${WORK}/engines" \
    sh "${ROOT}/scripts/certs/generate-engine-cert.sh" postgres >/dev/null || fail "generate-engine-cert.sh postgres failed"
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=m264-other-ca \
    -keyout "${WORK}/other-ca-key.pem" -out "${WORK}/other-ca.pem" 2>/dev/null || fail "openssl could not mint the other CA"
  openssl req -x509 -newkey rsa:2048 -nodes -days 10 -subj /CN=postgres -addext subjectAltName=DNS:postgres \
    -CA "${WORK}/ca/track-binocle-local-ca.pem" -CAkey "${WORK}/ca/track-binocle-local-ca-key.pem" \
    -keyout "${WORK}/short-key.pem" -out "${WORK}/short.pem" 2>/dev/null || fail "openssl could not mint the 10-day cert"
}

static_records() {
  [[ -f "${ROOT}/${ADR}" ]] || fail "${ADR} is missing"
  local word
  for word in tenant-control gotrue Rust pooler VM monolith W1 W2 W3 W4 W5 W6; do
    grep -q "${word}" "${ROOT}/${ADR}" || fail "${ADR} does not record ${word}"
  done
  grep -q 'outbox emission failed' "${ROOT}/src/apps/query-router/src/query/query.outbox-swallow.spec.ts" ||
    fail "the W2 spec no longer pins the outbox swallow"
  ok "ADR 0032 records the out-of-scope clients and W1–W6; the W2 spec is in place"
}

cleanup() {
  [[ -z "${WORK}" ]] && return
  [[ "$(type -t live_cleanup)" == function ]] && live_cleanup
  rm -rf "${WORK}"
}

main() {
  WORK="$(mktemp -d "${M264_TMP:-${TMPDIR:-/tmp}}/m264.XXXXXX")"
  trap cleanup EXIT
  export ENGINE_TLS_CERT_DIR="${WORK}/engines" ENGINE_TLS_DATA_PLANE_CERT_DIR="${WORK}/data-plane"
  step "static: opt-in, dialers, overlay, no drift, preflight, records"
  mint
  static_opt_in
  static_dialers
  static_overlay
  static_no_drift
  static_preflight
  static_records
  [[ "${M264_LIVE:-0}" == 1 ]] || {
    step "live legs skipped (M264_LIVE=1 runs them)"
    return
  }
  # shellcheck source=../lib/lib-m264-pg-clients-live.sh
  . "${ROOT}/scripts/lib/lib-m264-pg-clients-live.sh"
  live_main
  step "PASS"
}

main "$@"
