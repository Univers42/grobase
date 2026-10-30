#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m258-realtime-pg-tls.sh — realtime's LISTEN rides TLS when the DSN asks     #
#                                                                              #
#  The realtime PG producer dialled every DSN with NoTls, so it was the one    #
#  Postgres client that could not survive a server refusing plaintext (G5c,    #
#  docs/adr/0014-g5c-realtime-pg-tls-connector.md, R-TLS1–12).                 #
#                                                                              #
#  This gate mints a THROWAWAY CA and engine cert, starts a throwaway          #
#  PostgreSQL behind the G5a engine-TLS entrypoint, and runs the real          #
#  producer against it: sslmode=require and sslmode=verify-full + the CA must  #
#  attach with pg_stat_ssl.ssl = true for the producer's own backend and       #
#  deliver a NOTIFY; verify-full to a host name outside the certificate must   #
#  be refused with NO plaintext fallback. Then fmt, clippy -D warnings and the #
#  parser unit tests.                                                          #
#                                                                              #
#  Its own container, network and temp dir, all removed by an EXIT trap. It    #
#  never touches a mini-baas-* container, the live stack or the repo's CA.     #
# **************************************************************************** #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)" # scripts/verify -> repo root
RT_DIR="${ROOT}/infra/docker/services/realtime/realtime-agnostic"
ENTRYPOINT="${ROOT}/infra/docker/services/postgres/engine-tls-entrypoint.sh"

PG_IMAGE="${M258_PG_IMAGE:-postgres:16-alpine}"
TOOLCHAIN="${M258_TOOLCHAIN:-mini-baas-rust-toolchain}"
PGPW="m258"
NAME="m258-pg-$$"
NET="m258-net-$$"
WORK="$(mktemp -d)"
OUT="${WORK}/cargo.out"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M258] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M258] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

cleanup() {
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  rm -rf "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

toolchain() { # the cargo toolchain on the throwaway network; extra docker args first
  docker run --rm --network "${NET}" \
    -v "${RT_DIR}":/work -w /work \
    -v mini-baas-cargo-registry:/usr/local/cargo/registry \
    -v mini-baas-cargo-git:/usr/local/cargo/git \
    -v mini-baas-realtime-target:/work/target \
    "$@"
}

step "0/5 preconditions"
command -v docker >/dev/null 2>&1 || fail "docker is required"
[ -d "${RT_DIR}" ] || fail "realtime workspace not found at ${RT_DIR}"
[ -f "${ENTRYPOINT}" ] || fail "G5a engine-TLS entrypoint not found at ${ENTRYPOINT}"
docker image inspect "${TOOLCHAIN}" >/dev/null 2>&1 ||
  fail "toolchain image ${TOOLCHAIN} missing — run 'make _rust-toolchain' first"
ok "docker, realtime workspace, the G5a entrypoint and the cargo toolchain image are present"

step "1/5 mint a throwaway CA + postgres engine cert (never the repo CA)"
TRACK_BINOCLE_CERT_DIR="${WORK}" MINI_BAAS_WAF_TLS_GID=none GROBASE_PUBLIC_ADDRESSES='' \
  sh "${ROOT}/scripts/certs/generate-localhost-cert.sh" >/dev/null
TRACK_BINOCLE_CERT_DIR="${WORK}" ENGINE_TLS_CERT_DIR="${WORK}/engines" \
  sh "${ROOT}/scripts/certs/generate-engine-cert.sh" postgres >/dev/null
for f in engine.pem engine-key.pem ca.pem; do
  [ -s "${WORK}/engines/${f}" ] || fail "generate-engine-cert.sh did not write ${f}"
done
ok "engine cert with the postgres SANs, signed by a CA that dies with this run"

step "2/5 start a TLS PostgreSQL (alias 'postgres' is a SAN, 'pg-unlisted' is not)"
docker network create "${NET}" >/dev/null
docker run -d --name "${NAME}" --network "${NET}" \
  --network-alias postgres --network-alias pg-unlisted \
  -e POSTGRES_PASSWORD="${PGPW}" -e POSTGRES_USER=postgres -e POSTGRES_DB=postgres \
  -v "${WORK}/engines":/etc/engine-tls:ro \
  -v "${ENTRYPOINT}":/usr/local/bin/engine-tls-entrypoint.sh:ro \
  --tmpfs /run/engine-tls:mode=0700 \
  --entrypoint /bin/sh "${PG_IMAGE}" /usr/local/bin/engine-tls-entrypoint.sh postgres >/dev/null
deadline=$((SECONDS + 120))
# -h, not the socket: the initdb temporary server answers the socket while no
# dependent can connect over the network (see m183).
until docker exec "${NAME}" pg_isready -h 127.0.0.1 -U postgres -d postgres >/dev/null 2>&1; do
  [ "${SECONDS}" -lt "${deadline}" ] || fail "throwaway TLS postgres never accepted TCP within 120s"
  sleep 1
done
[ "$(docker exec "${NAME}" psql -U postgres -tAc 'SHOW ssl')" = on ] || fail "SHOW ssl is not on"
ok "postgres up, ssl = on"

step "3/5 the producer over require, verify-full + CA, and a refused bad SAN"
if ! toolchain -v "${WORK}/engines/ca.pem":/etc/m258-ca.pem:ro \
  -e REALTIME_PG_TLS_TEST_DSN="host=postgres user=postgres password=${PGPW} dbname=postgres" \
  -e REALTIME_PG_TLS_TEST_UNLISTED_HOST_DSN="host=pg-unlisted user=postgres password=${PGPW} dbname=postgres" \
  -e REALTIME_PG_TLS_CA_FILE=/etc/m258-ca.pem \
  "${TOOLCHAIN}" cargo test -p realtime-db-postgres --test tls -- --ignored --nocapture --test-threads=1 \
  >"${OUT}" 2>&1; then
  sed 's/^/    /' "${OUT}" | tail -40
  fail "the TLS proof failed"
fi
# `cargo test` exits 0 when it runs ZERO tests, so a renamed or filtered-out
# case would look exactly like a pass.
grep -qE 'test result: ok\. 3 passed' "${OUT}" ||
  fail "expected exactly 3 tests to run and pass; cargo reported: $(grep -m1 'test result' "${OUT}" || echo 'no test result line at all')"
grep -oE "(require|verify-full): backend ssl=true.*|refused as expected.*" "${OUT}" | sed "s/^/    /" || true
ok "require + verify-full attach encrypted and deliver; the unlisted host is refused, no plaintext fallback"

step "4/5 fmt --check, clippy -D warnings, the sslmode parser unit tests"
# rust:1-bookworm (the CI toolchain) ships neither component; the local image does.
if ! toolchain "${TOOLCHAIN}" sh -c '{ cargo clippy --version && cargo fmt --version; } >/dev/null 2>&1 ||
  rustup component add clippy rustfmt >/dev/null 2>&1
  cargo fmt --all -- --check &&
  cargo clippy -p realtime-db-postgres --all-targets -- -D warnings &&
  cargo test -p realtime-db-postgres --lib' >"${OUT}" 2>&1; then
  sed 's/^/    /' "${OUT}" | tail -40
  fail "fmt, clippy or the unit tests failed"
fi
grep -qE 'test result: ok\. [1-9][0-9]* passed' "${OUT}" || fail "the lib unit tests ran zero tests"
ok "fmt clean, clippy clean, $(grep -m1 -oE '[0-9]+ passed' "${OUT}") unit tests"

step "5/5 done"
printf '\033[0;32m[M258] ALL GATES GREEN — realtime LISTEN negotiates TLS on require / verify-full and refuses an unverified host without falling back\033[0m\n'
