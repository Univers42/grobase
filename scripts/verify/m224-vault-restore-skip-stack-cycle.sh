#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m224-vault-restore-skip-stack-cycle.sh — SKIP_STACK_CYCLE=1 hands the       #
#  stack to the caller, and a wrong stack is refused before any DROP          #
#                                                                              #
#  grobase-import.sh apply restores packet by packet. Left alone, each run    #
#  of vault-restore.sh stops every non-engine and ends in `make up EDITION`,  #
#  whose _rm-stale deletes every Exited mini-baas-* container: on a stack     #
#  started with another edition those services never come back (T0 verdict  #
#  C5/C6). With SKIP_STACK_CYCLE=1 the script must stop, start and make up    #
#  NOTHING, and must refuse (exit 2) when a non-engine still runs, when a     #
#  target engine is down, or when the flag is mistyped.                       #
#                                                                              #
#  Arms: RACER · ENGINE-DOWN · TYPO · QUIESCED · KEEP · DEFAULT (unset =      #
#        unchanged) · MUTANT (a guard-less copy must be caught).              #
#                                                                              #
#  Static only: docker and make are stubs that log their arguments; the seed  #
#  dir is empty and ENGINES=mssql, so every restore_* step skips.             #
#                                                                              #
# **************************************************************************** #
set -uo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VR="${ROOT}/scripts/ops/vault-restore.sh"

_B=$'\033[0;36m' _G=$'\033[0;32m' _R=$'\033[0;31m' _0=$'\033[0m'
rc=0
rc_vr=0
step() { printf '%s[M224] %s%s\n' "${_B}" "$1" "${_0}"; }
ok() { printf '%s  ✓ %s%s\n' "${_G}" "$1" "${_0}"; }
fail() {
  printf '%s[M224] FAIL — %s%s\n' "${_R}" "$1" "${_0}"
  rc=1
}

[ -f "${VR}" ] || {
  fail "missing scripts/ops/vault-restore.sh"
  exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin" "${WORK}/seeds" "${WORK}/state"
cat >"${WORK}/bin/docker" <<'EOF'
#!/bin/sh
printf 'docker %s\n' "$*" >>"$STUB_LOG"
if [ "$1" = ps ]; then
  for name in $STUB_PS; do printf '%s\n' "$name"; done
fi
exit 0
EOF
cat >"${WORK}/bin/make" <<'EOF'
#!/bin/sh
printf 'make %s\n' "$*" >>"$STUB_LOG"
exit 0
EOF
chmod +x "${WORK}/bin/docker" "${WORK}/bin/make"

# run_restore SCRIPT FLAG RUNNING [KEEP] — one restore against the stubs; RUNNING is what
# `docker ps` lists, KEEP the optional KEEP_RUNNING value. stdout/stderr and the stub log
# land in files so each arm asserts on them separately.
run_restore() {
  : >"${WORK}/log"
  rc_vr=0
  env PATH="${WORK}/bin:${PATH}" STUB_LOG="${WORK}/log" STUB_PS="$3" SKIP_STACK_CYCLE="$2" \
    KEEP_RUNNING="${4:-}" \
    ENGINES=mssql SEED_DIR="${WORK}/seeds" STATE_DIR="${WORK}/state" FETCH=0 \
    sh "$1" >"${WORK}/out" 2>"${WORK}/err" || rc_vr=$?
}

# untouched — nothing was stopped, started, exec'd or brought up.
untouched() { ! grep -qE '^docker (stop|start|exec)|^make ' "${WORK}/log"; }

racer_arm() {
  step "RACER — a running non-engine is refused before anything is touched"
  run_restore "${VR}" 1 "mini-baas-mssql mini-baas-kong"
  if [ "${rc_vr}" -eq 2 ] && grep -q 'mini-baas-kong' "${WORK}/err" && untouched; then
    ok "rc 2, stderr names mini-baas-kong, no stop/exec/make"
  else
    fail "rc ${rc_vr}; stderr [$(tr '\n' ' ' <"${WORK}/err")]; calls [$(tr '\n' ';' <"${WORK}/log")]"
  fi
}

engine_down_arm() {
  step "ENGINE-DOWN — a target engine that is not running is refused, not started"
  run_restore "${VR}" 1 ""
  if [ "${rc_vr}" -eq 2 ] && grep -q 'mini-baas-mssql' "${WORK}/err" && untouched; then
    ok "rc 2, stderr names mini-baas-mssql, no stop/exec/make"
  else
    fail "rc ${rc_vr}; stderr [$(tr '\n' ' ' <"${WORK}/err")]; calls [$(tr '\n' ';' <"${WORK}/log")]"
  fi
}

typo_arm() {
  step "TYPO — a value other than 0 or 1 never falls back to the stop/make-up path"
  run_restore "${VR}" yes "mini-baas-mssql mini-baas-kong"
  if [ "${rc_vr}" -eq 2 ] && untouched; then
    ok "SKIP_STACK_CYCLE=yes -> rc 2, no stop/exec/make"
  else
    fail "SKIP_STACK_CYCLE=yes -> rc ${rc_vr}; calls [$(tr '\n' ';' <"${WORK}/log")]"
  fi
}

quiesced_arm() {
  step "QUIESCED — engines only: the restore runs and the stack is left to the caller"
  run_restore "${VR}" 1 "mini-baas-mssql"
  if [ "${rc_vr}" -eq 0 ] && ! grep -qE '^docker (stop|start)|^make ' "${WORK}/log" &&
    grep -q 'the caller restarts it' "${WORK}/err"; then
    ok "rc 0, no docker stop/start, no make, the hand-back is named"
  else
    fail "rc ${rc_vr}; calls [$(tr '\n' ';' <"${WORK}/log")]"
  fi
}

# keep_arm — (a) without KEEP_RUNNING the caller's mysql is a racer, refused before any change;
# (b) KEEP_RUNNING=mysql is accepted with nothing cycled (the lone exec is QUIESCED's pg_isready
# probe); (c) KEEP_RUNNING widens the allow-list, it does not lift it: kong is still refused.
keep_arm() {
  step "KEEP — KEEP_RUNNING engines stay up: tolerated, never restored"
  run_restore "${VR}" 1 "mini-baas-mssql mini-baas-mysql"
  if [ "${rc_vr}" -eq 2 ] && grep -q 'mini-baas-mysql' "${WORK}/err" && untouched; then
    ok "rc 2, stderr names mini-baas-mysql, no stop/exec/make"
  else
    fail "rc ${rc_vr}; stderr [$(tr '\n' ' ' <"${WORK}/err")]; calls [$(tr '\n' ';' <"${WORK}/log")]"
  fi
  run_restore "${VR}" 1 "mini-baas-mssql mini-baas-mysql" mysql
  if [ "${rc_vr}" -eq 0 ] && ! grep -qE '^docker (stop|start)|^make ' "${WORK}/log" &&
    grep -q 'the caller restarts it' "${WORK}/err"; then
    ok "rc 0, mini-baas-mysql tolerated, no stop/start/make, the hand-back is named"
  else
    fail "rc ${rc_vr}; calls [$(tr '\n' ';' <"${WORK}/log")]"
  fi
  run_restore "${VR}" 1 "mini-baas-mssql mini-baas-mysql mini-baas-kong" mysql
  if [ "${rc_vr}" -eq 2 ] && grep -q 'mini-baas-kong' "${WORK}/err" && untouched; then
    ok "rc 2, stderr names mini-baas-kong, no stop/exec/make"
  else
    fail "rc ${rc_vr}; stderr [$(tr '\n' ' ' <"${WORK}/err")]; calls [$(tr '\n' ';' <"${WORK}/log")]"
  fi
}

default_arm() {
  step "DEFAULT — unset keeps today's cycle: stop the racers, engines up, full edition up"
  run_restore "${VR}" "" "mini-baas-mssql mini-baas-kong"
  if [ "${rc_vr}" -eq 0 ] && grep -qE '^docker stop -t 30 +mini-baas-kong$' "${WORK}/log" &&
    grep -qx 'make --no-print-directory up EDITION=devlean SERVICE=mssql' "${WORK}/log" &&
    grep -qx 'make --no-print-directory up EDITION=devlean' "${WORK}/log"; then
    ok "rc 0, kong stopped, engines-only up, then the full edition up"
  else
    fail "rc ${rc_vr}; calls [$(tr '\n' ';' <"${WORK}/log")]"
  fi
}

mutant_arm() {
  step "MUTANT — a copy whose main() always cycles the stack must fail QUIESCED"
  local mutant="${WORK}/vault-restore.mutant.sh"
  sed 's/^  quiesce_stack$/  engines_up/' "${VR}" >"${mutant}"
  cmp -s "${VR}" "${mutant}" && {
    fail "the mutant did not apply: main() no longer calls quiesce_stack"
    return
  }
  run_restore "${mutant}" 1 "mini-baas-mssql mini-baas-kong"
  if grep -qE '^docker stop|^make ' "${WORK}/log"; then
    ok "the guard-less copy stops containers and runs make: the arms above would see it"
  else
    fail "the guard-less copy touched nothing, so the arms prove nothing"
  fi
}

racer_arm
engine_down_arm
typo_arm
quiesced_arm
keep_arm
default_arm
mutant_arm

if [ "${rc}" -eq 0 ]; then
  printf '%s[M224] PASS — SKIP_STACK_CYCLE=1 never cycles the stack and refuses a wrong one before any DROP%s\n' "${_G}" "${_0}"
else
  printf '%s[M224] FAIL%s\n' "${_R}" "${_0}"
fi
exit "${rc}"
