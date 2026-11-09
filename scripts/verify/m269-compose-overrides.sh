#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m269-compose-overrides.sh — operator compose files ride every make         #
#  recreate, or make refuses to run                                            #
#                                                                              #
#  A host keeps local pins (a flag held in shadow, a builder kept off) in      #
#  compose files outside the repo. Passed as a side -f, they were dropped by   #
#  the next make-driven recreate and the drift check still passed, because it  #
#  compared against make's own command (VM, 2026-11-06 12:26Z). The knob:      #
#                                                                              #
#   RENDER   COMPOSE_OVERRIDES files join DC as -f, in order, after every      #
#            built-in overlay; unset leaves DC as it was.                      #
#   MISSING  a listed file that does not exist stops make, naming the file.    #
#   ENVLOCAL a COMPOSE_OVERRIDES= line in .env.local is read when the env is   #
#            silent.                                                           #
#   MUTANTS  each check refuses the way back in.                               #
#                                                                              #
#  Static only: no network, no stack, no credential read, no value printed.    #
#                                                                              #
# **************************************************************************** #
set -uo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CFG="${ROOT}/orchestrators/makes/00-config.mk"
PERF_OVERLAY="orchestrators/compose/docker-compose.perf.yml"
REDIS_OVERLAY="orchestrators/compose/docker-compose.redis-acl.yml"
OVERRIDE_A="orchestrators/compose/docker-compose.remote-access.yml"
OVERRIDE_B="orchestrators/compose/docker-compose.qemu-guest.yml"

_B=$'\033[0;36m' _G=$'\033[0;32m' _R=$'\033[0;31m' _0=$'\033[0m'
rc=0
step() { printf '%s[M269] %s%s\n' "${_B}" "$1" "${_0}"; }
ok() { printf '%s  ✓ %s%s\n' "${_G}" "$1" "${_0}"; }
fail() {
  printf '%s[M269] FAIL — %s%s\n' "${_R}" "$1" "${_0}"
  rc=1
}

for f in "${CFG}" "${ROOT}/${PERF_OVERLAY}" "${ROOT}/${REDIS_OVERLAY}" "${ROOT}/${OVERRIDE_A}" "${ROOT}/${OVERRIDE_B}"; do
  [ -f "${f}" ] || {
    fail "missing ${f#"${ROOT}"/}"
    exit 1
  }
done

# dc_in <dir> <cfg> [VAR=value…]: the compose command make builds, run from <dir>.
dc_in() {
  local dir="$1" cfg="$2"
  shift 2
  (cd "${dir}" && make -s -f "${cfg}" -f /dev/stdin show "$@" <<<'show: ; @echo $(DC)' 2>&1)
}

# render_ok <cfg>: two overrides land last and in order behind two built-in overlays;
# an empty knob renders exactly the knob-less command.
render_ok() {
  local with plain
  with="$(dc_in "${ROOT}" "$1" PERF=1 REDIS_ACL=1 "COMPOSE_OVERRIDES=${OVERRIDE_A} ${OVERRIDE_B}")"
  plain="$(dc_in "${ROOT}" "$1" PERF=1 REDIS_ACL=1 COMPOSE_OVERRIDES=)"
  [[ ${with} == "${plain} -f ${OVERRIDE_A} -f ${OVERRIDE_B}" ]] &&
    [[ ${plain} == *"-f ${REDIS_OVERLAY}" ]]
}

# missing_ok <cfg>: a listed file that does not exist fails make and the message names it.
missing_ok() {
  local out ghost="orchestrators/compose/m269-no-such-override.yml"
  out="$(dc_in "${ROOT}" "$1" "COMPOSE_OVERRIDES=${OVERRIDE_A} ${ghost}")" && return 1
  [[ ${out} == *"${ghost}"* ]] && [[ ${out} != *"docker compose"* ]]
}

# envlocal_ok <cfg>: from a directory whose .env.local lists two files, DC carries both.
envlocal_ok() {
  local work out
  work="$(mktemp -d)" || return 1
  touch "${work}/a.yml" "${work}/b.yml"
  printf 'OTHER=1\nCOMPOSE_OVERRIDES=a.yml b.yml\n' >"${work}/.env.local"
  out="$(dc_in "${work}" "$1")"
  rm -rf "${work}"
  [[ ${out} == *" -f a.yml -f b.yml" ]]
}

checks_arm() {
  step "RENDER — overrides join DC last, in order; unset changes nothing"
  render_ok "${CFG}" && ok "two overrides follow the built-in overlays, in the order listed" ||
    fail "COMPOSE_OVERRIDES does not render last and in order (or changes DC when empty)"
  step "MISSING — a listed file that does not exist stops make"
  missing_ok "${CFG}" && ok "make exits non-zero and names the missing file" ||
    fail "a missing override is skipped or the error does not name it"
  step "ENVLOCAL — a .env.local line is read when the env is silent"
  envlocal_ok "${CFG}" && ok "COMPOSE_OVERRIDES= in .env.local reaches DC" ||
    fail "00-config.mk does not read COMPOSE_OVERRIDES from .env.local"
}

# mutant <sed-expr> <check> <refused-message>: the check must reject the mutated config.
mutant() {
  local cfg="${work}/00-config.mk"
  sed "$1" "${CFG}" >"${cfg}"
  if cmp -s "${cfg}" "${CFG}"; then
    fail "mutant did not apply: $3"
  elif "$2" "${cfg}"; then
    fail "mutant survived: $3"
  else
    ok "refused: $3"
  fi
}

mutants_arm() {
  step "MUTANTS — each check refuses the way back in"
  local work
  work="$(mktemp -d)" || return
  trap 'rm -rf "${work}"' RETURN
  mutant 's/\$(foreach f,\$(COMPOSE_OVERRIDES), -f \$(f))$//' render_ok "overrides dropped from DC"
  mutant 's/^\(DC  *:= docker compose -f \$(COMPOSE_FILE)\)\(.*\)\$(foreach f,\$(COMPOSE_OVERRIDES), -f \$(f))$/\1$(foreach f,$(COMPOSE_OVERRIDES), -f $(f))\2/' \
    render_ok "overrides placed before the built-in overlays"
  mutant '/^\$(foreach f,\$(COMPOSE_OVERRIDES),\$(if \$(wildcard/d' missing_ok "a missing file skipped silently"
  mutant 's/^COMPOSE_OVERRIDES ?= .*/COMPOSE_OVERRIDES ?=/' envlocal_ok ".env.local no longer read"
}

checks_arm
mutants_arm

if [ "${rc}" -eq 0 ]; then
  printf '%s[M269] PASS — operator compose files ride every make recreate, or make refuses%s\n' "${_G}" "${_0}"
else
  printf '%s[M269] FAIL%s\n' "${_R}" "${_0}"
fi
exit "${rc}"
