#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m210-jwt-dual-key.sh — every JWT verifier that can take the previous        #
#  secret gets it, every other JWT secret site is named, and the rotation      #
#  scripts refuse to do what the stack cannot survive (G-Rotate, JWT half).    #
#                                                                              #
#  COMPOSE  renders base (every profile) and base + prod + netseg from a copy  #
#           of the compose tree, with sentinels: the interpolation env holds   #
#           JWT_SECRET/JWT_SECRET_PREV, the tree's .env (what env_file loads)  #
#           holds different ones, so a value says how it arrived. Every        #
#           service/key interpolated from JWT_SECRET must be classified        #
#           (verify+prev, or a named single-key site); every verify+prev       #
#           service gets the previous secret, and no other service does;       #
#           with JWT_SECRET_PREV unset each one gets "" (parity).              #
#  SOURCE   every read of a JWT secret variable under src/, infra/, deploy/    #
#           and scripts/{env,lib,ops,secrets,seed} is in a classified file,    #
#           and each verify+prev file reads its _PREV variable.                #
#  ROTATION rotate-jwt.sh and rotate-secrets.sh jwt refuse without             #
#           ROTATE_JWT_FORCE=1 and change nothing; forced, rotate-jwt.sh       #
#           writes JWT_SECRET_PREV (the name the verifiers read).              #
#  MUTANTS  a verifier losing its _PREV, a new service holding JWT_SECRET,     #
#           and a new source file reading it are each refused.                 #
#  The dual-accept itself is proven by unit tests: Go jwt_prev_test.go, TS     #
#  user-jwt.spec.ts, Rust realtime-auth previous_secret_tests.rs. No stack.    #
#                                                                              #
#  Ponytail: SOURCE is a regex over the usual env-read forms (Getenv, envFirst, #
#  process.env, config.get, env::var, ${VAR}). A secret read through a        #
#  computed name or a config file slips past it (under-reports).              #
#  Ponytail: the service-token fallback to JWT_SECRET is not classified here:  #
#  the render sets ADAPTER_REGISTRY_SERVICE_TOKEN as generate-env.sh does. A   #
#  .env without it rotates the service token along with JWT_SECRET.           #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M210] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M210] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
TREE="${WORK}/tree"
TS_VERIFIERS="query-router email-service storage-router permission-engine schema-service \
analytics-service gdpr-service newsletter-service ai-service log-service session-service mongo-api"

# is_verifier succeeds for the services whose verifier accepts a previous secret.
is_verifier() {
  case " tenant-control realtime ${TS_VERIFIERS} " in *" $1 "*) return 0 ;; esac
  return 1
}

# class prints how service $1 uses the JWT secret it holds under key $2, or
# nothing when that pairing is unclassified. single-key: Kong keeps one secret
# per issuer, GoTrue/PostgREST read one, vault42 is an external image.
class() {
  case "$1 $2" in
  "tenant-control GOTRUE_JWT_SECRET" | "realtime REALTIME_JWT_SECRET") echo verify-prev ;;
  "gotrue GOTRUE_JWT_SECRET" | "postgrest PGRST_JWT_SECRET" | "kong JWT_SECRET" | "vault42 JWT_SECRET") echo single-key ;;
  *" JWT_SECRET") case " ${TS_VERIFIERS} " in *" $1 "*) echo verify-prev ;; esac ;;
  esac
}

# prev_key prints the variable verifier $1 reads its previous secret from.
prev_key() { case "$1" in realtime) echo REALTIME_JWT_SECRET_PREV ;; *) echo JWT_SECRET_PREV ;; esac }

# render writes to $1 the JSON config of the copied tree plus compose files
# $3…, interpolated from env file $2 only.
render() {
  local out="$1" envf="$2" args=(-f "${TREE}/docker-compose.yml") f
  shift 2
  for f in "$@"; do args+=(-f "${f}"); done
  env -u JWT_SECRET -u JWT_SECRET_PREV -u ADAPTER_REGISTRY_SERVICE_TOKEN \
    docker compose --project-directory "${TREE}" --env-file "${envf}" "${args[@]}" \
    --profile '*' config --format json >"${out}" 2>"${WORK}/render.err" && return
  tail -n 3 "${WORK}/render.err" | sed 's/^/    /' >&2
  return 1
}

# pairs prints `service key value` for every env entry of config $1 whose value
# is an interpolated sentinel (a value env_file loads is m210-file, and ignored).
pairs() {
  jq -r '.services | to_entries[] | .key as $s | (.value.environment // {}) | to_entries[]
    | select(.value == "m210-cur" or .value == "m210-prev") | "\($s) \(.key) \(.value)"' "$1"
}

# offenders prints one line per defect in pair list $1.
offenders() {
  local svc key val c list
  list="$(cat "$1")"
  while read -r svc key val; do
    if [ "${val}" = m210-prev ]; then
      is_verifier "${svc}" && [ "${key}" = "$(prev_key "${svc}")" ] ||
        echo "${svc}: ${key} holds the previous secret but ${svc} does not verify with it"
      continue
    fi
    c="$(class "${svc}" "${key}")"
    [ -n "${c}" ] || echo "${svc}: ${key} holds JWT_SECRET and is unclassified"
    if [ "${c}" = verify-prev ] && ! grep -qx "${svc} $(prev_key "${svc}") m210-prev" "$1"; then
      echo "${svc}: verifies ${key} but does not get $(prev_key "${svc}")"
    fi
  done <<<"${list}"
}

# stack_defects renders compose files $1… with the previous secret set and
# prints its offenders, or why it could not render.
stack_defects() {
  render "${WORK}/s.json" "${WORK}/with-prev.env" "$@" || {
    echo "does not render"
    return
  }
  pairs "${WORK}/s.json" >"${WORK}/pairs"
  offenders "${WORK}/pairs"
}

# check_stack fails unless compose files $2… have no offender; $1 names the stack.
check_stack() {
  local name="$1" bad n
  shift
  bad="$(stack_defects "$@")"
  [ -z "${bad}" ] || fail "${name}: $(printf '%s' "${bad}" | head -n 4 | paste -sd ';' -)"
  n="$(grep -c ' m210-prev$' "${WORK}/pairs")"
  [ "${n}" -ge 14 ] || fail "${name}: only ${n} services get the previous secret — did compose render?"
  ok "${name}: every JWT_SECRET holder classified; ${n} verifiers get the previous secret, no other service"
}

# setup copies the compose tree and writes the sentinel env files.
setup() {
  mkdir -p "${TREE}/orchestrators"
  cp "${ROOT}/docker-compose.yml" "${TREE}/"
  cp -r "${ROOT}/orchestrators/compose" "${TREE}/orchestrators/"
  printf 'JWT_SECRET=m210-file\n' >"${TREE}/.env"
  printf 'JWT_SECRET=m210-cur\nADAPTER_REGISTRY_SERVICE_TOKEN=m210-svc\n' >"${WORK}/no-prev.env"
  { cat "${WORK}/no-prev.env" && echo 'JWT_SECRET_PREV=m210-prev'; } >"${WORK}/with-prev.env"
}

# compose_checks runs the COMPOSE arm.
compose_checks() {
  local base="${TREE}/orchestrators/compose" left="" svc
  step "COMPOSE — the previous secret reaches exactly the verifiers that read it"
  check_stack base
  check_stack "base + prod + netseg" "${base}/docker-compose.prod.yml" "${base}/docker-compose.netseg.yml"
  render "${WORK}/u.json" "${WORK}/no-prev.env" || fail "base does not render without JWT_SECRET_PREV"
  for svc in tenant-control realtime ${TS_VERIFIERS}; do
    [ "$(jq -r --arg s "${svc}" --arg k "$(prev_key "${svc}")" '.services[$s].environment[$k] // "absent"' \
      "${WORK}/u.json")" = "" ] || left+=" ${svc}"
  done
  [ -z "${left}" ] || fail "JWT_SECRET_PREV unset does not leave the previous secret empty in:${left}"
  ok "JWT_SECRET_PREV unset: every verifier gets an empty previous secret (parity)"
}

# src_class prints how repo file $1 uses a JWT secret, or nothing when unclassified.
src_class() {
  case "$1" in
  src/control-plane/internal/tenants/jwt.go | src/libs/common/src/identity/request-identity.ts | \
    src/libs/common/src/middleware/api-key.middleware.ts | \
    infra/docker/services/realtime/realtime-agnostic/crates/realtime-server/src/main.rs) echo verify-prev ;;
  src/control-plane/cmd/tenant-control/boot.go) echo builds-verifier ;;
  src/control-plane/internal/github/github.go | scripts/env/generate-env.sh | scripts/env/bootstrap-env.mjs | \
    scripts/seed/*.sh) echo sign ;;
  src/control-plane/internal/loginotp/loginotp.go) echo sign-and-single-key ;;
  infra/docker/services/kong/render-kong-config.sh) echo single-key ;;
  infra/docker/services/vault/scripts/init-vault.sh) echo store ;;
  scripts/secrets/rotate-jwt.sh | infra/docker/services/vault/scripts/rotate-secrets.sh) echo rotate ;;
  esac
}

# reads prints, relative to root $1, every file that reads a JWT secret variable.
reads() {
  local x='(GOTRUE_|REALTIME_|PGRST_)?JWT_SECRET(_PREV)?' d dirs=()
  for d in src infra deploy scripts/env scripts/lib scripts/ops scripts/secrets scripts/seed; do
    [ -d "$1/${d}" ] && dirs+=("$1/${d}")
  done
  grep -rlE --exclude-dir={coverage,node_modules,tests,target,dist} \
    --exclude='*.spec.ts' --exclude='*_test.go' --exclude='*tests.rs' --exclude='*.md' \
    -e "Getenv\(\"${x}\"\)|envFirst\([^)]*\"${x}\"|process\.env(\[['\"]|\.)${x}\b" \
    -e "get(<string>)?\(['\"]${x}['\"]|env::var\(\"${x}\"\)|\\\$\{${x}[:}-]|\\\$${x}\b" \
    "${dirs[@]}" | sed "s#^$1/##" | sort -u
}

# unclassified prints every file under root $1 that reads a JWT secret and has no class.
unclassified() {
  local f
  while read -r f; do [ -n "$(src_class "${f}")" ] || echo "${f}"; done < <(reads "$1")
}

# source_checks runs the SOURCE arm.
source_checks() {
  local bad n f
  step "SOURCE — every read of a JWT secret is classified"
  bad="$(unclassified "${ROOT}")"
  [ -z "${bad}" ] || fail "unclassified JWT secret reads: $(printf '%s' "${bad}" | paste -sd ' ' -)"
  n="$(reads "${ROOT}" | wc -l)"
  [ "${n}" -ge 10 ] || fail "only ${n} files read a JWT secret — is the scan broken?"
  for f in $(reads "${ROOT}"); do
    [ "$(src_class "${f}")" != verify-prev ] || grep -q 'JWT_SECRET_PREV' "${ROOT}/${f}" ||
      fail "${f} verifies but never reads its _PREV variable"
  done
  grep -q 'tenants.NewJWTVerifier' "${ROOT}/src/control-plane/cmd/tenant-control/boot.go" ||
    fail "tenant-control no longer builds its verifier with tenants.NewJWTVerifier"
  ok "${n} files read a JWT secret, all classified; every verify+prev file reads its _PREV"
}

# rotation_checks runs the ROTATION arm on a scratch directory with a no-op docker.
rotation_checks() {
  local d="${WORK}/rot" out
  step "ROTATION — the scripts refuse a swap the stack cannot survive"
  mkdir -p "${d}/secrets" "${d}/bin"
  printf 'm210-old' >"${d}/secrets/jwt_secret.txt"
  printf 'JWT_SECRET=m210-old\n' >"${d}/.env"
  printf '#!/bin/sh\nexit 0\n' >"${d}/bin/docker" && chmod +x "${d}/bin/docker"
  if out="$(cd "${d}" && PATH="${d}/bin:${PATH}" bash "${ROOT}/scripts/secrets/rotate-jwt.sh" secrets 2>&1)"; then
    fail "rotate-jwt.sh rotated without ROTATE_JWT_FORCE=1"
  fi
  grep -q ROTATE_JWT_FORCE <<<"${out}" || fail "rotate-jwt.sh refused without naming ROTATE_JWT_FORCE"
  [ "$(cat "${d}/secrets/jwt_secret.txt")" = m210-old ] && [ ! -e "${d}/secrets/jwt_secret_prev.txt" ] &&
    grep -qx 'JWT_SECRET=m210-old' "${d}/.env" || fail "the refused rotate-jwt.sh still changed a file"
  ok "rotate-jwt.sh refuses without ROTATE_JWT_FORCE=1 and changes nothing"
  (cd "${d}" && PATH="${d}/bin:${PATH}" ROTATE_JWT_FORCE=1 bash "${ROOT}/scripts/secrets/rotate-jwt.sh" secrets) \
    >/dev/null 2>&1 || fail "forced rotate-jwt.sh failed"
  grep -qx 'JWT_SECRET_PREV=m210-old' "${d}/.env" || fail "forced rotate-jwt.sh does not write JWT_SECRET_PREV"
  ok "forced, rotate-jwt.sh keeps the old secret as JWT_SECRET_PREV"
  if out="$(VAULT_TOKEN=m210 VAULT_ADDR=http://127.0.0.1:9 \
    bash "${ROOT}/infra/docker/services/vault/scripts/rotate-secrets.sh" jwt 2>&1)"; then
    fail "rotate-secrets.sh jwt rotated without ROTATE_JWT_FORCE=1"
  fi
  grep -q ROTATE_JWT_FORCE <<<"${out}" || fail "rotate-secrets.sh jwt refused without naming ROTATE_JWT_FORCE"
  ok "rotate-secrets.sh jwt refuses without ROTATE_JWT_FORCE=1, before it touches Vault"
}

# mutant writes overlay body $2 and fails unless the compose check refuses it; $1 names it.
mutant() {
  printf 'services:\n%s\n' "$2" >"${WORK}/mutant.yml"
  [ -n "$(stack_defects "${WORK}/mutant.yml")" ] || fail "mutant survived: $1"
  ok "refused: $1"
}

# mutants proves each arm sees the defect it exists for.
mutants() {
  step "MUTANTS — the checks refuse each way out"
  mutant "query-router loses JWT_SECRET_PREV" '  query-router:
    environment:
      JWT_SECRET_PREV: ""'
  mutant "a new service holds JWT_SECRET" '  rogue:
    image: busybox:1.36
    environment:
      JWT_SECRET: ${JWT_SECRET}'
  mutant "kong gets the previous secret" '  kong:
    environment:
      JWT_SECRET_PREV: ${JWT_SECRET_PREV:-}'
  mkdir -p "${WORK}/mut/src"
  printf 'package x\n\nvar _ = os.Getenv("JWT_SECRET")\n' >"${WORK}/mut/src/rogue.go"
  [ "$(unclassified "${WORK}/mut")" = src/rogue.go ] || fail "mutant survived: a new source file reads JWT_SECRET"
  ok "refused: a new source file reads JWT_SECRET"
}

command -v jq >/dev/null || fail "jq is required"
docker compose version >/dev/null 2>&1 || fail "docker compose is required"
setup
compose_checks
source_checks
rotation_checks
mutants
cyan "[M210] PASS"
