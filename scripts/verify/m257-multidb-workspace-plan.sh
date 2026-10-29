#!/usr/bin/env bash
# **************************************************************************** #
#  m257-multidb-workspace-plan.sh — the all-engine workspace seeder is safe     #
#  offline. scripts/seed/multidb-workspace.sh (plan item W1) writes to ten      #
#  engines and a workspace; its default is --plan. This gate runs it with fake  #
#  ids and every client binary PATH-shimmed to fail loudly, and holds: the ten  #
#  engines appear in order, each with its own mdw_ mount and association; the   #
#  two shared workspaces and malformed ids are refused; no --apply means no     #
#  client is ever invoked; --teardown --plan names only mdw_ objects. MUTANTs   #
#  prove the shim and the prefix check are awake. Static, no stack, no network. #
#  Caveat: it proves what the PLAN says and that plan mode stays off the wire;  #
#  it cannot prove the --apply path does what its plan lines claim — that needs #
#  a live stack and a human go.                                                 #
# **************************************************************************** #
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SEED="${ROOT}/scripts/seed/multidb-workspace.sh"
ok() { printf '\033[0;32m[M257] PASS: %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M257] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

WS="11111111-2222-4333-8444-555555555555"
WS32="11111111222243338444555555555555"
OWNER="66666666-7777-4888-9999-000000000000"
WANT_ORDER="postgresql cockroachdb mysql mariadb mongodb redis sqlite mssql http dynamodb"

SHIM="$(mktemp -d)"
trap 'rm -rf "${SHIM}"' EXIT
for tool in docker curl psql aws sqlcmd mongosh mysql mariadb redis-cli cockroach openssl; do
  printf '#!/bin/sh\necho "%s $*" >>"%s/calls"\nexit 97\n' "${tool}" "${SHIM}" >"${SHIM}/${tool}"
  chmod +x "${SHIM}/${tool}"
done

# run ARGS… — the seeder under the shim; stdout+stderr in $OUT, exit code in $RC.
run() {
  rm -f "${SHIM}/calls"
  set +e
  OUT="$(PATH="${SHIM}:${PATH}" MDW_HTTP_BASE_URL='' bash "${SEED}" "$@" 2>&1)"
  RC=$?
  set -e
}
no_calls() { [[ ! -s "${SHIM}/calls" ]] || fail "$1 invoked a client: $(head -3 "${SHIM}/calls")"; }
engine_order() { printf '%s\n' "${OUT}" | awk '$1 == "PLAN" && $2 != "prelude" && !seen[$2]++ { printf "%s%s", sep, $2; sep = " " }'; }
# only_mdw_targets: every target=<name> token starts with mdw_ and there is at least one.
only_mdw_targets() {
  local targets bad
  targets="$(grep -o 'target=[^ ]*' <<<"$1" | cut -d= -f2-)"
  [[ -n "${targets}" ]] || return 1
  bad="$(grep -v '^mdw_' <<<"${targets}" || true)"
  [[ -z "${bad}" ]]
}

[[ -f "${SEED}" ]] || fail "missing ${SEED#"${ROOT}"/}"

# 1) default (no mode flag) is plan: exit 0, the ten engines in order, nothing invoked.
run --workspace "${WS}" --owner "${OWNER}"
[[ "${RC}" == "0" ]] || fail "plan run exited ${RC}: $(tail -3 <<<"${OUT}")"
grep -q '^mode: plan' <<<"${OUT}" || fail "no --apply did not select plan mode"
no_calls "plan mode"
got="$(engine_order)"
[[ "${got}" == "${WANT_ORDER}" ]] || fail "engine order is '${got}', want '${WANT_ORDER}'"
ok "default mode is plan; ten engines in order; no client invoked"

for e in ${WANT_ORDER}; do
  grep -Eq "^PLAN ${e} .*register mount target=mdw_${WS32}_${e}( |$)" <<<"${OUT}" ||
    fail "${e}: no 'register mount target=mdw_${WS32}_${e}' plan line"
  grep -Eq "^PLAN ${e} .*associate .*workspace ${WS}" <<<"${OUT}" ||
    fail "${e}: no workspace association plan line"
done
only_mdw_targets "${OUT}" || fail "the apply plan names a non-mdw_ object"
grep -Eq 'relation|contract|edge' <<<"$(grep '^PLAN' <<<"${OUT}")" &&
  fail "the plan declares relations/contracts/edges — blocked until G12"
ok "each engine registers its own mdw_ mount and associates it; no edges or contracts"

# 2) the shared workspaces are refused (any case), as are malformed ids and a missing owner.
for refused in ac3e0000-0000-4000-a000-000000000001 0EA96910-277A-49D6-901C-524B147CC009; do
  run --workspace "${refused}" --owner "${OWNER}"
  [[ "${RC}" != "0" ]] || fail "shared workspace ${refused} was not refused"
  grep -qi 'refus' <<<"${OUT}" || fail "refusal of ${refused} has no clear message: ${OUT}"
  no_calls "the refusal of ${refused}"
done
run --workspace "not-a-uuid" --owner "${OWNER}"
[[ "${RC}" != "0" ]] || fail "a malformed workspace id was accepted"
run --workspace "${WS}"
[[ "${RC}" != "0" ]] || fail "a missing --owner was accepted"
run --workspace "${WS}" --owner "${OWNER}" --plan --apply
[[ "${RC}" != "0" ]] || fail "--plan with --apply was accepted"
no_calls "argument validation"
ok "WS_ACME / WS_MAIN refused; malformed ids, missing owner, --plan+--apply refused"

# 3) --teardown defaults to plan and names only mdw_ objects, ten engines in order.
run --workspace "${WS}" --owner "${OWNER}" --teardown
[[ "${RC}" == "0" ]] || fail "teardown plan exited ${RC}: $(tail -3 <<<"${OUT}")"
grep -q '^mode: plan' <<<"${OUT}" || fail "--teardown without --apply did not select plan mode"
no_calls "teardown plan"
got="$(engine_order)"
[[ "${got}" == "${WANT_ORDER}" ]] || fail "teardown engine order is '${got}', want '${WANT_ORDER}'"
only_mdw_targets "${OUT}" || fail "teardown plan names a non-mdw_ object: $(grep -o 'target=[^ ]*' <<<"${OUT}" | grep -v 'target=mdw_' | head -3)"
ok "--teardown --plan lists only mdw_ objects, ten engines"

# MUTANTs: the checks above are not asleep.
only_mdw_targets "PLAN postgresql 03 drop database target=commerce" &&
  fail "MUTANT: a non-mdw_ target passed the prefix check"
run --workspace "${WS}" --owner "${OWNER}" --apply
[[ -s "${SHIM}/calls" ]] || fail "MUTANT: --apply never reached a shimmed client — the no-call check is vacuous"
[[ "${RC}" != "0" ]] || fail "MUTANT: --apply against shimmed clients reported success"
ok "MUTANT: a non-mdw_ target is caught; --apply does reach the (shimmed) clients"
