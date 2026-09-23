#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m191-vault-drop-privileges.sh — with VAULT_DROP_PRIVILEGES_ENABLED on, the  #
#  Fly Vault image serves as the vault user; unset, it stays HEAD's root       #
#                                                                              #
#  C-5: Dockerfile.fly runs Vault as root. The fix is the flag in              #
#  fly-entrypoint.sh (OFF by default = byte-parity); this gate is its proof.   #
#  It builds Dockerfile.fly under a throwaway tag and boots it --network none  #
#  on fresh named volumes forced to root:root 755 (a new Fly volume's shape):  #
#    off  flag unset: the vault server and PID 1 run as uid 0 (HEAD), and      #
#         /vault + config/policies/scripts stay vault-owned (HEAD's image).    #
#         The probe seeing uid 0 here is what keeps the ON leg's 'not root'    #
#         from passing vacuously                                               #
#    on   flag 1: the vault server and PID 1 run as the image's vault uid      #
#         (real and effective); keys file 600 vault:vault; the volume handed   #
#         to vault; the vault uid cannot create a file in /vault or its        #
#         config/policy/script dirs; after `docker restart` it unseals from    #
#         the kept keys file, still as vault, without a second init            #
#    neg  flag 1 with VAULT_KEYS_FILE in a missing subdir: stops non-zero      #
#         before `vault operator init`, naming the missing directory           #
#                                                                              #
#  Needs docker. Below 2.5 GB free in docker's root dir it prints SKIP and     #
#  exits 77, never 0: a gate that did not look has not passed. The base        #
#  image is pulled by the build and removed again if it was absent before;     #
#  tag, intermediates, containers, volumes and temp dir go in an EXIT trap.    #
#                                                                              #
#  Mutant hook: M191_ENTRYPOINT=<path> builds with another entrypoint; one     #
#  that keeps root, loosens the keys file or leaves the scripts writable       #
#  must go red. M191_MIN_FREE_MB overrides the 2560 MB disk guard.             #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CTX="${ROOT}/infra/docker/services/vault"
ENTRY="${M191_ENTRYPOINT:-${CTX}/scripts/fly-entrypoint.sh}"
MIN_FREE_MB="${M191_MIN_FREE_MB:-2560}"
BASE="$(awk '$1 == "FROM" { print $2; exit }' "${CTX}/Dockerfile.fly")"
P="m191gate$$"
TAG="${P}:vault-fly"
KEYS=/vault/data/.vault-keys.json
READY='mapped to track-binocle-env-reader'
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M191] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M191] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

command -v docker >/dev/null && docker info >/dev/null 2>&1 || fail "docker is not reachable"
[ -n "${BASE}" ] || fail "no FROM line in ${CTX}/Dockerfile.fly"
[ -r "${ENTRY}" ] || fail "entrypoint ${ENTRY} is not readable"
FREE_KB="$(df -Pk "$(docker info -f '{{.DockerRootDir}}')" | awk 'NR == 2 { print $4 }')"
if [ "${FREE_KB:-0}" -lt $((MIN_FREE_MB * 1024)) ]; then
  printf '\033[0;33m[M191] SKIP — %s MB free for docker, the build needs %s MB; nothing built, nothing proven\033[0m\n' \
    "$((${FREE_KB:-0} / 1024))" "${MIN_FREE_MB}" >&2
  exit 77
fi
BASE_WAS_PRESENT=0
docker image inspect "${BASE}" >/dev/null 2>&1 && BASE_WAS_PRESENT=1
T="$(mktemp -d)" || exit 1

# cleanup removes the gate's containers, volumes, image and any build
# intermediates it left, the base image when this run pulled it, and the temp dir.
cleanup() {
  local leg
  for leg in off on neg; do
    docker rm -f "${P}-${leg}" >/dev/null 2>&1 || true
    docker volume rm "${P}-${leg}" >/dev/null 2>&1 || true
  done
  docker rmi "${TAG}" >/dev/null 2>&1 || true
  if [ -f "${T}/build.log" ]; then
    awk '/^ ---> [0-9a-f]{12}$/ { print $2 }' "${T}/build.log" | tail -n +2 | tac |
      xargs -r docker rmi >/dev/null 2>&1 || true
  fi
  [ "${BASE_WAS_PRESENT}" = 1 ] || docker rmi "${BASE}" >/dev/null 2>&1 || true
  rm -rf "${T}"
}
trap cleanup EXIT

# build_image stages the vault build context in the temp dir with the entrypoint
# under test and builds Dockerfile.fly with the legacy builder and --no-cache:
# BuildKit would leave cache behind, and uncached steps share no intermediate
# image with anyone else's build, so cleanup can remove every one it logged.
build_image() {
  mkdir -p "${T}/ctx" && cp -R "${CTX}/." "${T}/ctx/" &&
    cp "${ENTRY}" "${T}/ctx/scripts/fly-entrypoint.sh" || fail "cannot stage the build context"
  DOCKER_BUILDKIT=0 docker build --no-cache --force-rm -f "${T}/ctx/Dockerfile.fly" -t "${TAG}" "${T}/ctx" \
    >"${T}/build.log" 2>&1 || {
    tail -n 20 "${T}/build.log" >&2
    fail "docker build of Dockerfile.fly failed"
  }
}

# boot starts container $1 (--network none) on a fresh volume of the same name,
# first forced to root:root 755, the shape of a new Fly volume. Extra args go to
# docker run.
boot() {
  local name="$1" vol shape
  shift
  vol="type=volume,src=${name},dst=/vault/data,volume-nocopy"
  docker volume create "${name}" >/dev/null || fail "cannot create volume ${name}"
  shape="$(docker run --rm --entrypoint sh --mount "${vol}" "${TAG}" \
    -c 'chown root:root /vault/data && chmod 755 /vault/data && stat -c "%u:%g %a" /vault/data')"
  [ "${shape}" = "0:0 755" ] || fail "volume ${name} is '${shape}', want a root-owned 0:0 755"
  docker run -d --name "${name}" --network none --mount "${vol}" "$@" "${TAG}" >/dev/null ||
    fail "cannot start ${name}"
}

# wait_ready waits up to 90 s for container $1 to have logged $2 completed boots
# (the entrypoint's last line); fails with its log tail if it stops first.
wait_ready() {
  local _
  for _ in $(seq 1 90); do
    [ "$(docker logs "$1" 2>&1 | grep -c "${READY}")" -ge "$2" ] && return 0
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ] || break
    sleep 1
  done
  docker logs --tail 20 "$1" >&2
  fail "$1 did not finish boot $2"
}

# server_uids prints "<real> <effective>" uid for each process in container $1
# whose command line starts with "vault server".
server_uids() {
  docker exec "$1" sh -c 'for d in /proc/[0-9]*; do
    case "$(tr "\0" " " <"${d}/cmdline" 2>/dev/null)" in
      "vault server"*) awk "/^Uid:/ { print \$2, \$3 }" "${d}/status" ;;
    esac
  done'
}

# expect_eq fails with label $1 unless $2 (got) equals $3 (want).
expect_eq() {
  [ "$2" = "$3" ] || fail "$1: got '$2', want '$3'"
  ok "$1 = '$3'"
}

# expect_serving asserts container $1 runs one vault server and PID 1 as uid
# pair $2, holds the keys file as 600 vault:vault, and answers unsealed.
expect_serving() {
  expect_eq "$1 vault server uid (real effective)" "$(server_uids "$1")" "$2"
  expect_eq "$1 entrypoint PID 1 uid (real effective)" \
    "$(docker exec "$1" awk '/^Uid:/ { print $2, $3 }' /proc/1/status)" "$2"
  expect_eq "$1 keys file mode owner" "$(docker exec "$1" stat -c '%a %U:%G' "${KEYS}")" "600 vault:vault"
  docker exec -e VAULT_ADDR=http://127.0.0.1:8200 "$1" vault status >/dev/null ||
    fail "$1: vault status is not initialised and unsealed"
  ok "$1 initialised and unsealed"
}

# writable_by_vault prints each of /vault and its config, policy and script dirs
# that the vault uid in container $1 can actually create a file in.
writable_by_vault() {
  docker exec -u vault "$1" sh -c 'for d in /vault /vault/config /vault/policies /vault/scripts; do
    touch "${d}/.m191" 2>/dev/null && printf "%s " "${d}"
  done; true'
}

# leg_off: flag unset is HEAD's behaviour, and proves the uid probe can see root.
leg_off() {
  step "off — VAULT_DROP_PRIVILEGES_ENABLED unset: Vault stays root, image stays HEAD's"
  boot "${P}-off"
  wait_ready "${P}-off" 1
  expect_serving "${P}-off" "0 0"
  expect_eq "${P}-off image ownership of /vault config policies scripts" \
    "$(docker exec "${P}-off" stat -c '%U' /vault /vault/config /vault/policies /vault/scripts | tr '\n' ' ')" \
    "vault vault vault vault "
}

# leg_on: flag on drops every long-lived process to the vault uid, across a restart.
leg_on() {
  local vault_uid
  step "on — VAULT_DROP_PRIVILEGES_ENABLED=1: Vault serves as the vault user"
  boot "${P}-on" -e VAULT_DROP_PRIVILEGES_ENABLED=1
  wait_ready "${P}-on" 1
  vault_uid="$(docker exec "${P}-on" id -u vault)"
  [ -n "${vault_uid}" ] && [ "${vault_uid}" != 0 ] || fail "image has no non-root vault user (got '${vault_uid}')"
  expect_serving "${P}-on" "${vault_uid} ${vault_uid}"
  expect_eq "${P}-on volume owner" "$(docker exec "${P}-on" stat -c '%U' /vault/data)" "vault"
  expect_eq "${P}-on dirs the vault uid can write outside /vault/data" "$(writable_by_vault "${P}-on")" ""
  step "on — restart: unseals from the kept keys file, still as the vault user"
  docker restart "${P}-on" >/dev/null || fail "cannot restart ${P}-on"
  wait_ready "${P}-on" 2
  expect_serving "${P}-on" "${vault_uid} ${vault_uid}"
  expect_eq "${P}-on inits across two boots" "$(docker logs "${P}-on" 2>&1 | grep -c 'initializing Vault')" "1"
  expect_eq "${P}-on unseals across two boots" "$(docker logs "${P}-on" 2>&1 | grep -c 'unsealing Vault')" "2"
}

# leg_neg: flag on with the keys file in a missing dir refuses to start, and says why.
leg_neg() {
  local dir=/vault/data/m191-missing state log _
  step "neg — flag on, VAULT_KEYS_FILE in a missing dir: refuse before init, name the dir"
  boot "${P}-neg" -e VAULT_DROP_PRIVILEGES_ENABLED=1 -e "VAULT_KEYS_FILE=${dir}/.vault-keys.json"
  for _ in $(seq 1 30); do
    state="$(docker inspect -f '{{.State.Running}} {{.State.ExitCode}}' "${P}-neg")"
    [ "${state%% *}" = false ] && break
    sleep 1
  done
  case "${state}" in "false 0" | true*) fail "${P}-neg is '${state}' (running exit), want stopped non-zero" ;; esac
  ok "${P}-neg stopped, exit ${state#false }"
  log="$(docker logs "${P}-neg" 2>&1)"
  grep -qF "directory ${dir} does not exist" <<<"${log}" ||
    fail "${P}-neg log does not name the missing directory ${dir}"
  ok "${P}-neg names the missing directory"
  if grep -q 'initializing Vault' <<<"${log}"; then fail "${P}-neg ran vault operator init"; fi
  ok "${P}-neg never ran vault operator init"
}

step "build ${CTX#"${ROOT}/"}/Dockerfile.fly (entrypoint ${ENTRY#"${ROOT}/"}) as ${TAG}"
build_image
leg_off
leg_on
leg_neg
printf '\033[0;32m[M191] PASS — the flag drops Vault to the vault user; unset keeps HEAD root\033[0m\n'
