#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m212-service-env-scope.sh — platform services get the variables they read,  #
#  not the whole platform .env.                                                #
#                                                                              #
#  `env_file: [.env]` hands a service every secret in .env (service tokens,    #
#  engine passwords, SMTP, MinIO root), so a foothold in it reads them all     #
#  from /proc/1/environ. A scoped service lists what it reads in environment   #
#  (interpolated from .env) and loads only its optional .env.<service>. m211   #
#  covers the engines; this gate covers the platform services in SCOPED.       #
#                                                                              #
#  STATIC   a copy of the compose tree whose .env holds M212_PLATFORM (a key   #
#           only env_file can deliver) and a marker in each service's needed   #
#           key. Rendered with every profile: base, base + each overlay, base  #
#           + fly's override. No scoped service may hold M212_PLATFORM; each   #
#           must still get its needed key from .env.                           #
#  HATCH    a .env.<service> setting reaches the service; M212_PLATFORM not.   #
#  MUTANT   kong given env_file .env again: the check must go red.             #
#  LIVE     each running scoped service's PID 1 holds no .env key that its     #
#           base render does not name. Stack down = SKIP, stated.              #
#                                                                              #
#  Not rendered: docker-compose.monolith.yml (preserved pre-split file) and    #
#  track-binocle (needs pg-meta), as in m211.                                  #
#  Ponytail: only services listed in SCOPED are checked — a service still on   #
#  env_file .env passes silently until it is converted and added here.         #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCOPED="kong"
MARK="m212-marker-$$"
WORK="$(mktemp -d)" || exit 1
TREE="${WORK}/tree"
trap 'rm -rf "${WORK}"' EXIT
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M212] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M212] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

# needed_key prints the .env key service $1 must still receive by interpolation.
needed_key() {
  case "$1" in
  kong) echo KONG_SERVICE_API_KEY ;;
  *) fail "no needed key declared for $1" ;;
  esac
}

# setup copies the compose tree, fly's override and an empty cloud flags file,
# and writes a .env with M212_PLATFORM plus the marker in every needed key.
setup() {
  local svc
  mkdir -p "${TREE}/orchestrators" "${TREE}/deploy/fly" "${TREE}/infra/config/cloud"
  cp "${ROOT}/docker-compose.yml" "${TREE}/"
  cp -r "${ROOT}/orchestrators/compose" "${TREE}/orchestrators/"
  cp "${ROOT}/deploy/fly/compose.override.yml" "${TREE}/deploy/fly/"
  : >"${TREE}/infra/config/cloud/flags.env.cloud"
  printf 'M212_PLATFORM=%s\nJWT_SECRET=m212-jwt\n' "${MARK}" >"${TREE}/.env"
  for svc in ${SCOPED}; do printf '%s=%s\n' "$(needed_key "${svc}")" "${MARK}" >>"${TREE}/.env"; done
}

# render writes to $1 the every-profile config of the tree plus compose files $2…,
# interpolated from the tree's .env only.
render() {
  local out="$1" args=(-f "${TREE}/docker-compose.yml") f
  shift
  for f in "$@"; do args+=(-f "${f}"); done
  env -i PATH="${PATH}" HOME="${HOME}" docker compose --project-directory "${TREE}" "${args[@]}" \
    --profile '*' config --format json >"${out}" 2>"${WORK}/render.err" && return
  fail "render ${*##*/}: $(head -c 300 "${WORK}/render.err")"
}

# check fails when a scoped service in config $1 ($2 names it) is missing, holds
# M212_PLATFORM, or lost its needed key.
check() {
  local svc env
  for svc in ${SCOPED}; do
    env="$(jq -c --arg s "${svc}" '.services[$s].environment // null' "$1")"
    [ "${env}" != null ] || fail "$2: ${svc} is not rendered"
    [ "$(jq -r 'has("M212_PLATFORM")' <<<"${env}")" = false ] || fail "$2: ${svc} loads the platform .env"
    [ "$(jq -r --arg k "$(needed_key "${svc}")" '.[$k] // ""' <<<"${env}")" = "${MARK}" ] ||
      fail "$2: ${svc} no longer receives $(needed_key "${svc}") from .env"
  done
  ok "$2: ${SCOPED} — needed keys only, no platform .env"
}

# static_arm renders base and base + every overlay.
static_arm() {
  local o
  render "${WORK}/base.json"
  check "${WORK}/base.json" base
  for o in "${TREE}"/orchestrators/compose/docker-compose.*.yml "${TREE}/deploy/fly/compose.override.yml"; do
    case "${o##*/}" in docker-compose.monolith.yml | docker-compose.track-binocle.yml) continue ;; esac
    render "${WORK}/o.json" "${o}"
    check "${WORK}/o.json" "base + ${o##*/}"
  done
}

# hatch_arm proves a .env.<service> setting reaches each scoped service.
hatch_arm() {
  local svc
  for svc in ${SCOPED}; do printf 'M212_HATCH=on\n' >"${TREE}/.env.${svc}"; done
  render "${WORK}/hatch.json"
  for svc in ${SCOPED}; do
    [ "$(jq -r --arg s "${svc}" '.services[$s].environment.M212_HATCH // ""' "${WORK}/hatch.json")" = on ] ||
      fail "hatch: a .env.${svc} setting did not reach ${svc}"
    rm -f "${TREE}/.env.${svc}"
  done
  check "${WORK}/hatch.json" "base + .env.<service>"
}

# mutant_arm gives kong env_file .env again; the check must catch it.
mutant_arm() {
  local f="${TREE}/orchestrators/compose/base/gateway.yml"
  cp "${f}" "${WORK}/gateway.yml"
  sed 's|^      - path: \.env\.kong$|      - path: .env|' "${WORK}/gateway.yml" >"${f}"
  cmp -s "${f}" "${WORK}/gateway.yml" && fail "mutant: could not re-add env_file .env to kong"
  render "${WORK}/mutant.json"
  cp "${WORK}/gateway.yml" "${f}"
  [ "$(jq -r '.services.kong.environment | has("M212_PLATFORM")' "${WORK}/mutant.json")" = true ] ||
    fail "mutant: kong with env_file .env passed — the check is vacuous"
  ok "mutant: kong with env_file .env is caught"
}

# live_arm checks each running scoped service: no .env key name in its runtime
# env that its base render (real .env) does not name. Names only, never values.
live_arm() {
  local svc c allowed extra seen=""
  [ -f "${ROOT}/.env" ] || {
    printf '\033[0;33m  - SKIP live: no .env at the repo root\033[0m\n'
    return 0
  }
  docker compose --project-directory "${ROOT}" --profile '*' config --format json >"${WORK}/live.json" 2>/dev/null ||
    fail "live: the repo's compose does not render"
  for svc in ${SCOPED}; do
    c="$(docker ps -q --filter label=com.docker.compose.project=mini-baas \
      --filter "label=com.docker.compose.service=${svc}" | head -n1)"
    [ -n "${c}" ] || continue
    allowed="$(jq -r --arg s "${svc}" '.services[$s].environment // {} | keys[]' "${WORK}/live.json")"
    extra="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${c}" | cut -d= -f1 |
      grep -Fxf <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*' "${ROOT}/.env") | grep -Fxvf <(printf '%s\n' "${allowed}") | tr '\n' ' ')"
    [ -z "${extra}" ] || fail "live ${svc}: holds .env keys it does not read: ${extra}(recreate it: docker compose up -d ${svc})"
    seen="${seen} ${svc}"
  done
  [ -n "${seen}" ] || {
    printf '\033[0;33m  - SKIP live: no scoped service of project mini-baas is running\033[0m\n'
    return 0
  }
  ok "live runtime env:${seen} — only the .env keys the service reads"
}

command -v jq >/dev/null || fail "jq is required"
setup
step "static — base and every overlay, every profile, marker .env"
static_arm
step "escape hatch — .env.<service>"
hatch_arm
step "mutant — kong loads .env again"
mutant_arm
step "live — running scoped services"
live_arm
printf '\033[0;32m[M212] PASS — scoped services hold only the variables they read\033[0m\n'
