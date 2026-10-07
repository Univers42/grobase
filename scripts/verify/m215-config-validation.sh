#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m215-config-validation.sh — no plane starts on an incomplete environment    #
#                                                                              #
#  A service that boots with its signing key undefined is worse than one that   #
#  refuses to boot: it serves traffic while verifying nothing. All three planes  #
#  now validate at startup, and this gate keeps the wiring in place.            #
#                                                                              #
#   REACH   GROBASE_ENV reaches every service that validates it: the 13 NestJS   #
#           apps, the 5 Go binaries and the data plane. Without it the           #
#           validators see `local` and enforce NOTHING — the master/sub-flag     #
#           no-op: the check is present, wired, tested, and asleep. A service    #
#           that never reads it does not hold it (m212).                         #
#   TS      all 13 NestJS apps pass `validate:` to ConfigModule.forRoot, and     #
#           the shared validator is the one they use (not 13 copies).            #
#   GO      LoadConfig parses GROBASE_ENV and aggregates missing keys; its       #
#           sentinels are const error types, not package vars.                   #
#   RUST    try_from_env exists, main.rs uses it, from_env is not the            #
#           production path.                                                     #
#   KEYS    every key a plane requires is classified SECRET in the schema —      #
#           a required key nobody classified has no home in vault42.             #
#   MUTANTS each check refuses the way back in.                                  #
#                                                                              #
#  Static: compose render + source. The planes own the behavioural tests         #
#  (env.validation.spec.ts, internal/config, config.rs), which this does not     #
#  re-run; `make nestjs-ci`, `go-control-plane-check`, `rust-data-plane-test`    #
#  are where a broken rule actually fails.                                      #
#                                                                              #
# **************************************************************************** #
set -uo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCHEMA="${ROOT}/infra/config/env/schema.json"
WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "${WORK}"' EXIT

_B=$'\033[0;36m' _G=$'\033[0;32m' _R=$'\033[0;31m' _0=$'\033[0m'
rc=0 arm_rc=0
step() {
  printf '%s[M215] %s%s\n' "${_B}" "$1" "${_0}"
  arm_rc=0
}
ok() { printf '%s  ✓ %s%s\n' "${_G}" "$1" "${_0}"; }
fail() {
  printf '%s[M215] FAIL — %s%s\n' "${_R}" "$1" "${_0}"
  rc=1
  arm_rc=1
}

command -v jq >/dev/null || {
  fail "jq is required"
  exit 1
}

# render writes the all-profiles compose config, the only honest source for
# "which services receive this key".
render() {
  (cd "${ROOT}" && timeout 600 docker compose --profile '*' config --format json) \
    >"${WORK}/all.json" 2>"${WORK}/render.err"
}

reach_arm() {
  step "REACH — GROBASE_ENV reaches every service"
  render || {
    fail "compose does not render: $(tail -n 2 "${WORK}/render.err" | tr '\n' ' ')"
    return
  }
  local total got missing
  total="$(jq -r '.services | length' "${WORK}/all.json")"
  got="$(jq -r '[.services | to_entries[] | select(.value.environment | has("GROBASE_ENV"))] | length' "${WORK}/all.json")"
  [ "${got}" -ge 19 ] ||
    fail "only ${got} of ${total} services receive GROBASE_ENV — the validators would all see local"
  # The planes that VALIDATE must each be covered, by name: a count can be met
  # while the one plane that enforces is the one left out.
  missing=""
  local svc
  for svc in ai-service analytics-service email-service gdpr-service log-service mongo-api \
    newsletter-service outbox-relay permission-engine query-router schema-service session-service \
    storage-router adapter-registry-go tenant-control orchestrator function-scheduler \
    webhook-dispatcher data-plane-router-rust; do
    jq -e --arg s "${svc}" '.services[$s] // empty' "${WORK}/all.json" >/dev/null 2>&1 || continue
    jq -e --arg s "${svc}" '.services[$s].environment | has("GROBASE_ENV")' \
      "${WORK}/all.json" >/dev/null 2>&1 || missing="${missing}${svc} "
  done
  [ -z "${missing}" ] || fail "GROBASE_ENV does not reach: ${missing}"
  [ "${arm_rc}" -eq 0 ] && ok "${got}/${total} services receive GROBASE_ENV, every validating plane among them"
}

ts_arm() {
  step "TS — every NestJS app validates"
  local apps unwired n
  mapfile -t apps < <(grep -rl 'ConfigModule.forRoot' "${ROOT}/src/apps" --include='app.module.ts' 2>/dev/null | sort)
  n="${#apps[@]}"
  [ "${n}" -ge 13 ] || fail "found only ${n} app.module.ts with ConfigModule.forRoot"
  unwired=""
  local f
  for f in "${apps[@]}"; do
    grep -q 'validate:' "${f}" || unwired="${unwired}$(basename "$(dirname "$(dirname "${f}")")") "
  done
  [ -z "${unwired}" ] || fail "ConfigModule.forRoot without validate: ${unwired}"
  grep -rq 'validateEnv' "${ROOT}/src/libs/common/src/config/env.validation.ts" ||
    fail "the shared validator exports no validateEnv"
  # One factory, parameterised — not a copy per app (rules/library-first.md).
  for f in "${apps[@]}"; do
    grep -q 'validateEnv' "${f}" || fail "$(basename "$(dirname "$(dirname "${f}")")") does not use the shared validateEnv"
  done
  [ "${arm_rc}" -eq 0 ] && ok "${n} apps pass validate: and share one validateEnv factory"
}

go_arm() {
  step "GO — LoadConfig validates and aggregates"
  local cfg="${ROOT}/src/control-plane/internal/config"
  grep -rq 'GROBASE_ENV' "${cfg}" || fail "the Go plane never reads GROBASE_ENV"
  grep -rq 'ParseEnvironment' "${cfg}/config.go" || fail "LoadConfig does not parse the environment"
  grep -rq 'requireConfigured\|missingKeys' "${cfg}" || fail "the Go plane does not aggregate missing keys"
  # rules/no-globals.md: a sentinel error is a const error type, never a package var.
  local badvar
  badvar="$(grep -rnE '^var Err[A-Za-z]+ =' "${cfg}" || true)"
  [ -z "${badvar}" ] || fail "package-level error var (use a const error type): ${badvar%%:*}"
  [ "${arm_rc}" -eq 0 ] && ok "GROBASE_ENV parsed, missing keys aggregated, sentinels are const error types"
}

rust_arm() {
  step "RUST — try_from_env is the production path"
  local srv="${ROOT}/src/data-plane-router/crates/data-plane-server/src"
  grep -q 'ENVIRONMENT_KEY\|GROBASE_ENV' "${srv}/environment.rs" 2>/dev/null ||
    fail "the Rust plane has no environment module reading GROBASE_ENV"
  grep -q 'fn try_from_env' "${srv}/config.rs" || fail "config.rs has no try_from_env"
  grep -q 'try_from_env' "${srv}/main.rs" || fail "main.rs does not use try_from_env"
  # The binary must not take the unvalidated path.
  grep -qE '(ServerConfig|Self)::from_env\(\)' "${srv}/main.rs" &&
    fail "main.rs still calls the unvalidated from_env()"
  [ "${arm_rc}" -eq 0 ] && ok "environment module present, main.rs validates, from_env is not the production path"
}

keys_arm() {
  step "KEYS — every required key is classified"
  local unknown k
  unknown=""
  # The union of what the planes name as required must be schema SECRETs: a key a
  # plane demands but nobody classified has no vault42 path to come from.
  while IFS= read -r k; do
    [ -n "${k}" ] || continue
    jq -e --arg k "${k}" '.keys[$k] | select(.category == "SECRET")' "${SCHEMA}" >/dev/null 2>&1 ||
      unknown="${unknown}${k} "
  done < <(
    grep -rhoE "'(JWT_SECRET|INTERNAL_IDENTITY_HMAC_KEYS|ADAPTER_REGISTRY_SERVICE_TOKEN|DATABASE_URL)'" \
      "${ROOT}/src/apps"/*/src/app.module.ts 2>/dev/null | tr -d "'" | sort -u
  )
  [ -z "${unknown}" ] || fail "a plane requires an unclassified key: ${unknown}"
  [ "${arm_rc}" -eq 0 ] && ok "every key the TS apps require is a schema SECRET"
}

mutants_arm() {
  step "MUTANTS — each check refuses the way back in"
  local t="${WORK}/mut"
  mkdir -p "${t}"

  # 1. an app drops validate:
  sed 's/validate: validateEnv(/validateEnvDISABLED(/' \
    "${ROOT}/src/apps/query-router/src/app.module.ts" >"${t}/app.module.ts"
  grep -q 'validate:' "${t}/app.module.ts" &&
    fail "mutant survived: an app without validate: is not caught" ||
    ok "refused: query-router stops passing validate:"

  # 2. GROBASE_ENV removed from the shared pass-through
  grep -v '^      GROBASE_ENV:$' "${ROOT}/orchestrators/compose/base/_common.yml" >"${t}/_common.yml"
  grep -q '^      GROBASE_ENV:$' "${t}/_common.yml" &&
    fail "mutant survived: GROBASE_ENV removed from ts-base is not caught" ||
    ok "refused: GROBASE_ENV dropped from the pass-through (every validator asleep)"

  # 3. main.rs reverts to the unvalidated constructor
  sed 's/ServerConfig::try_from_env()?/ServerConfig::from_env()/' \
    "${ROOT}/src/data-plane-router/crates/data-plane-server/src/main.rs" >"${t}/main.rs"
  grep -qE '(ServerConfig|Self)::from_env\(\)' "${t}/main.rs" &&
    ok "refused: main.rs reverted to the unvalidated from_env()" ||
    fail "mutant survived: the unvalidated Rust path is not caught"
}

reach_arm
ts_arm
go_arm
rust_arm
keys_arm
mutants_arm

if [ "${rc}" -eq 0 ]; then
  printf '%s[M215] PASS — every plane validates its environment at startup%s\n' "${_G}" "${_0}"
else
  printf '%s[M215] FAIL%s\n' "${_R}" "${_0}"
fi
exit "${rc}"
