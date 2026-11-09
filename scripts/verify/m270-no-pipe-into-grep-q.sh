#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m270-no-pipe-into-grep-q.sh — no script pipes a multi-write producer into   #
#  an early-exiting grep                                                       #
#                                                                              #
#  Under `set -o pipefail`, `producer | grep -q pat` returns 141 when grep     #
#  matches and exits while the producer is still writing: a present match     #
#  reads as absent. CI run 42262662057 failed M183 that way (2026-11-06), and  #
#  the negated form (`! docker logs | grep -q 'PRIVATE KEY'`) passes on a log  #
#  that holds the key. The fix is to read the whole output first:             #
#      grep -q pat <<<"$(producer)"                                            #
#                                                                              #
#   SCAN     no bash file under scripts/ holds such a pipe outside a comment.  #
#   MUTANTS  a planted `docker logs | grep -q` and a planted                   #
#            `grep -v | grep -q` are both caught, so the scan is not vacuous.  #
#                                                                              #
#  Static only: no network, no stack, no credential read, no value printed.    #
#                                                                              #
# **************************************************************************** #
set -uo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

_B=$'\033[0;36m' _G=$'\033[0;32m' _R=$'\033[0;31m' _0=$'\033[0m'
rc=0
step() { printf '%s[M270] %s%s\n' "${_B}" "$1" "${_0}"; }
ok() { printf '%s  ✓ %s%s\n' "${_G}" "$1" "${_0}"; }
fail() {
  printf '%s[M270] FAIL — %s%s\n' "${_R}" "$1" "${_0}"
  rc=1
}

# Caveat: line-based regex over the producers that write in more than one chunk (log
# streams, filters, HTTP bodies). It misses a pipe split across a backslash continuation
# or a producer it does not name (a custom function), and it flags a quoted string that
# merely contains such a pipe. A producer of one short write (`printf '%s' "$x"`) is safe
# and deliberately not listed.
PRODUCER='(docker( compose)? (logs|exec)|journalctl|grep -v|sed |awk |cat |curl |ss |mc cat)'
PATTERN="${PRODUCER}[^|]*\\|( *grep [^|]*\\|)* *grep -[A-Za-z]*q"

# offenders <dir...>: file:line of every non-comment line that matches PATTERN, in bash
# files only. A `#!/bin/sh` script has no pipefail, so its pipe status is grep's and correct.
offenders() {
  local f
  grep -rlE --include='*.sh' --exclude="${0##*/}" -- "${PATTERN}" "$@" 2>/dev/null |
    while IFS= read -r f; do
      head -1 "${f}" | grep -qE '^#! */bin/(sh|dash)' || grep -HnE -- "${PATTERN}" "${f}"
    done | grep -vE '^[^:]+:[0-9]+: *#'
}

step "1/2 SCAN — bash under scripts/"
found="$(offenders "${ROOT}/scripts")"
if [ -z "${found}" ]; then
  ok "no multi-write producer is piped into grep -q"
else
  fail "pipe into grep -q (read the output first: grep -q pat <<<\"\$(producer)\"):"
  printf '%s\n' "${found//"${ROOT}/"/}"
fi

step "2/2 MUTANTS — a planted pipe is caught"
work="$(mktemp -d)" || exit 1
trap 'rm -rf "${work}"' EXIT
mutant() {
  printf '#!/usr/bin/env bash\n%s\n' "$1" >"${work}/m.sh"
  if [ -n "$(offenders "${work}")" ]; then ok "caught: $2"; else fail "missed: $2"; fi
}
mutant '! docker logs "${C}" 2>&1 | grep -q "PRIVATE KEY" || fail leak' "negated docker logs | grep -q"
mutant 'grep -v "^#" "${F}" | grep -qE "HMAC" && fail set' "grep -v file | grep -qE"
mutant 'docker logs "${C}" | grep accepted | grep -q TLS' "a pipe through a middle grep"
printf '%s\n' '  # docker logs "${C}" | grep -q x' >"${work}/m.sh"
if [ -z "$(offenders "${work}")" ]; then ok "a comment line is not flagged"; else fail "a comment line was flagged"; fi
printf '#!/bin/sh\ndocker logs "$C" | grep -q x\n' >"${work}/m.sh"
if [ -z "$(offenders "${work}")" ]; then ok "a #!/bin/sh file (no pipefail) is not flagged"; else fail "a #!/bin/sh file was flagged"; fi

[ "${rc}" = 0 ] && printf '%s[M270] PASS — no producer is piped into an early-exiting grep%s\n' "${_G}" "${_0}"
exit "${rc}"
