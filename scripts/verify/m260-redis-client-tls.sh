#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m260-redis-client-tls.sh — the Rust Redis clients dial rediss:// verified   #
#                                                                              #
#  G5b made redis serve TLS on 6380 while every client stayed plaintext,       #
#  because the redis crate had no TLS feature (G5b-C9). D3 turns it on for     #
#  the pool and the server's limiter/quota/metering link (ADR 0024, R1–R13).   #
#                                                                              #
#  This gate mints a THROWAWAY CA, a redis engine cert and a second, unrelated #
#  CA, boots redis behind the G5b overlay (ENGINE_TLS_ENGINES=redis, TLS on    #
#  6380, never published) under its own compose project, and runs the real     #
#  clients in a --features dynamodb build (ring + aws-lc-rs linked, R5):       #
#  rediss + the CA verifies; a wrong CA and a host name outside the SANs are   #
#  refused; an empty system store trusts only the CA (R9); plaintext 6379 is   #
#  unchanged; the server's honor-set refresh reads over rediss. Static: no     #
#  compose default names rediss:// (R2).                                       #
#                                                                              #
#  Needs the .env and localhost cert compose interpolates (CI makes them with  #
#  assemble-env.sh and generate-localhost-cert.sh, as for m247). Its project,  #
#  container and temp dir are removed by an EXIT trap; it never touches a      #
#  mini-baas-* container or the repo's CA.                                     #
#                                                                              #
#  Env: M260_PROJECT (m260) · M260_TOOLCHAIN (mini-baas-rust-toolchain) ·      #
#       M260_TARGET (volume or path for target/, m260-dpr-target) ·            #
#       M260_IMAGE (redis image override, as M247_IMAGE) · M260_TMP.           #
# **************************************************************************** #
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OVERLAY="orchestrators/compose/docker-compose.engine-tls-redis.yml"
PROJECT="${M260_PROJECT:-m260}"
TOOLCHAIN="${M260_TOOLCHAIN:-mini-baas-rust-toolchain}"
TARGET="${M260_TARGET:-m260-dpr-target}"
CONTAINER="${PROJECT}-redis"
WORK=""

step() { printf '\033[0;36m[M260] %s\033[0m\n' "$*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M260] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

dc() {
  docker compose -p "${PROJECT}" --project-directory "${ROOT}" -f "${ROOT}/docker-compose.yml" \
    -f "${ROOT}/${OVERLAY}" -f "${WORK}/rename.yml" --profile data-plane "$@"
}
cleanup() {
  [[ -z "${WORK}" ]] && return
  dc down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}

# cargo on the project network, the throwaway certs at /m260; extra docker args first.
toolchain() {
  docker run --rm --network "${PROJECT}_mini-baas" \
    -v "${ROOT}":/repo -w /repo/src/data-plane-router \
    -v mini-baas-cargo-registry:/usr/local/cargo/registry \
    -v mini-baas-cargo-git:/usr/local/cargo/git \
    -v "${TARGET}":/repo/src/data-plane-router/target \
    -v "${WORK}":/m260:ro \
    -e CARGO_NET_RETRY=10 -e CARGO_HTTP_MULTIPLEXING=false \
    -e M260_REDISS_URL=rediss://redis:6380/0 \
    -e "M260_UNLISTED_URL=rediss://${CONTAINER}:6380/0" \
    -e M260_PLAIN_URL=redis://redis:6379/0 \
    -e M260_CA_FILE=/m260/redis/ca.pem \
    -e M260_WRONG_CA_FILE=/m260/wrong/track-binocle-local-ca.pem \
    -e M260_EMPTY_STORE=/m260/empty.pem \
    "$@"
}

# $1 label, $2 expected passed count, rest the cargo test command. `cargo test`
# exits 0 when it runs ZERO tests, so the count is checked, not just the exit.
cargo_proof() {
  local label="$1" want="$2" out="${WORK}/$1.out"
  shift 2
  if ! toolchain "${TOOLCHAIN}" "$@" >"${out}" 2>&1; then
    sed 's/^/    /' "${out}" | tail -40
    fail "${label} failed"
  fi
  grep -qE "test result: ok\. ${want} passed" "${out}" ||
    fail "${label}: expected exactly ${want} passed; cargo said: $(grep -m1 'test result' "${out}" || echo 'no test result line')"
  # --nocapture prints a case's line right after cargo's own "test … " prefix, so unanchored.
  grep -ohE '(refused as expected|rediss \+ CA|redis:// 6379|empty store|server honor-set).*' "${out}" | sed 's/^/    /' || true
  ok "${label}: ${want} passed"
}

step "0/5 preconditions"
command -v docker >/dev/null 2>&1 || fail "docker is required"
[[ -f "${ROOT}/${OVERLAY}" ]] || fail "the G5b redis overlay is missing: ${OVERLAY}"
[[ -f "${ROOT}/.env" ]] || fail "no .env: run scripts/env/assemble-env.sh (compose interpolates every file)"
docker image inspect "${TOOLCHAIN}" >/dev/null 2>&1 || docker pull -q "${TOOLCHAIN}" >/dev/null ||
  fail "toolchain image ${TOOLCHAIN} missing — run 'make _rust-toolchain' first"
ok "docker, the overlay, .env and the toolchain image are present"

step "1/5 R2: rediss:// is opt-in — no compose default names it"
# Comments may name rediss://; a value may not.
if hits="$(grep -rnE '^[^#]*rediss://' "${ROOT}/docker-compose.yml" "${ROOT}/orchestrators/compose" "${ROOT}/.env.example")"; then
  printf '%s\n' "${hits}" | sed 's/^/    /'
  fail "a compose default dials rediss://; every default must stay redis://…:6379"
fi
ok "every compose default stays redis://"

step "2/5 mint a throwaway CA + redis cert, an unrelated CA, an empty store"
WORK="$(mktemp -d "${M260_TMP:-${TMPDIR:-/tmp}}/m260.XXXXXX")"
trap cleanup EXIT
for ca in "${WORK}" "${WORK}/wrong"; do
  mkdir -p "${ca}"
  TRACK_BINOCLE_CERT_DIR="${ca}" MINI_BAAS_WAF_TLS_GID=none GROBASE_PUBLIC_ADDRESSES='' \
    sh "${ROOT}/scripts/certs/generate-localhost-cert.sh" >/dev/null
done
TRACK_BINOCLE_CERT_DIR="${WORK}" ENGINE_TLS_CERT_DIR="${WORK}/redis" \
  sh "${ROOT}/scripts/certs/generate-engine-cert.sh" redis >/dev/null
[[ -s "${WORK}/redis/ca.pem" && -s "${WORK}/wrong/track-binocle-local-ca.pem" ]] || fail "a CA was not written"
: >"${WORK}/empty.pem"
# The CA keys are spent once the cert is signed; the toolchain mount never needs them.
rm -f "${WORK}/track-binocle-local-ca-key.pem" "${WORK}/wrong/track-binocle-local-ca-key.pem"
ok "redis cert (SANs redis, mini-baas-redis, localhost) under a CA that dies with this run"

step "3/5 boot redis behind the G5b overlay (project ${PROJECT}; ${CONTAINER} is not a SAN)"
printf 'services:\n  redis:\n    container_name: %s\n    ports: !reset []\n' "${CONTAINER}" >"${WORK}/rename.yml"
[[ -z "${M260_IMAGE:-}" ]] || printf '    image: %s\n' "${M260_IMAGE}" >>"${WORK}/rename.yml"
export ENGINE_TLS_REDIS_CERT_DIR="${WORK}/redis"
if ! dc up -d --wait --wait-timeout 120 --no-build --pull missing redis >"${WORK}/up.log" 2>&1; then
  tail -5 "${WORK}/up.log" >&2
  docker logs --tail 10 "${CONTAINER}" >&2 2>&1 || true
  fail "redis with the engine cert did not become healthy"
fi
[[ "$(docker exec "${CONTAINER}" redis-cli CONFIG GET tls-port | tail -1)" == 6380 ]] ||
  fail "redis is not serving TLS on 6380"
ok "redis up: TLS on 6380, plaintext on 6379, nothing published"

step "4/5 the clients, in a --features dynamodb build (ring + aws-lc-rs)"
cargo_proof "pool rediss live" 5 cargo test -p data-plane-pool --features dynamodb \
  --test rediss_live -- --ignored --test-threads=1 --nocapture
cargo_proof "pool provider (R5)" 1 cargo test -p data-plane-pool --features dynamodb \
  --test rediss_provider
cargo_proof "server honor-set link" 1 cargo test -p data-plane-server --features dynamodb \
  --lib redis_link::tests::the_honor_set_refreshes_over_rediss -- --ignored --exact --nocapture

step "5/5 done"
printf '\033[0;32m[M260] ALL GATES GREEN — rediss:// verifies with the CA, refuses a wrong CA and an unlisted name, plaintext 6379 unchanged, no provider panic\033[0m\n'
