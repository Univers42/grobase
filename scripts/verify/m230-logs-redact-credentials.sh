#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m230-logs-redact-credentials.sh — no service writes a credential header   #
#  into its request log                                                       #
#                                                                              #
#  pino-http serialises every request header into each line a request logs,  #
#  and promtail ships those lines to Loki. On 2026-10-15 query-router's log   #
#  on the b2b VM held request #1041's raw `authorization: Bearer <JWT>` and   #
#  its raw `apikey` JWT: the shared createPinoHttpOptions had no redact, and  #
#  all 13 NestJS apps build their logger from it.                             #
#                                                                              #
#  So createPinoHttpOptions censors seven serialised paths with [REDACTED],  #
#  and this gate holds the two things that keep that true: the shared config #
#  still lists every path, and no service builds pino or pino-http anywhere   #
#  else, where the redact would not reach.                                    #
#                                                                              #
#  Arms: SHARED (every path, censored [REDACTED]) ·                           #
#         ROUTED (every LoggerModule.forRoot takes createPinoHttpOptions; no  #
#                 other pinoHttp key, no other pino/pino-http import) ·       #
#         PROOF (logger.spec.ts exercises every header the paths name) ·     #
#         CANARY (the canary-password tests of the Go registry, the Rust     #
#                 pool and the TS filter exist; CI's test jobs run them).    #
#                                                                              #
#  Static only: no network, no stack, no credential read, no value printed.  #
#  The runtime proof is the jest spec: src/libs/common/src/observability/    #
#  logger.spec.ts.                                                            #
#                                                                              #
# **************************************************************************** #
set -uo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOGGER_REL="src/libs/common/src/observability/logger.ts"
LOGGER="${ROOT}/${LOGGER_REL}"
SPEC="${ROOT}/src/libs/common/src/observability/logger.spec.ts"

_B=$'\033[0;36m' _G=$'\033[0;32m' _R=$'\033[0;31m' _Y=$'\033[0;33m' _0=$'\033[0m'
rc=0
step() { printf '%s[M230] %s%s\n' "${_B}" "$1" "${_0}"; }
ok() { printf '%s  ✓ %s%s\n' "${_G}" "$1" "${_0}"; }
fail() {
  printf '%s[M230] FAIL — %s%s\n' "${_R}" "$1" "${_0}"
  rc=1
}

# skipped IS not passed: a check that could not run leaves the gate red.
skip() {
  printf '%s[M230] SKIP — %s%s\n' "${_Y}" "$1" "${_0}"
  rc=1
}

for f in "${LOGGER}" "${SPEC}"; do
  [ -f "${f}" ] || {
    fail "missing ${f#"${ROOT}"/}"
    exit 1
  }
done

# The paths pino-http serialises the credential headers to (Node lowercases
# incoming names, so one spelling covers every client casing).
PATHS=(
  'req.headers.authorization'
  'req.headers.apikey'
  'req.headers["x-baas-api-key"]'
  'req.headers["x-service-token"]'
  'req.headers["x-service-auth"]'
  'req.headers.cookie'
  'res.headers["set-cookie"]'
)

# The one form a service may build its request logger with.
SHARED_FORM='pinoHttp: \[?createPinoHttpOptions\('

# header_of <path> — the header a path censors: req.headers["x-a"] -> x-a.
header_of() {
  local h="${1#*.headers}"
  h="${h#.}"
  h="${h#\[\"}"
  printf '%s\n' "${h%\"\]}"
}

# src_grep <ERE> — every tracked or untracked-not-ignored JS/TS file in the repo
# (Deno services and scripts included), as file:line:text.
# ponytail: a regex over source, not a module graph — an import split across
# lines or built from a variable is missed; the jest spec is the runtime proof.
src_grep() {
  git -C "${ROOT}" grep --untracked -n -E "$1" -- \
    '*.ts' '*.tsx' '*.js' '*.mjs' '*.cjs' ':!src/coverage' 2>/dev/null
}

shared_arm() {
  step "SHARED — createPinoHttpOptions censors every credential path with [REDACTED]"
  local block p missing=""
  block="$(awk '/^const CREDENTIAL_PATHS/ {p=1} p {print} p && /^\];/ {exit}' "${LOGGER}")"
  for p in "${PATHS[@]}"; do
    printf '%s\n' "${block}" | grep -qxF -- "  '${p}'," || missing="${missing} ${p}"
  done
  [ -z "${missing}" ] && ok "CREDENTIAL_PATHS lists all ${#PATHS[@]} paths" ||
    fail "CREDENTIAL_PATHS in ${LOGGER_REL} does not list:${missing}"
  grep -qxF "    redact: { paths: [...CREDENTIAL_PATHS], censor: '[REDACTED]' }," "${LOGGER}" &&
    ok "the returned options pass CREDENTIAL_PATHS to redact, censor [REDACTED]" ||
    fail "createPinoHttpOptions no longer passes CREDENTIAL_PATHS to redact with censor [REDACTED]"
}

# routed_arm — git grep, so a checkout without git cannot read as clean.
routed_arm() {
  step "ROUTED — no service builds its request logger outside createPinoHttpOptions"
  local roots off_root pino_keys imports
  if ! git -C "${ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    skip "not a git work tree — the services cannot be listed, so this gate cannot claim PASS"
    return
  fi
  roots="$(src_grep 'LoggerModule\.forRoot')"
  if [ -z "${roots}" ]; then
    fail "no LoggerModule.forRoot found — the scan is not looking at the services"
    return
  fi
  off_root="$(printf '%s\n' "${roots}" | grep -vE "LoggerModule\.forRoot\(\{ ${SHARED_FORM}")"
  [ -z "${off_root}" ] &&
    ok "$(printf '%s\n' "${roots}" | wc -l | tr -d ' ') LoggerModule.forRoot calls, all { pinoHttp: createPinoHttpOptions(...) }" ||
    fail "a logger built another way (forRootAsync, spread, own options): ${off_root}"
  pino_keys="$(src_grep 'pinoHttp[[:space:]]*:' | grep -vE "${SHARED_FORM}")"
  [ -z "${pino_keys}" ] && ok "every pinoHttp key is createPinoHttpOptions(...)" ||
    fail "a pinoHttp option not built by createPinoHttpOptions: ${pino_keys}"
  imports="$(src_grep "(from|require\(|import\()[[:space:]]*['\"](npm:)?(pino|pino-http)(@[^'\"]*)?['\"]" |
    grep -vF "${LOGGER_REL}:")"
  [ -z "${imports}" ] && ok "pino and pino-http are imported by ${LOGGER_REL} alone" ||
    fail "a service imports pino or pino-http directly, out of the redact's reach: ${imports}"
}

# proof_arm — ponytail: reads the spec's text, not its run, so a header named
# only in a comment passes here; jest running logger.spec.ts is the proof.
proof_arm() {
  step "PROOF — logger.spec.ts exercises every header the paths name"
  local p h missing=""
  for p in "${PATHS[@]}"; do
    h="$(header_of "${p}")"
    grep -qE "(^|[^a-z-])'?${h}'?:|'${h}'\]" "${SPEC}" || missing="${missing} ${h}"
  done
  [ -z "${missing}" ] && ok "each of the ${#PATHS[@]} headers is sent or set by the spec" ||
    fail "logger.spec.ts never sends or sets:${missing}"
  grep -qF "createPinoHttpOptions(" "${SPEC}" && grep -qF "'[REDACTED]'" "${SPEC}" &&
    grep -qF "'x-request-id'" "${SPEC}" &&
    ok "the spec logs through createPinoHttpOptions, expects [REDACTED], and keeps x-request-id" ||
    fail "logger.spec.ts no longer logs through the shared config or asserts the censor"
}

# canary_arm — Caveat: proves the tests exist, not that they pass; go test,
# cargo test --workspace and jest in CI are the runtime proof.
canary_arm() {
  step "CANARY — a DSN password reaches no error body or log line (Go, Rust, TS)"
  local pair file needle missing=""
  for pair in \
    "src/control-plane/internal/adapterregistry/internal_error_test.go|func TestInternalErrorsHideTheCanaryFromBodyAndLog(" \
    "src/data-plane-router/crates/data-plane-pool/src/canary.rs|async fn a_refused_dial_never_repeats_the_password()" \
    "src/data-plane-router/crates/data-plane-pool/src/lib.rs|mod canary;" \
    "src/data-plane-router/crates/data-plane-pool/src/http/pool.rs|fn an_error_quotes_the_url_without_its_userinfo()" \
    "src/libs/common/src/observability/redact-dsn.spec.ts|describe('redactDsn'" \
    "src/libs/common/src/filters/all-exceptions.filter.spec.ts|describe('DSN redaction'" \
    "src/libs/common/src/filters/all-exceptions.filter.ts|redactDsn("; do
    file="${pair%%|*}" needle="${pair#*|}"
    grep -qF -- "${needle}" "${ROOT}/${file}" 2>/dev/null || missing="${missing} ${file}:${needle}"
  done
  [ -z "${missing}" ] && ok "7 canary anchors present across the registry, the pool and the filter" ||
    fail "a canary test or its wiring is gone:${missing}"
}

shared_arm
routed_arm
proof_arm
canary_arm

if [ "${rc}" -eq 0 ]; then
  printf '%s[M230] PASS — every request log is built by createPinoHttpOptions, which censors all %s credential paths%s\n' "${_G}" "${#PATHS[@]}" "${_0}"
else
  printf '%s[M230] FAIL%s\n' "${_R}" "${_0}"
fi
exit "${rc}"
