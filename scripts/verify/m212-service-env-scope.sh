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
#  covers the engines; this gate covers the platform services in SCOPED, the   #
#  Go control plane, the Rust data plane, realtime, and the init/ops jobs.     #
#                                                                              #
#  STATIC   a copy of the compose tree whose .env holds M212_PLATFORM (a key   #
#           only env_file can deliver) and a marker in each service's needed   #
#           key. Rendered with every profile: base, base + each overlay, base  #
#           + fly's override. No scoped service may hold M212_PLATFORM; each   #
#           must still get its needed key from .env.                           #
#  HATCH    a .env.<service> setting reaches the service; M212_PLATFORM not.   #
#  CLOUD    docker-compose.cloud.yml hands flags.env.cloud to orchestrator,    #
#           tenant-control and data-plane-router-rust. Their base entries are  #
#           bare pass-throughs, which beat an env_file value of the same name  #
#           (unset renders null), so every flags.env.example key set to a      #
#           marker must reach each of the three — or the value the base file   #
#           pins with a default — never null.                                  #
#  MUTANT   kong given env_file .env again, and the cloud overlay without its  #
#           `!reset` merge: each check must go red.                            #
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
# shellcheck source=../lib/lib-required-env.sh
. "${SCRIPT_DIR}/../lib/lib-required-env.sh"
TS_SERVICES="ai-service analytics-service email-service gdpr-service log-service mongo-api newsletter-service outbox-relay permission-engine query-router schema-service session-service storage-router"
GO_SERVICES="adapter-registry-go tenant-control orchestrator function-scheduler webhook-dispatcher"
CLOUD_SERVICES="orchestrator tenant-control data-plane-router-rust"
SCOPED="kong studio pg-meta gotrue postgrest ${TS_SERVICES} ${GO_SERVICES} data-plane-router-rust realtime db-bootstrap pg-migrate pg-backup supavisor vault-init"
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
  studio) echo POSTGRES_DB ;;
  pg-meta) echo PG_META_DB_HOST ;;
  gotrue) echo GOTRUE_DISABLE_SIGNUP ;;
  postgrest) echo PGRST_DB_URI ;;
  adapter-registry-go | tenant-control | orchestrator | function-scheduler | webhook-dispatcher | data-plane-router-rust) echo GROBASE_ENV ;;
  realtime) echo REALTIME_PRESENCE_REDIS_URL ;;
  db-bootstrap) echo WAIT_SECONDS ;;
  pg-migrate) echo POSTGRES_DB ;;
  pg-backup) echo PG_BACKUP_RETAIN_PRO_DAYS ;;
  supavisor) echo REGION ;;
  vault-init) echo SMTP_PASS ;;
  *-service | mongo-api | outbox-relay | permission-engine | query-router | storage-router) echo INTERNAL_IDENTITY_HMAC_KEYS ;;
  *) fail "no needed key declared for $1" ;;
  esac
}

# setup copies the compose tree, fly's override and an empty cloud flags file,
# and writes a .env with M212_PLATFORM plus the marker in every needed key.
setup() {
  local svc floor
  mkdir -p "${TREE}/orchestrators" "${TREE}/deploy/fly" "${TREE}/infra/config/cloud"
  cp "${ROOT}/docker-compose.yml" "${TREE}/"
  cp -r "${ROOT}/orchestrators/compose" "${TREE}/orchestrators/"
  cp "${ROOT}/deploy/fly/compose.override.yml" "${TREE}/deploy/fly/"
  : >"${TREE}/infra/config/cloud/flags.env.cloud"
  printf 'M212_PLATFORM=%s\nJWT_SECRET=m212-jwt\n' "${MARK}" >"${TREE}/.env"
  floor="$(required_env_floor "m212-floor" "${TREE}" "${TREE}/.env")"
  [ -z "${floor}" ] || printf '%s\n' "${floor}" >>"${TREE}/.env"
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

# cloud_render writes to $1 the base + cloud overlay render with every
# flags.env.example key set to MARK in the tree's flags.env.cloud (emptied again after).
# cloud_render writes the flags fixture where EVERY compose version will look for it.
# `env_file: infra/config/cloud/flags.env.cloud` is relative, and compose resolves a
# relative env_file against the project directory in some versions and against the
# compose FILE's directory in others. This gate asserts that the flags reach the three
# services, not where compose hunts for the file, so the fixture goes to both candidate
# paths — otherwise the arm passes on one runner and fails on another, which is what it
# did: green locally on v5.6.0, red on CI.
cloud_render() {
  local primary="${TREE}/infra/config/cloud/flags.env.cloud"
  local alt="${TREE}/orchestrators/compose/infra/config/cloud/flags.env.cloud"
  mkdir -p "${alt%/*}"
  sed "s|\$|=${MARK}|" "${WORK}/flag.keys" >"${primary}"
  cp "${primary}" "${alt}"
  render "$1" "${TREE}/orchestrators/compose/docker-compose.cloud.yml"
  : >"${primary}"
  rm -rf "${TREE}/orchestrators/compose/infra"
}

# cloud_check fails when a flags.env.example key does not reach a CLOUD_SERVICES
# service in config $1: it must hold MARK, or the value base.json pins for it.
cloud_check() {
  local svc missed
  for svc in ${CLOUD_SERVICES}; do
    missed="$(jq -r --arg s "${svc}" --arg m "${MARK}" --slurpfile base "${WORK}/base.json" \
      --rawfile keys "${WORK}/flag.keys" '
      .services[$s].environment as $env
      | ($keys | split("\n") | map(select(. != "")))[] as $k
      | (if $base[0].services[$s].environment[$k] == null then $m else $base[0].services[$s].environment[$k] end) as $want
      | select($env[$k] != $want) | $k' "$1" | tr '\n' ' ')"
    [ -z "${missed}" ] || fail "cloud: ${svc} does not receive from flags.env.cloud: ${missed}"
  done
}

# cloud_arm proves the cloud overlay still delivers its flags to CLOUD_SERVICES.
cloud_arm() {
  grep -vE '^[[:space:]]*(#|$)' "${ROOT}/infra/config/cloud/flags.env.example" | cut -d= -f1 >"${WORK}/flag.keys"
  [ -s "${WORK}/flag.keys" ] || fail "cloud: no keys read from flags.env.example"
  cloud_render "${WORK}/cloud.json"
  cloud_check "${WORK}/cloud.json"
  ok "cloud: $(wc -l <"${WORK}/flag.keys" | tr -d ' ') flags.env.example keys reach ${CLOUD_SERVICES}, or the default the base file pins"
}

# cloud_mutant_arm drops the cloud overlay's `!reset` merge; cloud_check must catch it.
cloud_mutant_arm() {
  local f="${TREE}/orchestrators/compose/docker-compose.cloud.yml"
  cp "${f}" "${WORK}/cloud.yml"
  sed 's|^      <<: \*cloud-flags$|      M212_NOOP: "1"|' "${WORK}/cloud.yml" >"${f}"
  cmp -s "${f}" "${WORK}/cloud.yml" && fail "mutant: could not drop the cloud-flags merge"
  cloud_render "${WORK}/cloud-mutant.json"
  cp "${WORK}/cloud.yml" "${f}"
  (cloud_check "${WORK}/cloud-mutant.json") >/dev/null 2>&1 && fail "mutant: the cloud overlay without its !reset merge passed — the check is vacuous"
  ok "mutant: the cloud overlay without its !reset merge is caught"
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
  live_image_env
}

# live_image_env fails when a running container of the project carries a bare
# env name (a pass-through left unset) that its image sets: Docker then unsets
# the image's value (APP_NAME, NODE_ENV), which a valueless compose key must never do.
live_image_env() {
  local c bare img bad=""
  for c in $(docker ps -q --filter label=com.docker.compose.project=mini-baas); do
    bare="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${c}" | grep -v '=' | grep .)" || continue
    img="$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$(docker inspect -f '{{.Image}}' "${c}")" | cut -d= -f1)"
    bad="${bad}$(grep -Fxf <(printf '%s\n' "${img}") <<<"${bare}" | sed "s|^|$(docker inspect -f '{{.Name}}' "${c}"):|" | tr '\n' ' ')"
  done
  [ -z "${bad}" ] || fail "live: an unset pass-through unsets the image's own variable: ${bad}"
  ok "live: no pass-through unsets an image variable (every running container)"
}

command -v jq >/dev/null || fail "jq is required"
setup
step "static — base and every overlay, every profile, marker .env"
static_arm
step "escape hatch — .env.<service>"
hatch_arm
step "cloud — flags.env.cloud still reaches the three services that read it"
cloud_arm
step "mutant — kong loads .env again; cloud overlay loses its merge"
mutant_arm
cloud_mutant_arm
step "live — running scoped services"
live_arm
printf '\033[0;32m[M212] PASS — scoped services hold only the variables they read\033[0m\n'
