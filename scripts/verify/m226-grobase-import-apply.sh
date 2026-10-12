#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m226-grobase-import-apply.sh — apply's blast radius is exactly the          #
#  recorded compose-project set, snapshot before the first restore, racer      #
#  refused before any DROP, stack down after a failed restore.                #
#                                                                              #
#  grobase-import-apply.sh must stop ONLY what it recorded (never the --rm    #
#  one), tar each target volume BEFORE the first vault-restore call, start    #
#  the engines back and refuse anything another actor started, restore packet #
#  by packet, prove postgres counts, run the target's own one-shots, then     #
#  `docker start` the recorded ids. On any exit the trap either restarts the  #
#  recorded set (before the first DROP) or leaves the stack down and names    #
#  the rollback (after it). This gate stubs docker, vault-restore.sh and      #
#  pg-counts.sh and asserts the order, the state file, the recorded ids and   #
#  the rollback, plus that a racer-check-less mutant is caught.                #
#                                                                              #
#  Arms: PLAN · MISSING · HAPPY · RM · RACER · RESTORE · COUNTS · MIGRATE ·    #
#        REFUSED · UNFINISHED · ALREADY · ROLLBACK · MUTANT.                   #
#                                                                              #
#  Hermetic: a mktemp WORK dir holding copies of apply/rollback, a stub       #
#  grobase-import.sh (verify only), stub vault-restore/pg-counts, and a       #
#  docker stub first on PATH. Every arm re-arms the same 4-container running   #
#  set (one --rm) and one postgres-only import.                               #
#                                                                              #
# **************************************************************************** #
set -uo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
APPLY="${ROOT}/scripts/ops/grobase-import-apply.sh"
ROLLBACK="${ROOT}/scripts/ops/grobase-import-rollback.sh"

_B=$'\033[0;36m' _G=$'\033[0;32m' _R=$'\033[0;31m' _0=$'\033[0m'
rc=0
step() { printf '%s[M226] %s%s\n' "${_B}" "$1" "${_0}"; }
ok() { printf '%s  ✓ %s%s\n' "${_G}" "$1" "${_0}"; }
fail() {
  printf '%s[M226] FAIL — %s%s\n' "${_R}" "$1" "${_0}"
  rc=1
}

[ -f "${APPLY}" ] && [ -f "${ROLLBACK}" ] || {
  fail "missing scripts/ops/grobase-import-{apply,rollback}.sh"
  exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin" "${WORK}/ops"
cp "${APPLY}" "${WORK}/ops/grobase-import-apply.sh"
cp "${ROLLBACK}" "${WORK}/ops/grobase-import-rollback.sh"
APPLY_RUN="${WORK}/ops/grobase-import-apply.sh"

# apply calls `bash "$SCRIPT_DIR/grobase-import.sh" verify ID`; log it and pass.
cat >"${WORK}/ops/grobase-import.sh" <<'EOF'
#!/usr/bin/env bash
printf 'verify %s\n' "$2" >>"${STUB_LOG}"
exit 0
EOF

# vault-restore.sh: one logged line, exit STUB_RESTORE_RC. `sh`-invoked by apply.
cat >"${WORK}/stub-restore.sh" <<'EOF'
#!/usr/bin/env bash
seed=""
for f in "${SEED_DIR}"/*; do seed="${seed} $(basename "$f")"; done
printf 'restore ENGINES=%s KEEP=%s SKIP=%s SEED=%s\n' \
  "${ENGINES:-}" "${KEEP_RUNNING:-}" "${SKIP_STACK_CYCLE:-}" "${seed# }" >>"${STUB_LOG}"
exit "${STUB_RESTORE_RC:-0}"
EOF

# pg-counts.sh: log the args, exit STUB_COUNTS_RC.
cat >"${WORK}/stub-counts.sh" <<'EOF'
#!/usr/bin/env bash
printf 'counts%s\n' "${*:+ ${*}}" >>"${STUB_LOG}"
exit "${STUB_COUNTS_RC:-0}"
EOF

# docker stub: logs `docker $*`, then answers the exact shapes apply/rollback use.
cat >"${WORK}/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"${STUB_LOG}"
case "$1" in
info | image | pull)
  exit 0
  ;;
ps)
  while read -r name; do printf 'id_%s\n' "$name"; done <"${WORK}/running"
  ;;
inspect)
  if [ "${2:-}" = -f ]; then
    arg="${4}"
    name="${arg#id_}"
    case "$3" in
    *Mounts*)
      printf 'vol_%s\n' "$name"
      ;;
    *AutoRemove*)
      case " ${STUB_AUTOREMOVE} " in
      *" $name "*) ;;
      *) printf 'id_%s %s\n' "$name" "$name" ;;
      esac
      ;;
    *Health*)
      printf 'healthy\n'
      ;;
    esac
  else
    case " ${STUB_EXISTS} " in
    *" $2 "*) ;;
    *) exit 1 ;;
    esac
  fi
  ;;
stop)
  shift
  [ "${1:-}" = -t ] && shift 2
  for arg in "$@"; do
    name="${arg#id_}"
    if grep -qxF "$name" "${WORK}/running" 2>/dev/null; then
      grep -vxF "$name" "${WORK}/running" >"${WORK}/running.tmp"
      mv "${WORK}/running.tmp" "${WORK}/running"
    fi
  done
  ;;
start)
  shift
  if [ "${1:-}" = -a ]; then
    exit "${STUB_MIGRATE_RC:-0}"
  fi
  for arg in "$@"; do
    name="${arg#id_}"
    grep -qxF "$name" "${WORK}/running" 2>/dev/null || printf '%s\n' "$name" >>"${WORK}/running"
    if [ "${STUB_RACER:-0}" = 1 ] && [ "$name" = mini-baas-postgres ]; then
      grep -qxF mini-baas-kong-2 "${WORK}/running" 2>/dev/null ||
        printf 'mini-baas-kong-2\n' >>"${WORK}/running"
    fi
  done
  ;;
run)
  case "$*" in
  *"du -sb"*) printf '100\t/v\n' ;;
  *"tar -czf"*) tar -czf - -C "${WORK}/fake" . ;;
  *"find /v -mindepth 1"*) (cd "${WORK}/fake" && find . -mindepth 1) ;;
  esac
  ;;
esac
exit 0
EOF
chmod +x "${WORK}/bin/docker"
mkdir -p "${WORK}/fake" && printf 'snapshotbytes\n' >"${WORK}/fake/filedata"

IMPORT_ROOT="${WORK}/import"
mkdir -p "${IMPORT_ROOT}/imp1"
VAULT_RESTORE="${WORK}/stub-restore.sh"
PG_COUNTS="${WORK}/stub-counts.sh"
STUB_LOG="${WORK}/log"
APPLY_DIR="${IMPORT_ROOT}/imp1/apply"

printf '%s\n' '{"packets":[{"id":"p-postgres","engine":"postgres","artifact":"postgres-all.sql.gz","bytes":10}]}' \
  >"${IMPORT_ROOT}/imp1/manifest.json"
printf 'binary-archive-placeholder\n' >"${IMPORT_ROOT}/imp1/postgres-all.sql.gz"
: >"${STUB_LOG}"

# reset — the fixed pre-arm world: 4 running (one --rm), the 3 that must exist.
reset() {
  STUB_RACER=0 STUB_MIGRATE_RC=0 STUB_RESTORE_RC=0 STUB_COUNTS_RC=0
  STUB_EXISTS="mini-baas-postgres mini-baas-db-bootstrap mini-baas-pg-migrate"
  STUB_AUTOREMOVE="mini-baas-mcp"
  printf '%s\n' mini-baas-postgres mini-baas-kong mini-baas-auth mini-baas-mcp |
    LC_ALL=C sort >"${WORK}/running"
  rm -rf "${APPLY_DIR}" "${IMPORT_ROOT}/imp1/state"
  mkdir -p "${IMPORT_ROOT}/imp1/state"
  : >"${STUB_LOG}"
}

# run_apply SCRIPT CONFIRM — one apply against the stubs; rc_apply holds its exit.
run_apply() {
  local CONFIRM="$2"
  rc_apply=0
  env PATH="${WORK}/bin:${PATH}" WORK="${WORK}" STUB_LOG="${STUB_LOG}" \
    STUB_EXISTS="${STUB_EXISTS}" STUB_AUTOREMOVE="${STUB_AUTOREMOVE}" \
    STUB_RACER="${STUB_RACER}" STUB_MIGRATE_RC="${STUB_MIGRATE_RC}" \
    STUB_RESTORE_RC="${STUB_RESTORE_RC}" STUB_COUNTS_RC="${STUB_COUNTS_RC}" \
    IMPORT_ROOT="${IMPORT_ROOT}" VAULT_RESTORE="${VAULT_RESTORE}" PG_COUNTS="${PG_COUNTS}" \
    HEALTH_TIMEOUT=3 SNAPSHOT_IMAGE=alpine:latest \
    bash "$1" apply imp1 ${CONFIRM} >"${WORK}/out" 2>"${WORK}/err" || rc_apply=$?
}

# run_rollback — after a clean apply, undo it against the same stubs.
run_rollback() {
  rc_roll=0
  env PATH="${WORK}/bin:${PATH}" WORK="${WORK}" STUB_LOG="${STUB_LOG}" \
    STUB_EXISTS="${STUB_EXISTS}" STUB_AUTOREMOVE="${STUB_AUTOREMOVE}" \
    IMPORT_ROOT="${IMPORT_ROOT}" SNAPSHOT_IMAGE=alpine:latest HEALTH_TIMEOUT=3 \
    bash "${WORK}/ops/grobase-import-rollback.sh" rollback imp1 --confirm \
    >"${WORK}/rout" 2>"${WORK}/rerr" || rc_roll=$?
}

first_line() { grep -nE "$1" "${STUB_LOG}" | head -n1 | cut -d: -f1; }
state_of() { cat "${IMPORT_ROOT}/imp1/state/${1}" 2>/dev/null; }
happy_run() {
  reset
  run_apply "${APPLY_RUN}" --confirm
}
racer_probe() {
  reset
  STUB_RACER=1
  run_apply "$1" --confirm
}

order_ok() {
  local a b c d e f g h v
  a=$(first_line '^docker stop')
  b=$(first_line 'tar -czf')
  c=$(first_line '^docker start mini-baas-postgres$')
  d=$(first_line '^restore ')
  e=$(first_line '^counts ')
  f=$(first_line '^docker start -a mini-baas-db-bootstrap')
  g=$(first_line '^docker start -a mini-baas-pg-migrate')
  h=$(first_line '^docker start id_mini-baas-kong$')
  for v in "$a" "$b" "$c" "$d" "$e" "$f" "$g" "$h"; do [ -n "$v" ] || return 1; done
  [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$d" ] && [ "$d" -lt "$e" ] &&
    [ "$e" -lt "$f" ] && [ "$f" -lt "$g" ] && [ "$g" -lt "$h" ]
}

restore_args_ok() {
  grep -q '^restore ENGINES=postgres KEEP=postgres SKIP=1 SEED=postgres-all.sql.gz$' "${STUB_LOG}"
}

running_sets_ok() {
  local want="id_mini-baas-auth id_mini-baas-kong id_mini-baas-postgres"
  [ "$(cut -d' ' -f1 "${APPLY_DIR}/running.before" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" = "${want}" ] &&
    [ "$(cut -d' ' -f1 "${APPLY_DIR}/running.after" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" = "${want}" ]
}

sums_ok() {
  [ -f "${APPLY_DIR}/volumes/SHA256SUMS" ] &&
    (cd "${APPLY_DIR}/volumes" && sha256sum -c SHA256SUMS >/dev/null 2>&1)
}

plan_arm() {
  step "PLAN — without --confirm nothing is stopped, snapshotted or restored"
  reset
  run_apply "${APPLY_RUN}" ""
  if [ "${rc_apply}" -eq 0 ] && ! grep -q '^docker stop' "${STUB_LOG}" &&
    ! grep -q 'tar -czf' "${STUB_LOG}" && ! grep -q '^restore ' "${STUB_LOG}"; then
    ok "rc 0; no docker stop / tar -czf / restore in the log"
  else
    fail "rc ${rc_apply}; calls [$(tr '\n' ';' <"${STUB_LOG}")]"
  fi
}

missing_arm() {
  step "MISSING — a target one-shot that is absent is refused before any stop"
  reset
  STUB_EXISTS="mini-baas-postgres mini-baas-db-bootstrap"
  run_apply "${APPLY_RUN}" --confirm
  if [ "${rc_apply}" -eq 2 ] && grep -q 'mini-baas-pg-migrate' "${WORK}/err" &&
    ! grep -q '^docker stop' "${STUB_LOG}"; then
    ok "rc 2; stderr names mini-baas-pg-migrate; no docker stop"
  else
    fail "rc ${rc_apply}; stderr [$(tr '\n' ' ' <"${WORK}/err")]; calls [$(tr '\n' ';' <"${STUB_LOG}")]"
  fi
}

happy_arm() {
  step "HAPPY — order, restore args, state, running sets and snapshot checksums"
  happy_run
  if [ "${rc_apply}" -eq 0 ] && order_ok && restore_args_ok &&
    [ "$(state_of p-postgres)" = verified ] && running_sets_ok && sums_ok; then
    ok "rc 0; stop<tar<start<restore<counts<migrate<id_kong; postgres/1; verified; 3 non-mcp both; sums ok"
  else
    fail "rc ${rc_apply}; state [$(state_of p-postgres)]; before [$(tr '\n' ',' <"${APPLY_DIR}/running.before")]; calls [$(grep -nE 'docker|restore|counts' "${STUB_LOG}" | tr '\n' ';')]"
  fi
}

rm_arm() {
  step "RM — the --rm container is never stopped and keeps running"
  happy_run
  local stops
  stops="$(grep '^docker stop' "${STUB_LOG}" || true)"
  if [ "${rc_apply}" -eq 0 ] && [ -n "${stops}" ] &&
    ! printf '%s\n' "${stops}" | grep -q 'id_mini-baas-mcp' &&
    grep -qxF mini-baas-mcp "${WORK}/running"; then
    ok "no docker stop of id_mini-baas-mcp; mini-baas-mcp still running"
  else
    fail "rc ${rc_apply}; stops [$(tr '\n' ';' <<<"${stops}")]; running [$(tr '\n' ' ' <"${WORK}/running")]"
  fi
}

racer_arm() {
  step "RACER — a container another actor started is refused; the trap restarts the set"
  racer_probe "${APPLY_RUN}"
  if [ "${rc_apply}" -eq 1 ] && grep -q 'started by someone else' "${WORK}/err" &&
    grep -q 'mini-baas-kong-2' "${WORK}/err" && ! grep -q '^restore ' "${STUB_LOG}" &&
    [ -n "$(first_line '^docker start id_mini-baas-kong$')" ]; then
    ok "rc 1; stderr names mini-baas-kong-2; no restore; trap restarted id_mini-baas-kong"
  else
    fail "rc ${rc_apply}; stderr [$(tr '\n' ' ' <"${WORK}/err")]; restores $(grep -c '^restore ' "${STUB_LOG}")"
  fi
}

mutant_arm() {
  step "MUTANT — a copy with the racer check removed must be caught by the RACER arm"
  local mutant="${WORK}/ops/apply.mutant.sh"
  sed '/^  \[ -z "\$others" \]/d' "${APPLY}" >"${mutant}"
  cmp -s "${APPLY}" "${mutant}" && {
    fail "the mutant did not apply: the racer-check line is still present"
    return
  }
  racer_probe "${mutant}"
  if [ "${rc_apply}" -eq 1 ] && ! grep -q '^restore ' "${STUB_LOG}"; then
    fail "the guard-less copy also passed the RACER assertions (rc 1, no restore) — arm proves nothing"
  else
    ok "mutant caught: without the racer check it restores (rc ${rc_apply}), not rc-1-no-restore"
  fi
}

restore_arm() {
  step "RESTORE — a failing vault-restore leaves the stack down and names the rollback"
  reset
  STUB_RESTORE_RC=1
  run_apply "${APPLY_RUN}" --confirm
  local l after
  l=$(first_line '^restore ')
  after=$(awk -v n="${l}" 'NR>n' "${STUB_LOG}" | grep -c '^docker start id_' || true)
  if [ "${rc_apply}" -eq 1 ] && [ "$(state_of p-postgres)" = failed ] &&
    grep -q 'rollback imp1' "${WORK}/err" && [ "${after}" -eq 0 ]; then
    ok "rc 1; state failed; stderr names rollback imp1; no docker start id_ after the restore"
  else
    fail "rc ${rc_apply}; state [$(state_of p-postgres)]; starts-after-restore ${after}; stderr [$(tr '\n' ' ' <"${WORK}/err")]"
  fi
}

counts_arm() {
  step "COUNTS — differing row counts exit 3, fail the packet, and still migrate"
  reset
  STUB_COUNTS_RC=1
  run_apply "${APPLY_RUN}" --confirm
  if [ "${rc_apply}" -eq 3 ] && [ "$(state_of p-postgres)" = failed ] &&
    [ -n "$(first_line '^docker start -a mini-baas-db-bootstrap')" ] &&
    [ -n "$(first_line '^docker start -a mini-baas-pg-migrate')" ]; then
    ok "rc 3; state failed; both migrate one-shots still ran"
  else
    fail "rc ${rc_apply}; state [$(state_of p-postgres)]; one-shots [$(grep -c 'start -a' "${STUB_LOG}")]"
  fi
}

migrate_arm() {
  step "MIGRATE — a failing one-shot leaves the stack down and names the rollback"
  reset
  STUB_MIGRATE_RC=1
  run_apply "${APPLY_RUN}" --confirm
  local l after
  l=$(first_line '^docker start -a ')
  after=$(awk -v n="${l}" 'NR>n' "${STUB_LOG}" | grep -c '^docker start id_' || true)
  if [ "${rc_apply}" -eq 1 ] && grep -q 'rollback imp1' "${WORK}/err" &&
    [ -n "${l}" ] && [ "${after}" -eq 0 ]; then
    ok "rc 1; stderr names rollback imp1; no docker start id_ after the first one-shot"
  else
    fail "rc ${rc_apply}; starts-after-one-shot ${after}; stderr [$(tr '\n' ' ' <"${WORK}/err")]"
  fi
}

already_arm() {
  step "ALREADY — a packet already applied is a no-op without --force"
  reset
  printf 'applied\n' >"${IMPORT_ROOT}/imp1/state/p-postgres"
  run_apply "${APPLY_RUN}" --confirm
  if [ "${rc_apply}" -eq 0 ] && grep -q 'already applied' "${WORK}/err" &&
    ! grep -q '^docker stop' "${STUB_LOG}"; then
    ok "rc 0; stderr says already applied; no docker stop"
  else
    fail "rc ${rc_apply}; stderr [$(tr '\n' ' ' <"${WORK}/err")]; calls [$(tr '\n' ';' <"${STUB_LOG}")]"
  fi
}

rollback_arm() {
  step "ROLLBACK — after a HAPPY apply: stop by checksum, untar, restart the recorded ids"
  reset
  run_apply "${APPLY_RUN}" --confirm
  if [ "${rc_apply}" -ne 0 ]; then
    fail "setup apply failed (rc ${rc_apply}); cannot exercise the rollback"
    return
  fi
  run_rollback
  local tarx after
  tarx=$(first_line 'tar -xzf')
  after=$(awk -v n="${tarx}" 'NR>n' "${STUB_LOG}" | grep -cE '^docker start .*id_mini-baas-kong' || true)
  if [ "${rc_roll}" -eq 0 ] && grep -qE '^docker stop .*id_mini-baas-kong' "${STUB_LOG}" &&
    ! grep -qE '^docker stop .*id_mini-baas-mcp' "${STUB_LOG}" && [ -n "${tarx}" ] &&
    [ "${after}" -ge 1 ] && [ "$(state_of p-postgres)" = verified_checksum ]; then
    ok "rc 0; stopped id_mini-baas-kong not mcp; untarred; restarted id_mini-baas-kong; verified_checksum"
  else
    fail "rc ${rc_roll}; state [$(state_of p-postgres)]; restarts-after-untar ${after}"
  fi
}

# refused_arm — vault-restore exits 2 only when it refused before touching anything, so the
# stack is restarted (as before the first DROP) and no rollback is asked for.
refused_arm() {
  step "REFUSED — a restore refused before any change restarts the stack, no rollback"
  reset
  STUB_RESTORE_RC=2
  run_apply "${APPLY_RUN}" --confirm
  local l after
  l=$(first_line '^restore ')
  after=$(awk -v n="${l:-0}" 'NR>n' "${STUB_LOG}" | grep -c '^docker start id_mini-baas-kong' || true)
  if [ "${rc_apply}" -eq 1 ] && ! grep -q 'rollback imp1' "${WORK}/err" && [ -n "${l}" ] && [ "${after}" -ge 1 ]; then
    ok "rc 1; no rollback named; the trap restarted id_mini-baas-kong after the refusal"
  else
    fail "rc ${rc_apply}; restarts-after-refusal ${after}; stderr [$(tr '\n' ' ' <"${WORK}/err")]"
  fi
}

# unfinished_arm — a packet left `failed` by an earlier run must not let a new run replace that
# run's snapshot; --force is the explicit override.
unfinished_arm() {
  step "UNFINISHED — an earlier run that stopped part-way is refused unless --force"
  reset
  printf 'failed\n' >"${IMPORT_ROOT}/imp1/state/p-postgres"
  run_apply "${APPLY_RUN}" --confirm
  local refused_rc="${rc_apply}" stops
  stops=$(grep -c '^docker stop' "${STUB_LOG}" || true)
  printf 'failed\n' >"${IMPORT_ROOT}/imp1/state/p-postgres"
  run_apply "${APPLY_RUN}" "--confirm --force"
  if [ "${refused_rc}" -eq 2 ] && [ "${stops}" -eq 0 ] && [ "${rc_apply}" -eq 0 ]; then
    ok "rc 2 and no docker stop without --force; rc 0 with it"
  else
    fail "refused rc ${refused_rc} (stops ${stops}); forced rc ${rc_apply}"
  fi
}

plan_arm
missing_arm
happy_arm
rm_arm
racer_arm
restore_arm
counts_arm
migrate_arm
refused_arm
unfinished_arm
already_arm
rollback_arm
mutant_arm

if [ "${rc}" -eq 0 ]; then
  printf '%s[M226] PASS — apply stops only the recorded set, snapshots first, refuses the racer, stays down on a failed restore%s\n' "${_G}" "${_0}"
else
  printf '%s[M226] FAIL%s\n' "${_R}" "${_0}"
fi
exit "${rc}"
