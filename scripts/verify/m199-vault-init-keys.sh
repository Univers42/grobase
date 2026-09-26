#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m199-vault-init-keys.sh — the compose Vault's unseal key stays private, and  #
#  a lost key file never silently destroys Vault's storage.                     #
#                                                                              #
#  init-vault.sh wrote /vault/data/.vault-keys.json (the unseal key AND the     #
#  root token) then chmod'ed it 0644, and when Vault was initialized but that   #
#  file was missing it deleted every file of Vault's storage and re-initialized #
#  — every secret, every CMEK key, gone without a question.                     #
#                                                                              #
#  Builds infra/docker/services/vault under a throwaway tag, runs a throwaway   #
#  vault server + init-vault.sh on a throwaway network and volume:              #
#    (a) fresh init: the key file is 600 vault                                  #
#    (b) key file lost: init refuses (non-zero, prints the deliberate reset)    #
#        and storage survives — key file put back, a sentinel still reads       #
#  The old wipe had no opt-out worth keeping: it ran under a live, unsealed     #
#  server that kept reporting "initialized", so it lost the data AND failed.    #
#  Needs docker. Everything the gate creates goes in an EXIT trap.              #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CTX="${ROOT}/infra/docker/services/vault"
P="m199gate$$"
TAG="${P}:vault"
KEYS=/vault/data/.vault-keys.json
T="$(mktemp -d)" || exit 1
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M199] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M199] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

# cleanup removes the server, network, volume, image and temp dir this run made.
cleanup() {
  docker rm -f "${P}-vault" >/dev/null 2>&1 || true
  docker network rm "${P}" >/dev/null 2>&1 || true
  docker volume rm "${P}" >/dev/null 2>&1 || true
  docker rmi "${TAG}" >/dev/null 2>&1 || true
  rm -rf "${T}"
}
trap cleanup EXIT

# in_vol CMD... runs CMD in the vault image as the vault user, with the gate volume.
in_vol() {
  docker run --rm -i --network "${P}" -e VAULT_ADDR=http://vault:8200 -v "${P}:/vault/data" \
    --entrypoint "$1" "${TAG}" "${@:2}"
}

# run_init [ENV=VAL…] runs init-vault.sh once; prints its output, returns its status.
run_init() {
  local envs=() e
  for e in "$@"; do envs+=(-e "$e"); done
  docker run --rm --network "${P}" -e VAULT_ADDR=http://vault:8200 "${envs[@]}" \
    -v "${P}:/vault/data" --entrypoint /vault/scripts/init-vault.sh "${TAG}" >"${T}/init.log" 2>&1
}

# kv ACTION ARGS… runs `vault kv ACTION` against the gate server with the key file's
# root token (flags before positional args, as the vault CLI requires).
kv() {
  local token
  token="$(in_vol jq -r .root_token "${KEYS}")" || return 1
  docker run --rm --network "${P}" -e VAULT_ADDR=http://vault:8200 -e VAULT_TOKEN="${token}" \
    --entrypoint vault "${TAG}" kv "$1" "${@:2}" </dev/null
}

command -v docker >/dev/null && docker info >/dev/null 2>&1 || fail "docker is not reachable"
step "0/2 build ${CTX} as ${TAG}; server on a throwaway network + volume"
docker build -q -t "${TAG}" "${CTX}" >"${T}/build.log" 2>&1 || {
  tail -5 "${T}/build.log" >&2
  fail "vault image build failed"
}
docker network create "${P}" >/dev/null && docker volume create "${P}" >/dev/null || fail "network/volume create failed"
docker run -d --name "${P}-vault" --network "${P}" --network-alias vault --cap-add IPC_LOCK -e SKIP_SETCAP=1 \
  -e VAULT_ADDR=http://127.0.0.1:8200 -v "${P}:/vault/data" "${TAG}" vault server -config=/vault/config/vault.hcl >/dev/null ||
  fail "vault server did not start"
ok "image built, server started"

step "1/2 fresh init — the key file (unseal key + root token) is private"
run_init || {
  tail -8 "${T}/init.log" >&2
  fail "(a) first init-vault.sh run failed"
}
mode="$(in_vol stat -c '%a %U' "${KEYS}")"
[ "${mode}" = "600 vault" ] || fail "(a) ${KEYS} is '${mode}', want '600 vault' — the unseal key and root token are readable by any uid"
ok "(a) ${KEYS} is ${mode}"
kv put -mount=secret m199/sentinel canary=alive >/dev/null || fail "(a) could not write the sentinel secret"

step "2/2 key file lost — init must refuse, not wipe Vault's storage"
in_vol cp "${KEYS}" /vault/data/m199-keys.bak && in_vol rm -f "${KEYS}" || fail "(b) could not stash the key file"
if run_init; then
  fail "(b) init-vault.sh exited 0 with the key file gone — it reset Vault's storage (every secret lost)"
fi
grep -q 'docker volume rm' "${T}/init.log" || fail "(b) the refusal does not say how to reset on purpose: $(tail -3 "${T}/init.log")"
grep -q 'clean storage' "${T}/init.log" && fail "(b) init started wiping storage before refusing"
ok "(b) refused non-zero, touched nothing, printed the deliberate reset"
in_vol mv /vault/data/m199-keys.bak "${KEYS}" || fail "(b) could not restore the key file"
run_init || {
  tail -8 "${T}/init.log" >&2
  fail "(b) init with the key file restored failed"
}
kv get -mount=secret -field=canary m199/sentinel | grep -qx alive || fail "(b) the sentinel secret is gone — storage was not preserved"
ok "(b) key file restored → the sentinel secret still reads 'alive' (storage intact)"

printf '\033[0;32m[M199] PASS — unseal key 600 vault; a lost key file is refused, never a silent wipe\033[0m\n'
