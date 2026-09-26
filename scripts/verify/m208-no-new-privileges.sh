#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m208-no-new-privileges.sh — no container can gain a privilege through exec  #
#  (N-30): every service runs with no-new-privileges, and none is privileged   #
#  or unconfined                                                               #
#                                                                              #
#  STATIC  (no stack) renders, with every profile and an empty --env-file so   #
#          a local .env cannot hide the default: the base, the base plus each  #
#          overlay under orchestrators/compose/, prod + netseg (what           #
#          `make prod-up` runs) and cloud (its flags file stubbed). In each,   #
#          every service carries exactly one no-new-privileges entry and it    #
#          is on; none is `privileged`, none has seccomp/apparmor unconfined.  #
#  OPT-OUT CONTAINER_NO_NEW_PRIVILEGES=false turns it off on every service     #
#          (the escape hatch is wired; preflight-production refuses it, m194). #
#  MUTANTS the check must refuse five overlays: security_opt reset to [],      #
#          a service that does not extend the base, privileged: true,          #
#          seccomp=unconfined, and no-new-privileges:false on one service.     #
#  LIVE    when this project's containers are running, the kernel reports      #
#          NoNewPrivs: 1 for every container's PID 1 (/proc/<pid>/status).     #
#          Otherwise LIVE prints SKIP.                                         #
#                                                                              #
#  Skipped stacks, by name: docker-compose.monolith.yml (a preserved pre-split #
#  snapshot no target runs) and docker-compose.track-binocle.yml (needs a      #
#  service this repo never defines; test-lint-compose skips it too). The ci    #
#  overlay does not render with every profile (mongo's tmpfs clashes with its  #
#  volume), so it is checked with the default profiles only.                   #
#                                                                              #
#  Ponytail: LIVE reads PID 1 only. no_new_privs is inherited and cannot be    #
#  cleared, so every later process has it too, except one started by          #
#  `docker exec`, which gets the container's security_opt from the runtime    #
#  and not from PID 1.                                                         #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OVERLAYS="${ROOT}/orchestrators/compose"
SKIPPED="docker-compose.monolith.yml docker-compose.track-binocle.yml"
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M208] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M208] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
: >"${WORK}/empty.env"

# render writes the merged config of compose files $2… to $1 as JSON, with every
# profile unless PROFILES is set to empty, and CONTAINER_NO_NEW_PRIVILEGES taken
# from M208_NNP (unset = the files' default).
render() {
  local out="$1" args=() f
  shift
  for f in "$@"; do args+=(-f "${f}"); done
  [ "${PROFILES-*}" = "" ] || args+=(--profile "${PROFILES-*}")
  CONTAINER_NO_NEW_PRIVILEGES="${M208_NNP:-}" docker compose --project-directory "${ROOT}" \
    --env-file "${WORK}/empty.env" "${args[@]}" config --format json >"${out}" 2>"${WORK}/render.err" && return
  tail -n 3 "${WORK}/render.err" | sed 's/^/    /' >&2
  return 1
}

# offenders prints one `service: reason` line per hardening defect in config $1.
offenders() {
  jq -r '.services | to_entries[] | .key as $k | (.value.security_opt // []) as $o
    | ([$o[] | select(test("^no-new-privileges"))]) as $n
    | (if ($n | length) != 1 then "\($k): \($n | length) no-new-privileges entries"
       elif ($n[0] | test("^no-new-privileges(:true)?$") | not) then "\($k): \($n[0])"
       else empty end),
      (if .value.privileged == true then "\($k): privileged" else empty end),
      ($o[] | select(test("^(seccomp|apparmor)[:=]unconfined$")) | "\($k): \(.)")' "$1"
}

# hardened renders compose files $2… and fails unless every service in it is
# hardened; $1 names the stack in the output.
hardened() {
  local name="$1" bad n
  shift
  render "${WORK}/s.json" "$@" || fail "${name} does not render"
  bad="$(offenders "${WORK}/s.json")"
  [ -z "${bad}" ] || fail "${name}: $(printf '%s' "${bad}" | head -n 5 | paste -sd ';' -)"
  n="$(jq '.services | length' "${WORK}/s.json")"
  ok "${name}: ${n} services, each with no-new-privileges:true, none privileged or unconfined"
}

# cloud_stack writes a copy of the cloud overlay whose flags file is a stub, so
# it renders without the untracked infra/config/cloud/flags.env.cloud.
cloud_stack() {
  printf 'M208_CLOUD_STUB=1\n' >"${WORK}/flags.env.cloud"
  sed "s#infra/config/cloud/flags\.env\.cloud#${WORK}/flags.env.cloud#g" \
    "${OVERLAYS}/docker-compose.cloud.yml" >"${WORK}/cloud.yml"
}

# static checks the base, every overlay on it, prod + netseg, and cloud.
static() {
  local o name
  step "STATIC — every stack's services run with no-new-privileges"
  hardened base "${ROOT}/docker-compose.yml"
  for o in "${OVERLAYS}"/docker-compose.*.yml; do
    name="${o##*/}"
    case " ${SKIPPED} " in *" ${name} "*) continue ;; esac
    case "${name}" in
    docker-compose.cloud.yml)
      cloud_stack
      hardened "base + cloud" "${ROOT}/docker-compose.yml" "${WORK}/cloud.yml"
      ;;
    docker-compose.ci.yml) PROFILES="" hardened "base + ci (default profiles)" "${ROOT}/docker-compose.yml" "${o}" ;;
    *) hardened "base + ${name#docker-compose.}" "${ROOT}/docker-compose.yml" "${o}" ;;
    esac
  done
  hardened "base + prod + netseg" "${ROOT}/docker-compose.yml" \
    "${OVERLAYS}/docker-compose.prod.yml" "${OVERLAYS}/docker-compose.netseg.yml"
  printf '  SKIP: %s (see the header)\n' "${SKIPPED}"
}

# opt_out checks CONTAINER_NO_NEW_PRIVILEGES=false reaches every service.
opt_out() {
  local n off
  step "OPT-OUT — CONTAINER_NO_NEW_PRIVILEGES=false turns it off everywhere"
  M208_NNP=false render "${WORK}/o.json" "${ROOT}/docker-compose.yml" \
    "${OVERLAYS}/docker-compose.prod.yml" || fail "the opt-out does not render"
  n="$(jq '.services | length' "${WORK}/o.json")"
  off="$(jq '[.services[] | select(.security_opt == ["no-new-privileges:false"])] | length' "${WORK}/o.json")"
  [ "${off}" = "${n}" ] || fail "the opt-out reaches ${off} of ${n} services"
  ok "the opt-out reaches all ${n} services of base + prod"
}

# mutant writes overlay body $2 to a file and fails unless the check refuses the
# base plus that overlay; $1 names the mutant.
mutant() {
  printf 'services:\n%s\n' "$2" >"${WORK}/mutant.yml"
  render "${WORK}/m.json" "${ROOT}/docker-compose.yml" "${WORK}/mutant.yml" || fail "mutant $1 does not render"
  [ -n "$(offenders "${WORK}/m.json")" ] || fail "mutant survived: $1"
  ok "refused: $1"
}

# mutants proves the check sees each way a service can lose the hardening.
mutants() {
  step "MUTANTS — the check refuses each way out"
  mutant "security_opt reset" '  kong:
    security_opt: !reset []'
  mutant "a service without extends" '  rogue:
    image: busybox:1.36'
  mutant "privileged" '  kong:
    privileged: true'
  mutant "seccomp unconfined" '  kong:
    security_opt: ["seccomp=unconfined"]'
  mutant "no-new-privileges:false on one service" '  kong:
    security_opt: !override ["no-new-privileges:false"]'
}

# live checks the kernel's NoNewPrivs for PID 1 of every running container of
# this project.
live() {
  local ids id pid name bad=() n=0
  step "LIVE — the kernel reports NoNewPrivs for every running container"
  ids="$(docker ps -q --filter label=com.docker.compose.project=mini-baas)"
  [ -n "${ids}" ] || {
    printf '  SKIP: no mini-baas container is running\n'
    return 0
  }
  for id in ${ids}; do
    read -r pid name <<<"$(docker inspect -f '{{.State.Pid}} {{.Name}}' "${id}")"
    n=$((n + 1))
    grep -Eq '^NoNewPrivs:[[:space:]]+1$' "/proc/${pid}/status" 2>/dev/null || bad+=("${name#/}")
  done
  [ "${#bad[@]}" -eq 0 ] ||
    fail "NoNewPrivs is 0 in ${#bad[@]} of ${n} containers (${bad[*]:0:5}…): recreate them (make up), or they were started with CONTAINER_NO_NEW_PRIVILEGES=false"
  ok "NoNewPrivs: 1 in all ${n} running containers"
}

command -v jq >/dev/null || fail "jq is required"
docker compose version >/dev/null 2>&1 || fail "docker compose is required"
static
opt_out
mutants
live
cyan "[M208] PASS"
