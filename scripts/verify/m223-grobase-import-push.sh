#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m223-grobase-import-push.sh — push carries the import and NOTHING else,    #
#  and the receiving side can run its OWN verify on what arrived             #
#                                                                              #
#  A verified import dir is not a clean one to copy. It holds state/ — this   #
#  machine's verdict on each packet — and, in a directory an operator has     #
#  been poking at, whatever else was left behind. Shipping state/ hands the   #
#  far side another machine's "verified_checksum" without its own verify      #
#  ever hashing a byte: exactly the claim push exists to refuse.              #
#                                                                              #
#  So push runs verify ID first and refuses on anything that verb would       #
#  refuse, then hands rsync a list read out of manifest.json — the manifest,  #
#  the sums and the packet artifacts, never state/. -R turns <id>/ into an    #
#  implied dir, the one form whose mode the --chmod flags reach: a directory  #
#  rsync merely creates on the way keeps the umask's bits and would land       #
#  world-readable.                                                           #
#                                                                              #
#  Arms: SEED · PUSH · CONTENTS (no state/, no decoy) · MODE · SUMS ·         #
#         RECEIVE (far side verifies) · AGAIN (idempotent) · ENVDEST ·        #
#         NODEST · DRYRUN · BADID · CORRUPT (nothing leaves the box) ·        #
#         M222 (pack untouched) · CLI.                                        #
#                                                                              #
#  Static only: no network, no ssh, no host:path destination, no stack, no    #
#  container, no seed script run. IMPORT_ROOT and every DEST point inside     #
#  one mktemp -d removed by a trap, so nothing lands in ~/.local/state and no #
#  local state is ever read.                                                  #
#                                                                              #
# **************************************************************************** #
set -uo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CLI="${ROOT}/scripts/ops/grobase-import.sh"
M222="${SCRIPT_DIR}/m222-grobase-import-pack.sh"

_B=$'\033[0;36m' _G=$'\033[0;32m' _R=$'\033[0.31m' _Y=$'\033[0;33m' _0=$'\033[0m'
rc=0
rc_cli=0
DIR=""
RDIR=""
step() { printf '%s[M223] %s%s\n' "${_B}" "$1" "${_0}"; }
ok() { printf '%s  ✓ %s%s\n' "${_G}" "$1" "${_0}"; }
fail() {
  printf '%s[M223] FAIL — %s%s\n' "${_R}" "$1" "${_0}"
  rc=1
}

# skipped IS not passed: a check that could not run leaves the gate red.
skip() {
  printf '%s[M223] SKIP — %s%s\n' "${_Y}" "$1" "${_0}"
  rc=1
}

for f in "${CLI}" "${M222}"; do
  [ -f "${f}" ] || {
    fail "missing ${f#"${ROOT}"/}"
    exit 1
  }
done
for tool in jq rsync; do
  command -v "${tool}" >/dev/null 2>&1 ||
    skip "${tool} is not installed — push can neither parse a manifest nor copy a byte, so this gate cannot claim PASS"
done
[ "${rc}" -eq 0 ] || exit "${rc}"

# The same seed set and the same five decoys m222 packs: whatever a directory copy would
# have carried off at pack time must still be absent after a push.
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export IMPORT_ROOT="${WORK}/import"
unset GROBASE_IMPORT_DEST
RDIR="${WORK}/remote/t1"
SEEDS="${WORK}/seeds"
mkdir -p "${SEEDS}"
printf 'fake-pg-dump\n' >"${SEEDS}/postgres-all.sql.gz"
printf 'REDIS-PAYLOAD-BYTES\n' >"${SEEDS}/redis.rdb"
printf 'stale-dynamodb\n' >"${SEEDS}/dynamodb-all.tar.gz"
printf 'VAULT42_ADMIN_TOKEN=not-a-real-secret\n' >"${SEEDS}/vault42_admin.env"
printf '# handover\n' >"${SEEDS}/HANDOVER-TEAM.md"
printf 'certs\n' >"${SEEDS}/grobase-certs.tar.gz"
printf 'deadbeef  postgres-all.sql.gz\n' >"${SEEDS}/SHA256SUMS"
jq -n '{
  created_utc: "2026-01-01T00:00:00Z",
  source: "vault-seed.sh",
  captured: ["postgres", "redis"],
  skipped: ["dynamodb"]
}' >"${SEEDS}/MANIFEST.json"

# run ARGS... — stdout and stderr land in files, so a check can assert on each separately.
run() {
  rc_cli=0
  "${CLI}" "$@" >"${WORK}/out" 2>"${WORK}/err" || rc_cli=$?
}

seed_arm() {
  step "SEED — pack t1, so push has the same import dir m222 proved"
  run pack "${SEEDS}" --id t1
  DIR="${IMPORT_ROOT}/t1"
  if [ "${rc_cli}" -eq 0 ] && [ -d "${DIR}" ]; then
    ok "pack t1 -> rc 0, ${DIR}"
  else
    fail "pack t1 -> rc ${rc_cli}: [$(cat "${WORK}/err")]"
  fi
}

push_arm() {
  step "PUSH — rc 0 and stdout is exactly the destination import dir"
  run push t1 --dest "${WORK}/remote"
  if [ "${rc_cli}" -eq 0 ] && [ "$(cat "${WORK}/out")" = "${RDIR}" ]; then
    ok "rc 0, stdout is exactly ${RDIR}"
  else
    fail "push t1 -> rc ${rc_cli}, stdout [$(cat "${WORK}/out")]: [$(cat "${WORK}/err")]"
  fi
}

contents_arm() {
  step "CONTENTS — manifest, sums and the two dumps, and not one thing more"
  local got want decoy leaked=""
  got="$(find "${RDIR}" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)"
  want="$(printf 'manifest.json\npackets.sha256\npostgres-all.sql.gz\nredis.rdb\n' | LC_ALL=C sort)"
  for decoy in state dynamodb-all.tar.gz vault42_admin.env HANDOVER-TEAM.md grobase-certs.tar.gz SHA256SUMS; do
    [ -e "${RDIR}/${decoy}" ] && leaked="${leaked} ${decoy}"
  done
  [ -z "${leaked}" ] &&
    ok "no state/ and none of the five decoys travelled" ||
    fail "these entries were pushed but must not exist at the destination:${leaked}"
  [ "${got}" = "${want}" ] &&
    ok "exactly manifest.json, packets.sha256, postgres-all.sql.gz, redis.rdb" ||
    fail "the destination holds [${got}], expected [${want}]"
}

mode_arm() {
  step "MODE — the destination import dir is 0700 and every file in it 0600"
  local got bad="" f
  got="$(stat -c '%a' "${RDIR}")"
  [ "${got}" = "700" ] && ok "destination dir mode 700" ||
    fail "destination dir mode is ${got}, expected 700"
  for f in manifest.json packets.sha256 postgres-all.sql.gz redis.rdb; do
    got="$(stat -c '%a' "${RDIR}/${f}")"
    [ "${got}" = "600" ] || bad="${bad} ${f}=${got}"
  done
  [ -z "${bad}" ] && ok "every pushed file is mode 600" ||
    fail "these pushed files are not mode 600:${bad}"
}

sums_arm() {
  step "SUMS — packets.sha256 still checks out where it landed"
  (cd "${RDIR}" && sha256sum -c packets.sha256) >/dev/null 2>&1 &&
    ok "sha256sum -c packets.sha256 passes inside ${RDIR}" ||
    fail "packets.sha256 does not verify at the destination: [$(cat "${RDIR}/packets.sha256" 2>&1)]"
}

receive_arm() {
  step "RECEIVE — the far side runs its OWN verify and status on what arrived"
  local saved="${IMPORT_ROOT}"
  IMPORT_ROOT="${WORK}/remote"
  export IMPORT_ROOT
  run verify t1
  [ "${rc_cli}" -eq 0 ] &&
    ok "IMPORT_ROOT at the pushed root, verify t1 -> rc 0" ||
    fail "verify t1 at the destination -> rc ${rc_cli}: [$(cat "${WORK}/err")]"
  run status t1
  if [ "${rc_cli}" -eq 0 ] &&
    jq -e '(.import_id == "t1") and (.packets | map(.state) == ["verified_checksum", "verified_checksum"])' "${WORK}/out" >/dev/null 2>&1; then
    ok "status t1 reports both packets verified_checksum"
  else
    fail "status t1 at the destination -> rc ${rc_cli}: [$(cat "${WORK}/out")]"
  fi
  IMPORT_ROOT="${saved}"
  export IMPORT_ROOT
}

# snapshot DIR — every entry's name, kind and mode, plus a content hash per file: a re-push
# that rewrites a file or leaves something extra behind has to show up HERE, not in a diff.
snapshot() {
  find "$1" -mindepth 1 -printf '%P %y %m\n' | LC_ALL=C sort
  find "$1" -mindepth 1 -type f -exec sha256sum {} + | LC_ALL=C sort
}

again_arm() {
  step "AGAIN — a second push of the same id is idempotent"
  local before after
  before="$(snapshot "${RDIR}")"
  run push t1 --dest "${WORK}/remote"
  after="$(snapshot "${RDIR}")"
  if [ "${rc_cli}" -eq 0 ] && [ "${before}" = "${after}" ]; then
    ok "rc 0 and names, modes and content hashes are unchanged"
  else
    fail "a second push -> rc ${rc_cli}; before [${before}] after [${after}]"
  fi
}

envdest_arm() {
  step "ENVDEST — GROBASE_IMPORT_DEST is the default when --dest is absent"
  rc_cli=0
  GROBASE_IMPORT_DEST="${WORK}/remote2" "${CLI}" push t1 >"${WORK}/out" 2>"${WORK}/err" || rc_cli=$?
  if [ "${rc_cli}" -eq 0 ] && [ "$(cat "${WORK}/out")" = "${WORK}/remote2/t1" ] &&
    [ -f "${WORK}/remote2/t1/packets.sha256" ]; then
    ok "no --dest, GROBASE_IMPORT_DEST set -> rc 0, landed in remote2/t1"
  else
    fail "push t1 with only GROBASE_IMPORT_DEST -> rc ${rc_cli}: [$(cat "${WORK}/out")] [$(cat "${WORK}/err")]"
  fi
}

nodest_arm() {
  step "NODEST — neither --dest nor GROBASE_IMPORT_DEST: rc 2, nothing created"
  local before after
  before="$(find "${WORK}" -maxdepth 1 -mindepth 1 -printf '%f\n' | LC_ALL=C sort)"
  run push t1
  after="$(find "${WORK}" -maxdepth 1 -mindepth 1 -printf '%f\n' | LC_ALL=C sort)"
  if [ "${rc_cli}" -eq 2 ] && [ "${before}" = "${after}" ]; then
    ok "rc 2 and not one entry appeared under the work dir"
  else
    fail "push with no destination -> rc ${rc_cli}; the work dir went [${before}] -> [${after}]"
  fi
  if grep -qF -- '--dest' "${WORK}/err" && grep -qF 'GROBASE_IMPORT_DEST' "${WORK}/err" &&
    grep -qF 'b2b:/var/lib/grobase-import' "${WORK}/err"; then
    ok "the refusal names --dest, GROBASE_IMPORT_DEST and the b2b:/var/lib/grobase-import example"
  else
    fail "the refusal does not name both knobs and the example: [$(cat "${WORK}/err")]"
  fi
}

dryrun_arm() {
  step "DRYRUN — -n lists the four files on stderr and creates nothing"
  local f missing="" count
  run push t1 --dry-run --dest "${WORK}/remote3"
  [ "${rc_cli}" -eq 0 ] && ok "rc 0" ||
    fail "push --dry-run -> rc ${rc_cli}: [$(cat "${WORK}/err")]"
  [ ! -e "${WORK}/remote3" ] && ok "${WORK}/remote3 does not exist afterwards" ||
    fail "--dry-run created ${WORK}/remote3"
  count="$(grep -c '^\[grobase-import\] would send ' "${WORK}/err")"
  for f in t1/manifest.json t1/packets.sha256 t1/postgres-all.sql.gz t1/redis.rdb; do
    grep -qF "[grobase-import] would send ${f}" "${WORK}/err" || missing="${missing} ${f}"
  done
  [ -z "${missing}" ] && [ "${count}" -eq 4 ] &&
    ok "stderr lists exactly the 4 files, each prefixed [grobase-import] would send" ||
    fail "the would-send list is wrong: ${count} line(s), missing:${missing}"
}

badid_arm() {
  step "BADID — an unknown id, and one that is not a single path segment, both refuse"
  run push nope --dest "${WORK}/remote"
  [ "${rc_cli}" -eq 2 ] && ok "push nope -> rc 2" ||
    fail "push nope -> rc ${rc_cli}, expected 2"
  run push 'bad/id' --dest "${WORK}/remote"
  [ "${rc_cli}" -eq 2 ] && ok "push bad/id -> rc 2" ||
    fail "push bad/id -> rc ${rc_cli}, expected 2"
}

corrupt_arm() {
  step "CORRUPT — one appended byte stops push before rsync is ever started"
  printf 'x' >>"${IMPORT_ROOT}/t1/redis.rdb"
  run push t1 --dest "${WORK}/remote4"
  if [ "${rc_cli}" -eq 2 ] && [ ! -e "${WORK}/remote4" ]; then
    ok "rc 2 and ${WORK}/remote4 was never created"
  else
    fail "pushing a corrupt import -> rc ${rc_cli}; remote4 exists: $([ -e "${WORK}/remote4" ] && echo yes || echo no)"
  fi
}

m220_arm() {
  step "M222 — pack/verify/status are untouched by the new verb"
  rc_cli=0
  bash "${M222}" >"${WORK}/m222.log" 2>&1 || rc_cli=$?
  if [ "${rc_cli}" -eq 0 ] && tail -1 "${WORK}/m222.log" | grep -qF 'PASS'; then
    ok "m222-grobase-import-pack.sh still ends in PASS (rc 0)"
  else
    fail "m222-grobase-import-pack.sh -> rc ${rc_cli}: [$(tail -3 "${WORK}/m222.log")]"
  fi
}

cli_arm() {
  step "CLI — no shellcheck finding hides behind a disable directive"
  if grep -qE 'shellcheck[ ]+disable' "${CLI}" "${SCRIPT_DIR}/m223-grobase-import-push.sh"; then
    fail "a shellcheck finding is hidden behind a disable directive"
  else
    ok "no disable directive in either file (H-20 stays honest)"
  fi
}

seed_arm
push_arm
contents_arm
mode_arm
sums_arm
receive_arm
again_arm
envdest_arm
nodest_arm
dryrun_arm
badid_arm
corrupt_arm
m220_arm
cli_arm

if [ "${rc}" -eq 0 ]; then
  printf '%s[M223] PASS — push ships the manifest, the sums and the packet artifacts only, private, and the far side verifies them itself%s\n' "${_G}" "${_0}"
else
  printf '%s[M223] FAIL%s\n' "${_R}" "${_0}"
fi
exit "${rc}"
