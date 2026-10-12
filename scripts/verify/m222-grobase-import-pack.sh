#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m222-grobase-import-pack.sh — pack carries the DUMPS and nothing else,    #
#  and verify/status report a packet's state without touching a database      #
#                                                                              #
#  A seed set is not an import dir. scripts/ops/vault-seed.sh leaves behind    #
#  more than data: SHA256SUMS, HANDOVER-TEAM.md, a vault42_admin.env, and    #
#  the tarball of an engine it SKIPPED but whose old file never went away.    #
#  Copying the directory would ship a credential and a stale dynamodb dump   #
#  into a data center, under a manifest that calls the whole thing captured.  #
#                                                                              #
#  So pack is driven by the manifest's `captured` array and by the packets    #
#  lib-packets.sh builds from it — nothing else is ever created — and the     #
#  directory is staged as a temp sibling and moved into place, so an          #
#  interrupted pack cannot leave half an import dir under the real name.      #
#                                                                              #
#  Arms: PACK · TAMPER · CONTENTS (decoys must not leak) · MANIFEST · SUMS ·  #
#         MODE · COLLIDE · BADID · NOPACK · VERIFY · CORRUPT · MISSING ·      #
#         STATUS · CLI.                                                      #
#                                                                              #
#  Static only: no network, no stack, no container, no seed script run, and   #
#  IMPORT_ROOT redirected into a temp dir so nothing lands in ~/.local/state.  #
#                                                                              #
# **************************************************************************** #
set -uo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CLI="${ROOT}/scripts/ops/grobase-import.sh"

_B=$'\033[0;36m' _G=$'\033[0;32m' _R=$'\033[0;31m' _Y=$'\033[0;33m' _0=$'\033[0m'
rc=0
rc_cli=0
step() { printf '%s[M222] %s%s\n' "${_B}" "$1" "${_0}"; }
ok() { printf '%s  ✓ %s%s\n' "${_G}" "$1" "${_0}"; }
fail() {
  printf '%s[M222] FAIL — %s%s\n' "${_R}" "$1" "${_0}"
  rc=1
}

# skipped IS not passed: a check that could not run leaves the gate red.
skip() {
  printf '%s[M222] SKIP — %s%s\n' "${_Y}" "$1" "${_0}"
  rc=1
}

[ -f "${CLI}" ] || {
  fail "missing scripts/ops/grobase-import.sh"
  exit 1
}
if ! command -v jq >/dev/null 2>&1; then
  skip "jq is not installed — no manifest is ever parsed, so this gate cannot claim PASS"
  exit "${rc}"
fi

# The seed dir: its two captured dumps, and five decoys a directory copy would carry off.
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export IMPORT_ROOT="${WORK}/import"
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

pack_arm() {
  step "PACK — exits 0 and prints the import dir path on stdout"
  run pack "${SEEDS}" --id t1
  DIR="${IMPORT_ROOT}/t1"
  if [ "${rc_cli}" -eq 0 ] && [ "$(cat "${WORK}/out")" = "${DIR}" ]; then
    ok "rc 0, stdout is exactly ${DIR}"
  else
    fail "pack t1 gave rc ${rc_cli} and stdout [$(cat "${WORK}/out")]"
  fi
  grep -q '^\[grobase-import\] ' "${WORK}/err" &&
    ok "progress notes go to stderr, prefixed [grobase-import]" ||
    fail "no [grobase-import] progress line on stderr: [$(cat "${WORK}/err")]"
}

contents_arm() {
  step "CONTENTS — exactly the manifest, the sums, the two dumps and state/"
  local got want decoy leaked=""
  got="$(find "${DIR}" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)"
  want="$(printf 'manifest.json\npackets.sha256\npostgres-all.sql.gz\nredis.rdb\nstate\n' | LC_ALL=C sort)"
  for decoy in dynamodb-all.tar.gz vault42_admin.env HANDOVER-TEAM.md grobase-certs.tar.gz SHA256SUMS; do
    [ -e "${DIR}/${decoy}" ] && leaked="${leaked} ${decoy}"
  done
  [ -z "${leaked}" ] &&
    ok "no decoy travelled: dynamodb tarball, env file, HANDOVER, certs and SHA256SUMS stayed" ||
    fail "these non-captured files were packed:${leaked}"
  [ "${got}" = "${want}" ] &&
    ok "manifest.json, packets.sha256, postgres-all.sql.gz, redis.rdb, state" ||
    fail "import dir entries are [${got}], expected [${want}]"
  [ "$(cat "${DIR}/state/postgres")" = "staged" ] &&
    [ "$(cat "${DIR}/state/redis")" = "staged" ] &&
    ok "one state file per packet id, each holding staged" ||
    fail "state/ does not hold one staged file per packet id"
}

manifest_arm() {
  step "MANIFEST — v1 keys unchanged, plus manifest_version, import_id and the packets"
  jq -e '(.captured == ["postgres", "redis"]) and (.skipped == ["dynamodb"])
    and (.created_utc == "2026-01-01T00:00:00Z") and (.source == "vault-seed.sh")
    and (.manifest_version == 2) and (.import_id == "t1")
    and ((.packets | length) == (.captured | length))
    and (.packets | map(.artifact) == ["postgres-all.sql.gz", "redis.rdb"])
    and (.packets[0].sha256 | test("^[0-9a-f]{64}$"))' "${DIR}/manifest.json" >/dev/null 2>&1 &&
    ok "v1 keys as in the seed, v2, import_id t1, one packet per captured engine" ||
    fail "manifest.json does not carry the seed's v1 keys unchanged: [$(cat "${DIR}/manifest.json")]"
}

sums_arm() {
  step "SUMS — packets.sha256 is sha256sum -c format over the packed artifacts"
  (cd "${DIR}" && sha256sum -c packets.sha256) >/dev/null 2>&1 &&
    ok "sha256sum -c packets.sha256 passes inside the import dir" ||
    fail "packets.sha256 does not verify: [$(cat "${DIR}/packets.sha256")]"
  [ "$(wc -l <"${DIR}/packets.sha256")" -eq 2 ] &&
    ok "one line per packet, nothing hashed that was not packed" ||
    fail "packets.sha256 has $(wc -l <"${DIR}/packets.sha256") lines, expected 2"
}

mode_arm() {
  step "MODE — the import dir is 0700: engine dumps, not a world-readable directory"
  local got
  got="$(stat -c '%a' "${DIR}")"
  [ "${got}" = "700" ] && ok "mode 700" ||
    fail "import dir mode is ${got}, expected 700"
}

collide_arm() {
  step "COLLIDE — a second pack of the same id refuses; --force replaces it"
  run pack "${SEEDS}" --id t1
  [ "${rc_cli}" -eq 2 ] && ok "pack --id t1 again -> rc 2" ||
    fail "pack --id t1 again -> rc ${rc_cli}, expected 2"
  run pack "${SEEDS}" --id t1 --force
  [ "${rc_cli}" -eq 0 ] && ok "with --force -> rc 0" ||
    fail "pack --id t1 --force -> rc ${rc_cli}, expected 0"
}

badid_arm() {
  step "BADID — an id that is not one path segment is refused"
  run pack "${SEEDS}" --id 'bad/id'
  [ "${rc_cli}" -eq 2 ] && ok "pack --id bad/id -> rc 2" ||
    fail "pack --id bad/id -> rc ${rc_cli}, expected 2"
}

# NOPACK — a seed whose captured list names a dump that is not on disk must create NOTHING:
# not the import dir, not the staging sibling a half pack would leave behind.
nopack_arm() {
  step "NOPACK — captured mysql without mysql-all.sql.gz: rc 2, nothing created"
  local hole="${WORK}/hole"
  mkdir -p "${hole}"
  jq -n '{created_utc: "2026-01-01T00:00:00Z", source: "vault-seed.sh",
    captured: ["mysql"], skipped: ["postgres"]}' >"${hole}/MANIFEST.json"
  run pack "${hole}" --id t2
  if [ "${rc_cli}" -eq 2 ] && [ ! -e "${IMPORT_ROOT}/t2" ] && [ ! -e "${IMPORT_ROOT}/.t2.tmp" ]; then
    ok "rc 2, and neither t2 nor .t2.tmp exists under IMPORT_ROOT"
  else
    fail "rc ${rc_cli}; t2 exists: $([ -e "${IMPORT_ROOT}/t2" ] && echo yes || echo no), .t2.tmp exists: $([ -e "${IMPORT_ROOT}/.t2.tmp" ] && echo yes || echo no)"
  fi
}

verify_arm() {
  step "VERIFY — every packet re-checksums and reads verified_checksum"
  run verify t1
  if [ "${rc_cli}" -eq 0 ] &&
    [ "$(cat "${DIR}/state/postgres")" = "verified_checksum" ] &&
    [ "$(cat "${DIR}/state/redis")" = "verified_checksum" ]; then
    ok "rc 0, both state files read verified_checksum"
  else
    fail "verify t1 -> rc ${rc_cli}; states postgres=$(cat "${DIR}/state/postgres" 2>/dev/null) redis=$(cat "${DIR}/state/redis" 2>/dev/null)"
  fi
}

corrupt_arm() {
  step "CORRUPT — one appended byte fails that packet and only that packet"
  printf 'x' >>"${DIR}/redis.rdb"
  run verify t1
  if [ "${rc_cli}" -eq 2 ] && grep -q 'redis' "${WORK}/err" &&
    grep -qF 'sha256 mismatch' "${WORK}/err"; then
    ok "rc 2, stderr names redis and sha256 mismatch"
  else
    fail "verify after corruption -> rc ${rc_cli}: [$(cat "${WORK}/err")]"
  fi
  [ "$(cat "${DIR}/state/redis")" = "failed" ] &&
    [ "$(cat "${DIR}/state/postgres")" = "verified_checksum" ] &&
    ok "state/redis failed, state/postgres still verified_checksum" ||
    fail "a corrupt dump did not flip only its own state file"
}

missing_arm() {
  step "MISSING — a deleted artifact is reported as missing, not as a mismatch"
  rm -f "${DIR}/postgres-all.sql.gz"
  run verify t1
  if [ "${rc_cli}" -eq 2 ] && grep -q 'postgres' "${WORK}/err" &&
    grep -qF 'missing' "${WORK}/err"; then
    ok "rc 2, stderr names postgres and missing"
  else
    fail "verify after deletion -> rc ${rc_cli}: [$(cat "${WORK}/err")]"
  fi
}

status_arm() {
  step "STATUS — one JSON object, states in packet order, exit 0"
  run status t1
  if [ "${rc_cli}" -eq 0 ] &&
    jq -e '(.import_id == "t1") and (.packets | length == 2)
      and (.packets | map(.state) == ["failed", "failed"])
      and (.packets | map(.id) == ["postgres", "redis"])' "${WORK}/out" >/dev/null 2>&1; then
    ok "import_id t1, states [failed, failed] in packet order"
  else
    fail "status t1 -> rc ${rc_cli}: [$(cat "${WORK}/out")]"
  fi
}

cli_arm() {
  step "CLI — an unknown id, no verb and --help take the documented exit codes"
  run verify nope
  [ "${rc_cli}" -eq 2 ] && ok "verify nope -> rc 2" ||
    fail "verify nope -> rc ${rc_cli}, expected 2"
  run status nope
  [ "${rc_cli}" -eq 2 ] && ok "status nope -> rc 2" ||
    fail "status nope -> rc ${rc_cli}, expected 2"
  run
  if [ "${rc_cli}" -eq 2 ] && grep -q 'usage:' "${WORK}/err"; then
    ok "no verb -> rc 2 with usage on stderr"
  else
    fail "no verb -> rc ${rc_cli}, expected 2"
  fi
  run --help
  if [ "${rc_cli}" -eq 0 ] && grep -q 'usage:' "${WORK}/out"; then
    ok "--help -> rc 0 with usage on stdout"
  else
    fail "--help -> rc ${rc_cli}, expected 0"
  fi
  grep -qE 'shellcheck[ ]+disable' "${CLI}" "${SCRIPT_DIR}/m222-grobase-import-pack.sh" &&
    fail "a shellcheck finding is hidden behind a disable directive" ||
    ok "no disable directive in either new file (H-20 stays honest)"
}

# TAMPER — a pushed manifest is input: an artifact name that walks out of the import dir is
# refused before any file is read or any state word is written.
tamper_arm() {
  step "TAMPER — a manifest naming a path lib-packets.sh would not produce is refused"
  run pack "${SEEDS}" --id t3
  local t3="${IMPORT_ROOT}/t3" edited
  edited="$(jq '.packets[0].artifact = "../t1/redis.rdb"' "${t3}/manifest.json")"
  printf '%s\n' "${edited}" >"${t3}/manifest.json"
  run verify t3
  [ "${rc_cli}" -eq 2 ] && [ "$(cat "${t3}/state/postgres")" = "staged" ] &&
    ok "verify t3 -> rc 2, state/postgres still staged" ||
    fail "tampered verify -> rc ${rc_cli}, state/postgres=$(cat "${t3}/state/postgres")"
  run status t3
  [ "${rc_cli}" -eq 2 ] && ok "status t3 -> rc 2" ||
    fail "tampered status -> rc ${rc_cli}, expected 2"
}

pack_arm
tamper_arm
contents_arm
manifest_arm
sums_arm
mode_arm
collide_arm
badid_arm
nopack_arm
verify_arm
corrupt_arm
missing_arm
status_arm
cli_arm

if [ "${rc}" -eq 0 ]; then
  printf '%s[M222] PASS — an import dir carries the captured dumps only, and verify/status report state without applying%s\n' "${_G}" "${_0}"
else
  printf '%s[M222] FAIL%s\n' "${_R}" "${_0}"
fi
exit "${rc}"
