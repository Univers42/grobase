#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m205-service-token-rotation.sh — the service-token rotation procedure       #
#  (G-Rotate) moves through its phases and every verifier gets the token.      #
#                                                                              #
#    (1) scripts/ops/rotate-service-token.sh on a scratch env file with        #
#        synthetic tokens: dry run writes nothing; begin mints a 64-hex        #
#        PREV and keeps the current token; begin again, swap/finish out of     #
#        order and a file without the token are refused; swap exchanges        #
#        the two; finish removes PREV and leaves the new token current;        #
#        mode 0600 survives; no output ever contains a token                   #
#    (2) compose: with ADAPTER_REGISTRY_SERVICE_TOKEN_PREV in the env file,    #
#        every service that holds INTERNAL_SERVICE_TOKEN (Go/Rust name) or     #
#        sets ADAPTER_REGISTRY_SERVICE_TOKEN itself (TS name) gets the         #
#        matching _PREV equal to it; without one, it is empty                  #
#  The verifiers' dual-accept is proven elsewhere: Go by m68 (live, static     #
#  and hmac), TS by service-token.guard.spec.ts. The Rust data plane only      #
#  sends the token (it verifies none), so it just follows the swap.           #
#  No stack needed.                                                            #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ROTATE="${M205_ROTATE:-${ROOT}/scripts/ops/rotate-service-token.sh}"
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M205] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M205] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
ENVF="${WORK}/secrets.env"
OUT="${WORK}/out.txt"
OLD="m205old$(printf '%057d' 0)"
: >"${OUT}"

# get prints key $1 from the scratch file.
get() {
  awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print }' "${ENVF}"
}

# rot runs the rotation script on the scratch file, keeping all its output.
rot() {
  bash "${ROTATE}" "$@" --file "${ENVF}" >>"${OUT}" 2>&1
}

# expect_refused fails unless the rotation script exits 1 for arguments $@.
expect_refused() {
  rot "$@"
  local rc=$?
  [ "${rc}" = 1 ] || fail "'$*' exited ${rc}, want 1 (refused)"
}

static_phases() {
  printf 'JWT_SECRET=m205jwt\nADAPTER_REGISTRY_SERVICE_TOKEN=%s\nOTHER=keep\n' "${OLD}" >"${ENVF}"
  chmod 600 "${ENVF}"
  local before
  before="$(sha256sum <"${ENVF}")"
  rot begin || fail "dry-run begin failed"
  [ "$(sha256sum <"${ENVF}")" = "${before}" ] || fail "a dry run changed the file"
  expect_refused swap
  expect_refused finish
  ok "dry run writes nothing; swap/finish before begin are refused"
  rot begin --apply || fail "begin --apply failed"
  NEW="$(get ADAPTER_REGISTRY_SERVICE_TOKEN_PREV)"
  printf '%s' "${NEW}" | grep -Eqx '[0-9a-f]{64}' || fail "begin did not mint a 64-hex PREV"
  [ "$(get ADAPTER_REGISTRY_SERVICE_TOKEN)" = "${OLD}" ] || fail "begin changed the current token"
  expect_refused begin
  ok "begin: new token in PREV, current unchanged, a second begin refused"
  rot swap --apply || fail "swap failed"
  [ "$(get ADAPTER_REGISTRY_SERVICE_TOKEN)" = "${NEW}" ] && [ "$(get ADAPTER_REGISTRY_SERVICE_TOKEN_PREV)" = "${OLD}" ] ||
    fail "swap did not exchange the two tokens"
  ok "swap: new token current, old token in PREV"
  rot finish --apply || fail "finish failed"
  [ -z "$(get ADAPTER_REGISTRY_SERVICE_TOKEN_PREV)" ] && ! grep -q '^ADAPTER_REGISTRY_SERVICE_TOKEN_PREV=' "${ENVF}" ||
    fail "finish left PREV behind"
  [ "$(get ADAPTER_REGISTRY_SERVICE_TOKEN)" = "${NEW}" ] || fail "finish lost the new token"
  [ "$(get OTHER)" = keep ] && [ "$(get JWT_SECRET)" = m205jwt ] || fail "unrelated keys changed"
  [ "$(stat -c %a "${ENVF}")" = 600 ] || fail "file mode is $(stat -c %a "${ENVF}"), want 600"
  ok "finish: PREV removed, new token current, other keys and mode 0600 kept"
}

static_refusals_and_secrecy() {
  printf 'JWT_SECRET=m205jwt\n' >"${ENVF}"
  expect_refused begin --apply
  ok "a file without ADAPTER_REGISTRY_SERVICE_TOKEN is refused (it would fall back to JWT_SECRET)"
  rot status || fail "status failed"
  if grep -qF -e "${OLD}" -e "${NEW}" -e m205jwt "${OUT}"; then
    fail "the script printed a token value"
  fi
  ok "no output line contains a token ($(wc -l <"${OUT}") lines checked)"
}

# declared_by prints, one per line, the services whose base compose file sets
# token variable $1 explicitly. The rest get it only through env_file: .env,
# which carries _PREV once rotate-service-token.sh reassembles it.
# Ponytail: finds services by their 2-space "name:" line and the variable by
# its 6-space environment indent — a service written in another layout (flow
# map, anchor-merged environment) is missed and so not checked.
declared_by() {
  awk -v k="      $1: " '/^  [a-z][a-z0-9-]*:$/ { svc = substr($1, 1, length($1) - 1) }
    index($0, k) == 1 { print svc }' "${ROOT}"/orchestrators/compose/base/*.yml | sort -u
}

# holders prints, per service that declares token variable $2, its $2_PREV
# value, rendering with the repo .env (when present) overridden by env file $1.
holders() {
  local files=()
  [ -f "${ROOT}/.env" ] && files+=(--env-file "${ROOT}/.env")
  docker compose -f "${ROOT}/docker-compose.yml" "${files[@]}" --env-file "$1" --profile '*' \
    config --format json 2>/dev/null |
    jq -r --arg k "$2" --arg svcs "$(declared_by "$2")" '($svcs | split("\n")) as $d
      | .services | to_entries[] | select(.key | IN($d[]))
      | "\(.key)=\(.value.environment[$k + "_PREV"] // "<unset>")"'
}

# check_window fails unless every holder of token variable $1 gets $1_PREV
# from the open window and an empty one from the closed window.
check_window() {
  local key="$1" n bad
  n="$(holders "${WORK}/open.env" "${key}" | wc -l)"
  [ "${n}" -ge "$2" ] || fail "only ${n} services hold ${key} — did compose render?"
  bad="$(holders "${WORK}/open.env" "${key}" | grep -v '=m205probe$' | tr '\n' ' ')"
  [ -z "${bad}" ] || fail "window open but these ${key} holders do not get the previous token: ${bad}"
  bad="$(holders "${WORK}/closed.env" "${key}" | grep -v '=$' | tr '\n' ' ')"
  [ -z "${bad}" ] || fail "no window but ${key}_PREV is non-empty on: ${bad}"
  ok "all ${n} ${key} holders get ${key}_PREV in a window, an empty one outside it"
}

compose_mapping() {
  echo "ADAPTER_REGISTRY_SERVICE_TOKEN_PREV=" >"${WORK}/closed.env"
  echo "ADAPTER_REGISTRY_SERVICE_TOKEN_PREV=m205probe" >"${WORK}/open.env"
  check_window INTERNAL_SERVICE_TOKEN 6
  check_window ADAPTER_REGISTRY_SERVICE_TOKEN 3
}

step "(1) rotation procedure on a scratch file"
static_phases
static_refusals_and_secrecy
step "(2) compose delivers the previous token to every verifier"
compose_mapping
printf '\033[0;32m[M205] OK — begin → swap → finish rotates the service token and every holder sees the window\033[0m\n'
