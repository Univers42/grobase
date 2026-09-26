#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m209-backup-encryption.sh — with BACKUP_AGE_RECIPIENTS set, pg-backup never  #
#  writes a plaintext artifact, and restoring one needs the age identity       #
#                                                                              #
#  Hermetic: a scratch network, postgres, MinIO and a pg-backup image built    #
#  from the CURRENT source (no running stack needed; all removed on exit).     #
#    PARITY    recipients unset: logical/<stamp>.dump is a plain pg_dump       #
#              archive (starts PGDMP), as before this change                   #
#    SEALED    recipients set: logical/<stamp>.dump.age starts with the age    #
#              header, holds no PGDMP, and no plaintext .dump was added        #
#    FAIL-SHUT a recipient age refuses: the run fails, nothing is uploaded     #
#    RESTORE   no identity, the wrong identity: refused, target stays empty;   #
#              the right identity: the marker row is back                      #
#    REFUSE    an artifact of unknown type is refused, never reported done     #
#    MUTANT    restore.sh without its .age branch and with refusal turned into #
#              exit 0 restores nothing and exits 0: the row check catches it   #
#    SERVICE   loop, once and archive-wal refuse to start holding an identity  #
#    PHYSICAL  PG_BACKUP_PHYSICAL=1: every physical/base-<stamp>/ member is    #
#              .age and decrypts to the base (base.tar.gz lists PG_VERSION)    #
#    WAL       archive-wal stores wal/<seg>.age, never wal/<seg>, byte-exact   #
#              after decrypting, and a retry is "already stored"               #
#    PITR      pitr-restore decrypts the base into PGDATA and the WAL into its #
#              stage under bare names; without the identity it refuses         #
#                                                                              #
#  Not proven here: a WAL replay of encrypted segments (m99 replays plaintext  #
#  ones; the decryption this gate proves happens before restore_command).      #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PGB="${ROOT}/infra/docker/services/pg-backup"
IMG="${M209_IMAGE:-grobase-pg-backup:m209}"
PG_IMAGE="${M209_PG_IMAGE:-mirror.gcr.io/library/postgres:16-alpine}"
MINIO_IMAGE="${M209_MINIO_IMAGE:-ghcr.io/univers42/grobase-minio:latest}"
N="m209-$$"
PW="m209-scratch-pw"
SEG="000000010000000000000099"
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M209] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M209] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

WORK="$(mktemp -d)"
cleanup() {
  docker rm -f "${N}-pg" "${N}-minio" >/dev/null 2>&1
  docker network rm "${N}" >/dev/null 2>&1
  rm -rf "${WORK}"
}
trap cleanup EXIT

# pgb runs the pg-backup image on the scratch network with the store settings;
# extra docker-run options come first, then `--`, then the entrypoint mode/args.
pgb() {
  local opts=()
  while [ "$1" != -- ]; do opts+=("$1") && shift; done
  shift
  docker run --rm --network "${N}" -v "${WORK}/keys:/keys:ro" \
    -e DATABASE_URL="postgres://postgres:${PW}@${N}-pg:5432/postgres" \
    -e RESTORE_DATABASE_URL="postgres://postgres:${PW}@${N}-pg:5432/m209_target" \
    -e MINIO_ENDPOINT="http://${N}-minio:9000" -e MINIO_ROOT_USER=m209 -e MINIO_ROOT_PASSWORD="${PW}" \
    -e PG_BACKUP_BUCKET=backups -e PG_BACKUP_PREFIX=m209 "${opts[@]}" "${IMG}" "$@"
}
# sh_in runs bash script $1 in the image with the mc alias set; extra docker-run
# options follow.
sh_in() {
  local script="$1"
  shift
  pgb --entrypoint bash "$@" -- -c "mc alias set baas http://${N}-minio:9000 m209 ${PW} >/dev/null && ${script}"
}
objects() { sh_in 'mc ls -r baas/backups/m209/ | awk "{print \$NF}"' 2>/dev/null | sort; }
psql_pg() { docker exec "${N}-pg" psql -U postgres -tAc "$1" "${2:-postgres}"; }
marker() { psql_pg 'SELECT v FROM m209_marker' m209_target 2>/dev/null; }
reset_target() { psql_pg 'DROP DATABASE IF EXISTS m209_target' >/dev/null 2>&1 && psql_pg 'CREATE DATABASE m209_target' >/dev/null; }

# boot builds the image and starts postgres (replication allowed, a marker row)
# and MinIO, and makes the age identities.
boot() {
  step "0 ${IMG} (built from current source unless M209_IMAGE names one); scratch postgres + MinIO"
  [ -n "${M209_IMAGE:-}" ] || docker build -q -t "${IMG}" "${PGB}" >/dev/null || fail "pg-backup image build failed"
  docker run --rm --entrypoint age "${IMG}" --version >/dev/null || fail "${IMG} has no age"
  docker network create "${N}" >/dev/null || fail "network ${N}"
  docker run -d --name "${N}-pg" --network "${N}" -e POSTGRES_PASSWORD="${PW}" "${PG_IMAGE}" \
    -c wal_level=replica >/dev/null || fail "postgres did not start"
  docker run -d --name "${N}-minio" --network "${N}" -e MINIO_ROOT_USER=m209 -e MINIO_ROOT_PASSWORD="${PW}" \
    "${MINIO_IMAGE}" server /tmp/m209 >/dev/null || fail "minio did not start"
  for _ in $(seq 60); do psql_pg 'SELECT 1' >/dev/null 2>&1 && break || sleep 1; done
  psql_pg "CREATE TABLE m209_marker (v text); INSERT INTO m209_marker VALUES ('m209-$$')" >/dev/null || fail "seed failed"
  docker exec "${N}-pg" sh -c 'echo "host replication all all scram-sha-256" >>"$PGDATA/pg_hba.conf"' &&
    psql_pg 'SELECT pg_reload_conf()' >/dev/null || fail "pg_hba replication line"
  mkdir -p "${WORK}/keys" && chmod 755 "${WORK}/keys"
  for k in id wrong; do docker run --rm --entrypoint age-keygen "${IMG}" 2>/dev/null >"${WORK}/keys/${k}.txt"; done
  chmod 644 "${WORK}/keys/"*.txt
  RCPT="$(grep -o 'age1[0-9a-z]*' "${WORK}/keys/id.txt" | head -n1)"
  [ -n "${RCPT}" ] || fail "age-keygen made no recipient"
  for _ in $(seq 30); do sh_in 'mc mb -p baas/backups' >/dev/null 2>&1 && break || sleep 1; done
  ok "postgres, MinIO, image with $(docker run --rm --entrypoint age "${IMG}" --version); recipient ${RCPT:0:12}…"
}

# logical proves PARITY, SEALED and FAIL-SHUT.
logical() {
  local head before
  step "1 logical backup: parity, sealed, fail-shut"
  pgb -- once >"${WORK}/once.log" 2>&1 || fail "plaintext once failed: $(tail -n1 "${WORK}/once.log")"
  PLAIN="$(objects | grep '\.dump$' | head -n1)"
  head="$(sh_in "mc cat baas/backups/m209/${PLAIN} | head -c 5")"
  [ "${head}" = PGDMP ] || fail "parity: ${PLAIN:-no .dump} does not start PGDMP"
  ok "recipients unset: ${PLAIN} is a plain pg_dump archive"
  sleep 1
  pgb -e BACKUP_AGE_RECIPIENTS="${RCPT}" -- once >"${WORK}/once.log" 2>&1 || fail "sealed once failed: $(tail -n1 "${WORK}/once.log")"
  SEALED="$(objects | grep '\.dump\.age$' | head -n1)"
  [ -n "${SEALED}" ] || fail "no .dump.age uploaded"
  [ "$(objects | grep -c '\.dump$')" = 1 ] || fail "a plaintext .dump was uploaded next to the .age"
  head="$(sh_in "mc cat baas/backups/m209/${SEALED} | head -n1")"
  [ "${head}" = age-encryption.org/v1 ] || fail "${SEALED} has no age header"
  sh_in "mc cat baas/backups/m209/${SEALED} | grep -qa PGDMP" && fail "${SEALED} holds a pg_dump header in clear"
  ok "recipients set: ${SEALED} starts with the age header, no PGDMP inside, no plaintext copy"
  before="$(objects | wc -l)"
  pgb -e BACKUP_AGE_RECIPIENTS="age1notakey" -- once >"${WORK}/bad.log" 2>&1 && fail "a bad recipient still backed up"
  grep -q 'refuses a recipient' "${WORK}/bad.log" || fail "bad recipient not named: $(tail -n1 "${WORK}/bad.log")"
  [ "$(objects | wc -l)" = "${before}" ] || fail "a bad recipient uploaded something"
  ok "a recipient age refuses: the run fails and nothing is uploaded"
}

# restored KEY [OPTS...] resets the target, restores KEY, and succeeds only when
# the command exited 0 AND the marker row is back.
restored() {
  local key="$1"
  shift
  reset_target || fail "target reset"
  pgb "$@" -- restore "${key}" >"${WORK}/restore.log" 2>&1 || return 1
  [ "$(marker)" = "m209-$$" ]
}

# restores proves RESTORE, REFUSE and MUTANT.
restores() {
  local id=(-e BACKUP_AGE_IDENTITY_FILE=/keys/id.txt) wrong=(-e BACKUP_AGE_IDENTITY_FILE=/keys/wrong.txt)
  step "2 restore: identity required, unknown artifacts refused, mutant caught"
  restored "${SEALED}" && fail "restored ${SEALED} without an identity"
  grep -q BACKUP_AGE_IDENTITY_FILE "${WORK}/restore.log" || fail "no identity: not refused by name: $(tail -n1 "${WORK}/restore.log")"
  [ -z "$(marker)" ] || fail "no identity: rows landed anyway"
  restored "${SEALED}" "${wrong[@]}" && fail "restored ${SEALED} with the wrong identity"
  [ -z "$(marker)" ] || fail "wrong identity: rows landed anyway"
  restored "${SEALED}" "${id[@]}" || fail "the right identity did not restore: $(tail -n2 "${WORK}/restore.log" | paste -sd' ')"
  restored "${PLAIN}" || fail "a plaintext .dump no longer restores (changeover)"
  ok "${SEALED}: refused without / with the wrong identity; the right one and the old plaintext .dump both restore"
  sh_in 'echo junk | mc pipe baas/backups/m209/logical/junk.bin' >/dev/null || fail "junk upload"
  pgb -- restore logical/junk.bin >"${WORK}/junk.log" 2>&1 && fail "restore of junk.bin exited 0"
  grep -q refusing "${WORK}/junk.log" || fail "junk.bin not refused by name"
  ok "an artifact of unknown type is refused"
  sed -e '/^if \[\[ "\$LOCAL" == \*\.age \]\]; then$/,/^fi$/d' -e 's/^  exit 1$/  exit 0/' \
    "${PGB}/scripts/restore.sh" >"${WORK}/mutant.sh"
  grep -q '\*\.age' "${WORK}/mutant.sh" && fail "mutant: the .age branch is not where this gate expects it"
  grep -qx '  exit 0' "${WORK}/mutant.sh" || fail "mutant: the refusal is not where this gate expects it"
  restored "${SEALED}" "${id[@]}" -v "${WORK}/mutant.sh:/opt/pg-backup/restore.sh:ro" && fail "mutant survived"
  ok "mutant restore.sh (no .age branch, refusal exits 0) restores nothing and is caught"
}

# service proves loop, once and archive-wal refuse an identity.
service() {
  local mode
  step "3 the backup service never holds the identity"
  for mode in loop once archive-wal; do
    timeout 60 docker run --rm -e BACKUP_AGE_IDENTITY_FILE=/keys/id.txt -e PG_BACKUP_PITR=1 "${IMG}" "${mode}" x x \
      >"${WORK}/svc.log" 2>&1 && fail "${mode} started with an identity"
    grep -q 'belongs to a one-off restore run' "${WORK}/svc.log" || fail "${mode}: $(tail -n1 "${WORK}/svc.log")"
  done
  ok "loop, once and archive-wal refuse BACKUP_AGE_IDENTITY_FILE"
}

# physical proves every physical member is sealed and decrypts to the base.
physical() {
  local members base
  step "4 physical base backup is sealed"
  pgb -e BACKUP_AGE_RECIPIENTS="${RCPT}" -e PG_BACKUP_PHYSICAL=1 -- once >"${WORK}/phys.log" 2>&1 ||
    fail "physical once failed: $(tail -n1 "${WORK}/phys.log")"
  members="$(objects | grep '^physical/')"
  [ -n "${members}" ] || fail "no physical member uploaded"
  grep -qv '\.age$' <<<"${members}" && fail "plaintext physical member(s): $(grep -v '\.age$' <<<"${members}" | paste -sd' ')"
  base="$(grep '/base\.tar\.gz\.age$' <<<"${members}")"
  sh_in "mc cat baas/backups/m209/${base} | age -d -i /keys/id.txt | tar -tz | grep -Eqx '(\./)?PG_VERSION'" ||
    fail "${base} does not decrypt to a base holding PG_VERSION"
  ok "$(wc -l <<<"${members}") physical member(s), all .age; base.tar.gz decrypts to a base (PG_VERSION)"
}

# wal proves archive-wal seals, is idempotent, fails shut, and PITR decrypts.
wal() {
  local sums pitr
  step "5 WAL archive and PITR staging"
  sums="$(sh_in "head -c 65536 /dev/urandom >/tmp/s && sha256sum </tmp/s && /opt/pg-backup/wal-archive.sh /tmp/s ${SEG} && /opt/pg-backup/wal-archive.sh /tmp/s ${SEG} && BACKUP_AGE_RECIPIENTS= /opt/pg-backup/wal-archive.sh /etc/hostname ${SEG%9}8" \
    -e BACKUP_AGE_RECIPIENTS="${RCPT}")" || fail "archive-wal failed: ${sums}"
  grep -q 'already stored' <<<"${sums}" || fail "a retried segment was not 'already stored'"
  objects | grep -qx "wal/${SEG}.age" || fail "wal/${SEG}.age not stored"
  objects | grep -qx "wal/${SEG}" && fail "wal/${SEG} stored in clear"
  [ "$(sh_in "mc cat baas/backups/m209/wal/${SEG}.age | age -d -i /keys/id.txt | sha256sum")" = "$(head -n1 <<<"${sums}")" ] ||
    fail "wal/${SEG}.age does not decrypt to the segment"
  sh_in "/opt/pg-backup/wal-archive.sh /etc/hostname ${SEG%9}7" -e BACKUP_AGE_RECIPIENTS=age1notakey >/dev/null 2>&1 &&
    fail "archive-wal stored a segment it could not encrypt"
  objects | grep -q "wal/${SEG%9}7" && fail "a segment that failed to encrypt was stored"
  ok "wal/${SEG}.age byte-exact after decrypting, a retry is 'already stored', a bad recipient stores nothing"
  pitr="PG_BACKUP_PITR=1 /opt/pg-backup/pitr-restore.sh latest '2099-01-01 00:00:00+00' >/dev/null"
  sh_in "${pitr}" >"${WORK}/pitr.log" 2>&1 && fail "pitr-restore ran without the identity"
  grep -q BACKUP_AGE_IDENTITY_FILE "${WORK}/pitr.log" || fail "pitr without identity: $(tail -n1 "${WORK}/pitr.log")"
  sh_in "${pitr} && test -f /pitr/pgdata/PG_VERSION && test -f /pitr/wal/${SEG%9}8 && ! ls /pitr/wal/*.age 2>/dev/null && sha256sum </pitr/wal/${SEG}" \
    -e BACKUP_AGE_IDENTITY_FILE=/keys/id.txt >"${WORK}/pitr.log" 2>&1 || fail "pitr-restore: $(tail -n2 "${WORK}/pitr.log" | paste -sd' ')"
  [ "$(tail -n1 "${WORK}/pitr.log")" = "$(head -n1 <<<"${sums}")" ] || fail "the staged segment differs from the archived one"
  ok "pitr-restore: base decrypted into PGDATA, .age and plaintext segments staged under bare names; refused without identity"
}

command -v docker >/dev/null || fail "docker is required"
boot
logical
restores
service
physical
wal
cyan "[M209] PASS — backups are age-encrypted when BACKUP_AGE_RECIPIENTS is set; restores need the identity"
