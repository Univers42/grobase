#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m184-realtime-listen-reconnect.sh — the LISTEN must survive PostgreSQL      #
#                                                                              #
#  The realtime PG producer opened a LISTEN exactly once. When PostgreSQL was  #
#  recreated the connection ended, the listener task returned, its sender      #
#  dropped, and the server's consumer loop finished WITH NO LOG LINE while the #
#  process carried on serving WebSockets. Subscribers connected, every         #
#  container reported healthy, and no row change was ever delivered again.     #
#  The documented remedy was `docker restart mini-baas-realtime`, by hand,     #
#  after someone noticed — which is the definition of healthy-but-wrong.       #
#                                                                              #
#  This gate starts a THROWAWAY PostgreSQL, attaches the real producer to it,  #
#  proves a notification is delivered, then terminates the producer's backend  #
#  server-side — what recreating the container does to a LISTEN — and proves   #
#  delivery RESUMES. Against the old one-shot producer the sender is dropped   #
#  the instant the connection dies, so nothing is ever delivered again and     #
#  this gate fails.                                                            #
#                                                                              #
#  Its own container, network and volume, all removed by an EXIT trap. It      #
#  never touches a mini-baas-* container and never reads the live stack.       #
# **************************************************************************** #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)" # scripts/verify -> repo root
RT_DIR="${ROOT}/infra/docker/services/realtime/realtime-agnostic"

PG_IMAGE="${M184_PG_IMAGE:-postgres:16-alpine}"
TOOLCHAIN="${M184_TOOLCHAIN:-mini-baas-rust-toolchain}"
PGPW="m184"
NAME="m184-pg-$$"
NET="m184-net-$$"
OUT="$(mktemp)"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M184] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M184] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

cleanup() {
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  rm -f "${OUT}" 2>/dev/null || true
}
trap cleanup EXIT

step "0/4 preconditions"
command -v docker >/dev/null 2>&1 || fail "docker is required"
[ -d "${RT_DIR}" ] || fail "realtime workspace not found at ${RT_DIR}"
docker image inspect "${TOOLCHAIN}" >/dev/null 2>&1 ||
  fail "toolchain image ${TOOLCHAIN} missing — run 'make _rust-toolchain' first"
ok "docker, realtime workspace and the cargo toolchain image are present"

step "1/4 start a throwaway PostgreSQL (its own network, alias 'postgres')"
docker network create "${NET}" >/dev/null
docker run -d --name "${NAME}" --network "${NET}" --network-alias postgres \
  -e POSTGRES_PASSWORD="${PGPW}" -e POSTGRES_USER=postgres -e POSTGRES_DB=postgres \
  "${PG_IMAGE}" >/dev/null
deadline=$((SECONDS + 120))
# -h, not the socket: the initdb temporary server answers the socket while no
# dependent can connect over the network (see m183).
until docker exec "${NAME}" pg_isready -h 127.0.0.1 -U postgres -d postgres >/dev/null 2>&1; do
  [ "${SECONDS}" -lt "${deadline}" ] || fail "throwaway postgres never accepted TCP within 120s"
  sleep 1
done
ok "postgres up and accepting TCP"

step "2/4 run the producer against it, kill its backend, require delivery to resume"
if ! docker run --rm --network "${NET}" \
  -v "${RT_DIR}":/work -w /work \
  -v mini-baas-cargo-registry:/usr/local/cargo/registry \
  -v mini-baas-cargo-git:/usr/local/cargo/git \
  -v mini-baas-realtime-target:/work/target \
  -e REALTIME_PG_TEST_DSN="host=postgres user=postgres password=${PGPW} dbname=postgres" \
  "${TOOLCHAIN}" cargo test -p realtime-db-postgres --test reconnect -- --ignored --nocapture \
  >"${OUT}" 2>&1; then
  sed 's/^/    /' "${OUT}" | tail -30
  fail "the reconnect proof failed — the LISTEN did not re-attach after the backend was terminated"
fi
ok "delivery resumed after the producer's backend was terminated"

step "3/4 the run must not have been vacuous"
# `cargo test` exits 0 when it runs ZERO tests, so a renamed or filtered-out
# case would look exactly like a pass. Require the case to have actually run.
grep -qE 'test result: ok\. 1 passed' "${OUT}" ||
  fail "expected exactly 1 test to run and pass; cargo reported: $(grep -m1 'test result' "${OUT}" || echo 'no test result line at all')"
ok "1 test ran and passed (not a zero-test green)"

step "4/4 done"
printf '\033[0;32m[M184] ALL GATES GREEN — the PostgreSQL LISTEN re-attaches after the connection dies; delivery resumes without a restart\033[0m\n'
