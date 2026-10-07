#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m211-engine-env-scope.sh — engine containers get their own variables, not   #
#  the platform .env (JWT_SECRET, service tokens, every other password).       #
#                                                                              #
#  An engine loaded the whole .env through `env_file: [.env]`, so a foothold   #
#  in it (a Postgres superuser's COPY … PROGRAM, a Redis or Mongo RCE) read    #
#  every platform secret from /proc/1/environ. The ten engine services now     #
#  load only the optional .env.engines (operator engine settings: MINIO_*,     #
#  TZ, …) plus their explicit environment.                                     #
#                                                                              #
#  STATIC   a copy of the compose tree whose .env holds a sentinel in          #
#           JWT_SECRET, SERVICE_ROLE_KEY and M211_PLATFORM (so it reaches a    #
#           service by env_file or by interpolation). Rendered with every      #
#           profile: base, base + each overlay, base + fly's override. No      #
#           engine may hold the sentinel; base must render all ten engines.    #
#  HATCH    a .env.engines setting reaches minio; the sentinel still does not. #
#  MUTANT   postgres given env_file .env again: the check must go red.         #
#  LIVE     when the stack runs: each running engine's runtime env and PID 1   #
#           /proc environ hold no platform secret. Stack down = SKIP, stated.  #
#                                                                              #
#  Not rendered: docker-compose.monolith.yml (preserved pre-split file, stale  #
#  paths, no make target uses it) and track-binocle (needs pg-meta).           #
#  Ponytail: the list of engines is fixed below — a new engine service that    #
#  loads .env is not caught until it is added to ENGINES.                      #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENGINES="postgres redis mongo mysql mariadb minio trino iceberg-rest debezium minio-iceberg-init"
SENT="m211-sentinel-$$"
FLOOR="m211-floor-$$"
# shellcheck source=../lib/lib-required-env.sh
. "${SCRIPT_DIR}/../lib/lib-required-env.sh"
WORK="$(mktemp -d)" || exit 1
TREE="${WORK}/tree"
trap 'rm -rf "${WORK}"' EXIT
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M211] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M211] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

# setup copies the compose tree, fly's override and an empty cloud flags file,
# and writes the sentinel .env.
setup() {
  mkdir -p "${TREE}/orchestrators" "${TREE}/deploy/fly" "${TREE}/infra/config/cloud"
  cp "${ROOT}/docker-compose.yml" "${TREE}/"
  cp -r "${ROOT}/orchestrators/compose" "${TREE}/orchestrators/"
  cp "${ROOT}/deploy/fly/compose.override.yml" "${TREE}/deploy/fly/"
  : >"${TREE}/infra/config/cloud/flags.env.cloud"
  printf 'JWT_SECRET=%s\nSERVICE_ROLE_KEY=%s\nM211_PLATFORM=%s\n' "${SENT}" "${SENT}" "${SENT}" >"${TREE}/.env"
  # Secret-bearing compose entries are ${KEY:?...}; satisfy the whole required floor
  # or the render fails for an unrelated reason. FLOOR differs from SENT so a
  # legitimate consumer never matches the leak sentinel.
  floor="$(required_env_floor "${FLOOR}" "${TREE}" "${TREE}/.env")"
  [ -z "${floor}" ] || printf '%s\n' "${floor}" >>"${TREE}/.env"
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

# leaks prints service:key for every engine variable in config $1 that holds
# the sentinel or is named M211_PLATFORM.
leaks() {
  jq -r --arg e "${ENGINES}" --arg s "${SENT}" '($e | split(" ")) as $eng
    | .services | to_entries[] | select(.key | IN($eng[])) | .key as $svc
    | (.value.environment // {}) | to_entries[]
    | select(.value == $s or .key == "M211_PLATFORM") | "\($svc):\(.key)"' "$1"
}

# engines_in prints how many of ENGINES config $1 renders.
engines_in() {
  jq --arg e "${ENGINES}" '[.services | keys[] | select(IN($e | split(" ")[]))] | length' "$1"
}

# check fails when an engine in config $1 ($2 names it) holds the sentinel.
check() {
  local bad
  bad="$(leaks "$1" | tr '\n' ' ')"
  [ -z "${bad}" ] || fail "$2: engines hold platform variables: ${bad}"
  ok "$2: $(engines_in "$1") engines, none holds a platform variable"
}

# static_arm renders base (all ten engines required) and base + every overlay.
static_arm() {
  local o n
  render "${WORK}/base.json"
  n="$(engines_in "${WORK}/base.json")"
  [ "${n}" = 10 ] || fail "base renders ${n} of the 10 engines — ENGINES or the profiles drifted"
  check "${WORK}/base.json" base
  for o in "${TREE}"/orchestrators/compose/docker-compose.*.yml "${TREE}/deploy/fly/compose.override.yml"; do
    case "${o##*/}" in docker-compose.monolith.yml | docker-compose.track-binocle.yml) continue ;; esac
    render "${WORK}/o.json" "${o}"
    check "${WORK}/o.json" "base + ${o##*/}"
  done
}

# hatch_arm proves a .env.engines setting reaches minio while the sentinel does not.
hatch_arm() {
  printf 'MINIO_PROMETHEUS_AUTH_TYPE=public\n' >"${TREE}/.env.engines"
  render "${WORK}/hatch.json"
  [ "$(jq -r '.services.minio.environment.MINIO_PROMETHEUS_AUTH_TYPE // ""' "${WORK}/hatch.json")" = public ] ||
    fail "hatch: a .env.engines setting did not reach minio"
  check "${WORK}/hatch.json" "base + .env.engines (MINIO_PROMETHEUS_AUTH_TYPE reaches minio)"
  rm -f "${TREE}/.env.engines"
}

# mutant_arm gives postgres env_file .env again; the check must catch it.
mutant_arm() {
  local f="${TREE}/orchestrators/compose/base/data-engines.yml" n
  cp "${f}" "${WORK}/data-engines.yml"
  awk '/^  postgres:$/ { p = 1 } p && $0 == "      - path: .env.engines" { print "      - path: .env"; p = 0; next } { print }' \
    "${WORK}/data-engines.yml" >"${f}"
  cmp -s "${f}" "${WORK}/data-engines.yml" && fail "mutant: could not re-add env_file .env to postgres"
  render "${WORK}/mutant.json"
  cp "${WORK}/data-engines.yml" "${f}"
  n="$(leaks "${WORK}/mutant.json" | wc -l)"
  [ "${n}" -gt 0 ] || fail "mutant: postgres with env_file .env passed — the check is vacuous"
  ok "mutant: postgres with env_file .env is caught (${n} platform variables)"
}

# live_env prints, one variable per line, the environment the runtime hands
# container $1's PID 1, then that PID 1's /proc environ read from a sidecar in
# its PID namespace (no tool needed in the engine image).
# Ponytail: a process that rewrites its environ block for its title (redis)
# shows an empty /proc view; the runtime's list still covers it.
live_env() {
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1"
  docker run --rm --pid "container:$1" --cap-add SYS_PTRACE --network none "${M211_SIDECAR:-alpine:3.21}" \
    sh -c 'tr "\0" "\n" </proc/1/environ' 2>/dev/null
}

# live_arm checks every running engine's PID 1 environment: read for real (PATH
# present), no platform secret. No engine running = SKIP.
live_arm() {
  local svc c envs seen=""
  for svc in ${ENGINES}; do
    c="$(docker ps -q --filter label=com.docker.compose.project=mini-baas \
      --filter "label=com.docker.compose.service=${svc}" | head -n1)"
    [ -n "${c}" ] || continue
    envs="$(live_env "${c}")"
    [ -n "${envs}" ] || fail "live ${svc}: could not read /proc/1/environ"
    grep -q '^PATH=' <<<"${envs}" || fail "live ${svc}: /proc/1/environ read returned no PATH — not a real environment"
    ! grep -qE '^(JWT_SECRET|SERVICE_ROLE_KEY|ADAPTER_REGISTRY_SERVICE_TOKEN|ANON_KEY)=' <<<"${envs}" ||
      fail "live ${svc}: PID 1 holds a platform secret (recreate it: docker compose up -d ${svc})"
    seen="${seen} ${svc}"
  done
  [ -n "${seen}" ] || {
    printf '\033[0;33m  - SKIP live: no engine of project mini-baas is running\033[0m\n'
    return 0
  }
  ok "live runtime env + /proc/1/environ:${seen} — no JWT_SECRET/SERVICE_ROLE_KEY/service token/ANON_KEY"
}

command -v jq >/dev/null || fail "jq is required"
setup
step "static — base and every overlay, every profile, sentinel .env"
static_arm
step "escape hatch — .env.engines"
hatch_arm
step "mutant — postgres loads .env again"
mutant_arm
step "live — running engines"
live_arm
printf '\033[0;32m[M211] PASS — engines hold their own variables, never the platform .env\033[0m\n'
