#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m218-vault-restore-fresh-volume.sh — the vault restore lands on a FRESH      #
#  volume, and a rootless host can run 42ctl                                   #
#                                                                              #
#  `make vault-restore` is how a fresh machine gets the team data (groot's      #
#  `make all` → restore-if-empty calls it). Three ways it failed on an EMPTY    #
#  stack, all measured 2026-10-10 on develop 7abe647d:                         #
#                                                                              #
#   PG      pg_dumpall --clean's DROP DATABASE has no IF EXISTS: on a fresh     #
#           volume every absent database prints "does not exist" and the       #
#           replay gate called the restore failed after every table had landed.#
#   REDIS   docker cp leaves dump.rdb owned by the caller, 0600; redis-server   #
#           runs as `redis` and the throwaway loader cannot read it.           #
#   MINIO   mktemp -d is 0700 and grobase-mc runs as uid 1001: mc mirror said   #
#           "permission denied", exited 0, and the chat bucket came back EMPTY. #
#   CTL     on rootless Docker the caller's uid is unmapped inside the 42ctl    #
#           container; CTL_USER=0:0 is the knob and every --user must honour it.#
#   MUTANTS each check refuses the way back in.                                #
#                                                                              #
#  Static only: no network, no stack, no credential read, no value printed.    #
#                                                                              #
# **************************************************************************** #
set -uo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VR="${ROOT}/scripts/ops/vault-restore.sh"
CTL="${ROOT}/scripts/vault/ctl-env.sh"

_B=$'\033[0;36m' _G=$'\033[0;32m' _R=$'\033[0;31m' _0=$'\033[0m'
rc=0
step() { printf '%s[M218] %s%s\n' "${_B}" "$1" "${_0}"; }
ok() { printf '%s  ✓ %s%s\n' "${_G}" "$1" "${_0}"; }
fail() {
  printf '%s[M218] FAIL — %s%s\n' "${_R}" "$1" "${_0}"
  rc=1
}

for f in "${VR}" "${CTL}"; do
  [ -f "${f}" ] || {
    fail "missing ${f#"${ROOT}"/}"
    exit 1
  }
done

# fn_body <file> <name> — the lines of one shell function, so order can be checked.
fn_body() { awk -v fn="$2" '$0 == fn"() {" {p=1} p {print} p && /^}/ {exit}' "$1"; }

# ordered <file> <fn> <first> <second> <third> — the three fixed strings occur in that order.
ordered() {
  local body a b c
  body="$(fn_body "$1" "$2")"
  a="$(printf '%s\n' "${body}" | grep -nF -- "$3" | head -1 | cut -d: -f1)"
  b="$(printf '%s\n' "${body}" | grep -nF -- "$4" | head -1 | cut -d: -f1)"
  c="$(printf '%s\n' "${body}" | grep -nF -- "$5" | head -1 | cut -d: -f1)"
  [ -n "${a}" ] && [ -n "${b}" ] && [ -n "${c}" ] && [ "${a}" -lt "${b}" ] && [ "${b}" -lt "${c}" ]
}

# benign_pattern <file> — PG_BENIGN's value, read as text; the script is never executed.
benign_pattern() { sed -n "s/^PG_BENIGN='\(.*\)'\$/\1/p" "$1"; }

# The predicates take the file to judge, so the mutants arm can aim them at a copy.
pg_benign_ok() {
  local pat
  pat="$(benign_pattern "$1")"
  [ -n "${pat}" ] && printf 'ERROR:  database "commerce" does not exist\n' | grep -qE -- "${pat}"
}
pg_strict_ok() {
  local pat
  pat="$(benign_pattern "$1")"
  [ -n "${pat}" ] && ! printf 'ERROR:  relation "osionos_pages" does not exist\n' | grep -qE -- "${pat}"
}
redis_ok() {
  ordered "$1" restore_redis 'docker cp "$SEED_DIR/redis.rdb"' \
    'chown "$(stat -c %u:%g /d)" /d/dump.rdb' 'docker run -d --name vault-restore-redis'
}
minio_ok() {
  ordered "$1" restore_minio 'tar -xzf "$SEED_DIR/minio.tar.gz"' \
    'chmod -R a+rX "$stage"' 'mirror --quiet /in seed'
}
ctl_ok() {
  grep -qF -- '--user "${CTL_USER:-$(id -u):$(id -g)}"' "$1" &&
    [ "$(grep -F -- '--user' "$1" | grep -vcF 'CTL_USER:-')" -eq 0 ]
}

pg_arm() {
  step "PG — DROP DATABASE on a fresh volume is benign, a missing relation is not"
  pg_benign_ok "${VR}" && ok 'ERROR:  database "x" does not exist passes the replay gate' ||
    fail "DROP DATABASE on a fresh volume still fails the replay (PG_BENIGN)"
  pg_strict_ok "${VR}" && ok 'ERROR:  relation "x" does not exist is still a real error' ||
    fail "PG_BENIGN hides a missing relation — real replay errors would pass"
}

redis_arm() {
  step "REDIS — the rdb is handed to the redis user between docker cp and the loader"
  redis_ok "${VR}" && ok "chown to the data dir's owner sits between docker cp and the throwaway start" ||
    fail "restore_redis does not chown dump.rdb before the throwaway redis starts"
}

minio_arm() {
  step "MINIO — the stage is opened before mc mounts it"
  minio_ok "${VR}" && ok "chmod -R a+rX sits between the tar extraction and mc mirror" ||
    fail "restore_minio mounts a 0700 stage for the uid-1001 mc user"
}

ctl_arm() {
  step "CTL — every 42ctl docker run honours CTL_USER"
  ctl_ok "${CTL}" && ok 'every --user flag reads ${CTL_USER:-caller}' ||
    fail "ctl-env.sh pins a docker run to the caller's uid with no CTL_USER override"
}

mutants_arm() {
  step "MUTANTS — each check refuses the way back in"
  local work vr ctl
  work="$(mktemp -d)" || return
  trap 'rm -rf "${work}"' RETURN
  vr="${work}/vault-restore.sh"
  ctl="${work}/ctl-env.sh"

  sed '/^PG_BENIGN=/s/|^ERROR:  database "\[^"\]\*" does not exist\$//' "${VR}" >"${vr}"
  pg_benign_ok "${vr}" && fail "mutant survived: the does-not-exist pattern removed is not caught" ||
    ok "refused: DROP DATABASE made fatal again"

  sed '/^PG_BENIGN=/s/|^ERROR:  database "\[^"\]\*" does not exist\$/|^ERROR:  .* does not exist$/' "${VR}" >"${vr}"
  pg_strict_ok "${vr}" && fail "mutant survived: a catch-all does-not-exist is not caught" ||
    ok "refused: a catch-all does-not-exist pattern (would hide missing relations)"

  sed '/chown "\$(stat -c %u:%g \/d)" \/d\/dump.rdb/d' "${VR}" >"${vr}"
  redis_ok "${vr}" && fail "mutant survived: the rdb chown removed is not caught" ||
    ok "refused: the rdb left owned by the caller"

  sed '/chmod -R a+rX "\$stage"/d' "${VR}" >"${vr}"
  minio_ok "${vr}" && fail "mutant survived: the stage chmod removed is not caught" ||
    ok "refused: the minio stage left 0700"

  sed 's/\${CTL_USER:-\$(id -u):\$(id -g)}/$(id -u):$(id -g)/' "${CTL}" >"${ctl}"
  ctl_ok "${ctl}" && fail "mutant survived: a hard-pinned --user is not caught" ||
    ok "refused: --user pinned back to the caller"
}

pg_arm
redis_arm
minio_arm
ctl_arm
mutants_arm

if [ "${rc}" -eq 0 ]; then
  printf '%s[M218] PASS — the vault restore lands on a fresh volume; 42ctl runs on a rootless host%s\n' "${_G}" "${_0}"
else
  printf '%s[M218] FAIL%s\n' "${_R}" "${_0}"
fi
exit "${rc}"
