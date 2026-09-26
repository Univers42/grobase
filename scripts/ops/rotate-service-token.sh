#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  rotate-service-token.sh — rotate ADAPTER_REGISTRY_SERVICE_TOKEN (the        #
#  internal service token every plane shares) with no request refused.        #
#                                                                              #
#  Usage: rotate-service-token.sh <status|begin|swap|finish> [--file F]        #
#                                 [--apply]                                    #
#    status  which phase the file is in                                        #
#    begin   mint a new token into ADAPTER_REGISTRY_SERVICE_TOKEN_PREV:        #
#            every verifier now accepts it, senders still send the old one     #
#    swap    exchange the two: senders send the new token, verifiers still     #
#            accept the old one from peers not rolled yet                      #
#    finish  drop the old token (after baas_service_token_previous_accepted    #
#            _total has stayed flat — alert PreviousServiceTokenInUse quiet)   #
#  After each --apply, roll the stack (`make up` with the same PACKAGE/        #
#  EDITION) and let it settle before the next phase. At every point of every   #
#  roll, each token a sender uses is one each verifier accepts.                #
#                                                                              #
#  F defaults to .env.secrets (the source layer; .env is then reassembled)     #
#  or, without one, .env. Dry run unless --apply. Prints lengths, never a      #
#  token. Exit: 0 done/dry-run, 1 refused (wrong phase, no token), 2 usage.    #
#                                                                              #
#  Ponytail: every container loads .env, so each roll recreates the whole      #
#  stack — no 401s, but a short restart per phase. Tokens held in Vault        #
#  (SECURITY_MODE=max) are not edited here; rotate them at the source.         #
#                                                                              #
# **************************************************************************** #
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
KEY="ADAPTER_REGISTRY_SERVICE_TOKEN"
PREV_KEY="${KEY}_PREV"

usage() {
  sed -n '6,24p' "$0" | sed 's/^#  \{0,1\}//; s/ *#$//'
  exit 2
}

refuse() {
  printf 'rotate-service-token: %s\n' "$*" >&2
  exit 1
}

# value prints the value of key $1 in file $2 (empty when absent).
value() {
  awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); v = $0 } END { printf "%s", v }' "$2"
}

# describe prints a key's state without its value.
describe() {
  local v
  v="$(value "$1" "$2")"
  if [ -n "${v}" ]; then printf '%s: set (%d chars)\n' "$1" "${#v}"; else printf '%s: empty\n' "$1"; fi
}

# rewrite writes file $1 with key $2 set to $3 (removed when $3 is empty),
# atomically and with the original file's mode.
rewrite() {
  local file="$1" key="$2" val="$3" tmp
  tmp="$(mktemp "${file}.rotate.XXXXXX")"
  chmod --reference="${file}" "${tmp}"
  awk -F= -v k="${key}" -v v="${val}" '
    $1 == k { if (v != "" && !done) { print k "=" v; done = 1 } next }
    { print }
    END { if (v != "" && !done) print k "=" v }' "${file}" >"${tmp}"
  mv "${tmp}" "${file}"
}

# phase names the rotation phase of file $1.
phase() {
  [ -n "$(value "${PREV_KEY}" "$1")" ] && echo "window open" || echo "no rotation window"
}

# plan prints the change for phase $1 on file $2 and applies it when $3 = 1.
plan() {
  local cmd="$1" file="$2" apply="$3" cur prev new
  cur="$(value "${KEY}" "${file}")"
  prev="$(value "${PREV_KEY}" "${file}")"
  [ -n "${cur}" ] || refuse "${KEY} is not set in ${file} — the stack falls back to JWT_SECRET; set it first"
  case "${cmd}" in
  begin)
    [ -z "${prev}" ] || refuse "a rotation is already open in ${file} (run swap or finish)"
    new="$(openssl rand -hex 32)"
    echo "begin: ${PREV_KEY} <- new token (${#new} chars); ${KEY} unchanged"
    [ "${apply}" = 1 ] && rewrite "${file}" "${PREV_KEY}" "${new}"
    ;;
  swap)
    [ -n "${prev}" ] || refuse "no rotation open in ${file} (run begin first)"
    echo "swap: ${KEY} <-> ${PREV_KEY}"
    [ "${apply}" = 1 ] && rewrite "${file}" "${KEY}" "${prev}" && rewrite "${file}" "${PREV_KEY}" "${cur}"
    ;;
  finish)
    [ -n "${prev}" ] || refuse "no rotation open in ${file}"
    echo "finish: ${PREV_KEY} removed"
    [ "${apply}" = 1 ] && rewrite "${file}" "${PREV_KEY}" ""
    ;;
  esac
  return 0
}

# reassemble rebuilds the repo's .env when the edited file is its
# .env.secrets layer (assemble-env.sh only ever works on the repo root).
reassemble() {
  [ "$1" = "${ROOT}/.env.secrets" ] || return 0
  bash "${ROOT}/scripts/env/assemble-env.sh" >/dev/null
  echo "reassembled .env from the layers"
}

main() {
  local cmd="${1:-}" file="" apply=0
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
    --file) file="${2:?--file needs a path}" && shift ;;
    --apply) apply=1 ;;
    *) usage ;;
    esac
    shift
  done
  [ -n "${file}" ] || { [ -f "${ROOT}/.env.secrets" ] && file="${ROOT}/.env.secrets" || file="${ROOT}/.env"; }
  [ -f "${file}" ] || refuse "${file} not found"
  case "${cmd}" in
  status)
    echo "${file}: $(phase "${file}")"
    describe "${KEY}" "${file}"
    describe "${PREV_KEY}" "${file}"
    ;;
  begin | swap | finish)
    plan "${cmd}" "${file}" "${apply}"
    if [ "${apply}" = 1 ]; then
      reassemble "${file}"
      echo "applied — now roll the stack: make up (same PACKAGE/EDITION as running)"
    else
      echo "dry run — nothing written; add --apply"
    fi
    ;;
  *) usage ;;
  esac
}

main "$@"
