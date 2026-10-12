#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m228-vault-remote-daemon.sh — vault-seed / vault-restore move minio and     #
#  dynamodb data through the docker API, so they work on a remote daemon       #
#                                                                              #
#  A `-v <path>` names a directory on the DAEMON's host. Under                 #
#  DOCKER_HOST=ssh://b2b (the data center) seed_minio mirrored into a          #
#  directory on the VM and tarred an empty local stage: "minio: SKIPPED        #
#  (archive came back empty (0 entries))", 2026-10-12. restore_minio and       #
#  restore_dynamodb read their stage through the same kind of mount. They now  #
#  go through `docker cp` and stdin.                                           #
#    STATIC    no -v / --volume / --mount in the four functions, and a copy    #
#              of seed_minio with the old bind mount must be caught            #
#    MINIO     the real seed_minio and restore_minio, renamed onto a throwaway #
#              MinIO: objects captured, a failed mirror keeps that archive,    #
#              bucket dropped, restored byte for byte                          #
#    DYNAMODB  the real seed_dynamodb and restore_dynamodb on a throwaway      #
#              dynamodb-local: 30 items (two batches) captured, table dropped, #
#              all 30 back                                                     #
#  Ponytail: the live arms run on whatever daemon DOCKER_HOST names; on a      #
#  local one a bind mount would pass them too. STATIC is what keeps the mount  #
#  out; the live arms prove the docker cp / stdin path moves the data.         #
#  Needs docker, python3 and the four images already present (nothing is      #
#  pulled); otherwise SKIP, exit 77, never 0. Containers, network and temp dir #
#  go in an EXIT trap.                                                         #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SEED="${ROOT}/scripts/ops/vault-seed.sh"
RESTORE="${ROOT}/scripts/ops/vault-restore.sh"
NETSEG="${ROOT}/scripts/lib/lib-netseg.sh"
MC_IMG="${M228_MC_IMAGE:-ghcr.io/univers42/grobase-mc:latest}"
MINIO_IMG="${M228_MINIO_IMAGE:-ghcr.io/univers42/grobase-minio:latest}"
DDB_IMG="${M228_DYNAMODB_IMAGE:-amazon/dynamodb-local:latest}"
AWS_IMG="${M228_AWS_IMAGE:-amazon/aws-cli}"
TAG="m228gate$$"
NET="${TAG}-net"
MINIO_PW="m228-$$-$(date +%s)"
WORK="$(mktemp -d)"
FAILED=0

ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
bad() {
  printf '\033[0;31m  ✗ %s\033[0m\n' "$*"
  FAILED=1
}
step() { printf '\033[0;36m[M228] %s\033[0m\n' "$*"; }

# skip REASON: print why nothing was proven and exit 77 (a gate that did not look has not passed).
skip() {
  printf '\033[0;33m[M228] SKIP — %s; nothing proven\033[0m\n' "$*"
  exit 77
}

# cleanup: remove every container, the network and the temp dir this run made.
cleanup() {
  docker rm -f "${TAG}-minio" "${TAG}-ddb" "${TAG}-seed-mc" "${TAG}-restore-mc" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

# fn FILE NAME...: print the named top-level functions of FILE, renamed onto this run's
# containers so a live stack's mini-baas-minio / mini-baas-dynamodb-local, and a live seed's
# or restore's fixed-name mc container, are never touched.
fn() {
  local file="$1" name
  shift
  for name in "$@"; do
    awk -v n="${name}" '
      $0 ~ "^" n "\\(\\) \\{" { on = 1; print; if ($0 ~ /\}[ \t]*$/) exit; next }
      on { print }
      on && /^}/ { exit }' "${file}"
  done | sed -e "s/mini-baas-minio/${TAG}-minio/g" -e "s/mini-baas-dynamodb-local/${TAG}-ddb/g" \
    -e "s/vault-seed-mc/${TAG}-seed-mc/g" -e "s/vault-restore-mc/${TAG}-restore-mc/g"
}

# mounts: the -v / --volume / --volumes-from / --mount flags in the function text on stdin,
# comments aside, spaced or glued to their value (-v"$stage":/out).
# Ponytail: a text match — a mount passed through a variable ($opts, "$@") is not seen, and
# a `grep -v` in these functions would read as a mount (noisy, never silent).
mounts() {
  grep -v '^[[:space:]]*#' |
    grep -nE -- '(^|[[:space:]])(-v|--volume|--volumes-from|--mount)([^[:alpha:]-]|$)'
}

# harness NAME FILE FUNCS... -- CALLS...: a POSIX sh script running the real functions.
harness() {
  local out="${WORK}/$1.sh" file="$2" funcs=()
  shift 2
  while [ "$1" != -- ]; do funcs+=("$1") && shift; done
  shift
  {
    printf 'set -eu\nSEED_DIR=%s NET=%s MC_IMAGE=%s AWS_IMAGE=%s CAPTURED= SKIPPED=\n' \
      "${WORK}/seed" "${NET}" "${MC_IMG}" "${AWS_IMG}"
    printf '. %s\n' "${NETSEG}"
    fn "${file}" "${funcs[@]}"
    printf '%s\n' "$@"
  } >"${out}"
  printf '%s' "${out}"
}

mc() {
  docker run --rm -i --network "${NET}" -e MC_HOST_g="http://m228admin:${MINIO_PW}@${TAG}-minio:9000" \
    -e HOME=/tmp --tmpfs /tmp:rw,size=16m "${MC_IMG}" "$@"
}
aws() {
  docker run --rm -i --network "${NET}" -e AWS_ACCESS_KEY_ID=local -e AWS_SECRET_ACCESS_KEY=local \
    -e AWS_DEFAULT_REGION=us-east-1 "${AWS_IMG}" --endpoint-url "http://${TAG}-ddb:8000" dynamodb "$@"
}

# wait_for CMD...: retry CMD for up to 60 s.
wait_for() {
  local i
  for i in $(seq 1 60); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# items N0 N: a batch-write-item request putting items N0 … N0+N-1 into m228_t.
items() {
  python3 -c 'import json,sys
a,n=int(sys.argv[1]),int(sys.argv[2])
print(json.dumps({"m228_t":[{"PutRequest":{"Item":{"id":{"S":"k%03d"%i},"v":{"N":str(i)}}}} for i in range(a,a+n)]}))' "$1" "$2"
}

step "1/3 STATIC — no bind mount in the four functions"
for pair in "${SEED}:seed_minio" "${SEED}:seed_dynamodb" "${RESTORE}:restore_minio" "${RESTORE}:restore_dynamodb"; do
  body="$(fn "${pair%%:*}" "${pair##*:}")"
  if [ -z "${body}" ]; then
    bad "${pair##*:} not found in ${pair%%:*}"
  elif hits="$(mounts <<<"${body}")"; then
    bad "${pair##*:} mounts a host path: ${hits}"
  else
    ok "${pair##*:}: no -v / --volume / --mount"
  fi
done
for mount in '-v "$stage":/out' '-v"$stage":/out' '--mount type=bind,src="$stage",dst=/out'; do
  if fn "${SEED}" seed_minio | sed "s#\"\\\$MC_IMAGE\" mirror#${mount} \"\$MC_IMAGE\" mirror#" | mounts >/dev/null; then
    ok "refused: seed_minio with ${mount}"
  else
    bad "mutant survived: seed_minio with ${mount} is not caught — this arm is blind"
  fi
done

command -v docker >/dev/null 2>&1 || skip "docker is not available"
command -v python3 >/dev/null 2>&1 || skip "python3 is not available (restore_dynamodb needs it)"
for img in "${MC_IMG}" "${MINIO_IMG}" "${DDB_IMG}" "${AWS_IMG}"; do
  docker image inspect "${img}" >/dev/null 2>&1 || skip "${img} is not present"
done
mkdir -p "${WORK}/seed"
docker network create "${NET}" >/dev/null || skip "could not create a docker network"
docker run -d --name "${TAG}-minio" --network "${NET}" -e MINIO_ROOT_USER=m228admin -e MINIO_ROOT_PASSWORD="${MINIO_PW}" \
  "${MINIO_IMG}" server /data >/dev/null || skip "could not start MinIO"
docker run -d --name "${TAG}-ddb" --network "${NET}" "${DDB_IMG}" >/dev/null || skip "could not start dynamodb-local"

step "2/3 MINIO — captured, dropped, restored"
wait_for mc ls g || skip "MinIO did not answer"
payload="m228 payload $$"
mc mb g/m228-bucket >/dev/null && printf '%s\n' "${payload}" | mc pipe g/m228-bucket/nested/obj.txt >/dev/null &&
  printf 'top\n' | mc pipe g/m228-bucket/top.txt >/dev/null || skip "could not write the test objects"
out="$(sh "$(harness seed-minio "${SEED}" note have_container took missed commit_archive seed_minio -- seed_minio)" 2>&1)"
listing="$(tar -tzf "${WORK}/seed/minio.tar.gz" 2>/dev/null)"
if grep -q 'minio: captured' <<<"${out}" && grep -qx './m228-bucket/nested/obj.txt' <<<"${listing}" &&
  grep -qx './m228-bucket/top.txt' <<<"${listing}"; then
  ok "seed_minio captured both objects"
else
  bad "seed_minio did not capture the objects: $(tail -1 <<<"${out}")"
fi
# A mirror that fails must leave the last good archive alone, not commit a partial one.
good="$(sha256sum <"${WORK}/seed/minio.tar.gz" 2>/dev/null)"
h="$(harness seed-minio-fail "${SEED}" note have_container took missed commit_archive seed_minio -- seed_minio)"
sed -i 's#mirror --quiet seed /home/mc/out#mirror --quiet seed/m228-absent /home/mc/out#' "${h}"
out="$(sh "${h}" 2>&1)"
if grep -q 'minio: SKIPPED (mirror or copy-out failed)' <<<"${out}" &&
  [ "$(sha256sum <"${WORK}/seed/minio.tar.gz")" = "${good}" ]; then
  ok "a failed mirror kept the previous minio.tar.gz"
else
  bad "a failed mirror was not reported, or replaced minio.tar.gz: $(tail -1 <<<"${out}")"
fi
mc rb --force g/m228-bucket >/dev/null 2>&1 || bad "could not drop the test bucket"
out="$(sh "$(harness restore-minio "${RESTORE}" die note have restore_minio -- restore_minio)" 2>&1)" ||
  bad "restore_minio failed: $(tail -1 <<<"${out}")"
if [ "$(mc cat g/m228-bucket/nested/obj.txt 2>/dev/null)" = "${payload}" ]; then
  ok "restore_minio put the dropped bucket back, same bytes"
else
  bad "restore_minio did not bring m228-bucket/nested/obj.txt back"
fi

step "3/3 DYNAMODB — captured, dropped, restored"
wait_for aws list-tables || skip "dynamodb-local did not answer"
aws create-table --table-name m228_t --attribute-definitions AttributeName=id,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH --billing-mode PAY_PER_REQUEST >/dev/null &&
  items 0 15 | aws batch-write-item --request-items file:///dev/stdin >/dev/null &&
  items 15 15 | aws batch-write-item --request-items file:///dev/stdin >/dev/null || skip "could not seed the test table"
out="$(sh "$(harness seed-ddb "${SEED}" note took missed have_container commit_archive seed_dynamodb -- seed_dynamodb)" 2>&1)"
if grep -q 'dynamodb: captured' <<<"${out}"; then ok "seed_dynamodb captured m228_t"; else bad "seed_dynamodb: $(tail -1 <<<"${out}")"; fi
aws delete-table --table-name m228_t >/dev/null || bad "could not drop the test table"
out="$(sh "$(harness restore-ddb "${RESTORE}" die note have is_running restore_dynamodb -- restore_dynamodb)" 2>&1)" ||
  bad "restore_dynamodb failed: $(tail -1 <<<"${out}")"
count="$(aws scan --table-name m228_t --select COUNT --output text --query Count 2>/dev/null)"
if [ "${count}" = 30 ]; then ok "restore_dynamodb re-created m228_t with all 30 items"; else bad "m228_t holds ${count:-no} items after the restore, want 30"; fi

[ "${FAILED}" -eq 0 ] && step "PASS" || step "FAIL"
exit "${FAILED}"
