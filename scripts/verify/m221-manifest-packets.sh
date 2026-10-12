#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m221-manifest-packets.sh — the seed manifest names the FILES, not just    #
#  the engines, and the file names it names are the ones restore opens        #
#                                                                              #
#  A MANIFEST.json listing "captured: [postgres, redis]" tells a reader which #
#  engines ran and nothing about what landed: no artefact name, no checksum,  #
#  no size, and no statement of how the dump was produced. Anyone asked to   #
#  mirror or import a seed set had to go and read vault-seed.sh to learn that #
#  postgres ships as pg_dumpall + gzip. The same two names appearing in two   #
#  files with nothing tying them together is how a rename lands and a restore #
#  silently finds no dump.                                                   #
#                                                                              #
#  So manifest v2 adds, after the four v1 keys, a `packets` array — one      #
#  {artifact, sha256, bytes, format, target, mode} object per CAPTURED engine #
#  — built by ONE reusable POSIX-sh function (scripts/lib/lib-packets.sh)    #
#  that grobase-import.sh will share rather than re-derive.                  #
#                                                                              #
#  Arms: SOURCE (POSIX sh, not bash) · MAP (7 engines + unknown) ·            #
#         PACKETS (jq-valid, ordered, hashed off the real bytes) ·            #
#         MISSING (a dump that is not on disk fails CLOSED) ·                 #
#         NAMES (the artefact names still equal dump_for) ·                  #
#         MANIFEST (v1 keys unchanged and still first).                      #
#                                                                              #
#  Static only: no network, no stack, no credential read, no value printed.  #
#                                                                              #
# **************************************************************************** #
set -uo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIB="${ROOT}/scripts/lib/lib-packets.sh"
VS="${ROOT}/scripts/ops/vault-seed.sh"
VR="${ROOT}/scripts/ops/vault-restore.sh"

_B=$'\033[0;36m' _G=$'\033[0;32m' _R=$'\033[0;31m' _Y=$'\033[0;33m' _0=$'\033[0m'
rc=0
step() { printf '%s[M221] %s%s\n' "${_B}" "$1" "${_0}"; }
ok() { printf '%s  ✓ %s%s\n' "${_G}" "$1" "${_0}"; }
fail() {
  printf '%s[M221] FAIL — %s%s\n' "${_R}" "$1" "${_0}"
  rc=1
}

# skipped IS not passed: a check that could not run leaves the gate red.
skip() {
  printf '%s[M221] SKIP — %s%s\n' "${_Y}" "$1" "${_0}"
  rc=1
}

for f in "${LIB}" "${VS}" "${VR}"; do
  [ -f "${f}" ] || {
    fail "missing ${f#"${ROOT}"/}"
    exit 1
  }
done

# fn_body <file> <name> — the lines of one shell function, so order can be checked.
fn_body() { awk -v fn="$2" '$0 == fn"() {" {p=1} p {print} p && /^}/ {exit}' "$1"; }

# /bin/sh is bash on this box, and a lib that only parses under bash is not a POSIX lib.
POSIX_SH=()
for _cand in dash busybox; do
  if command -v "${_cand}" >/dev/null 2>&1; then
    if [ "${_cand}" = busybox ]; then POSIX_SH=(busybox sh); else POSIX_SH=("${_cand}"); fi
    break
  fi
done
if [ "${#POSIX_SH[@]}" -eq 0 ]; then
  fail "no POSIX shell (dash or busybox sh) to source the lib with"
  exit 1
fi

# Two fake dumps, sized differently on purpose so a swapped bytes/sha256 cannot pass.
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
SEEDS="${WORK}/seeds"
mkdir -p "${SEEDS}"
printf 'fake-pg-dump\n' >"${SEEDS}/postgres-all.sql.gz"
printf 'REDIS-PAYLOAD-BYTES\n' >"${SEEDS}/redis.rdb"

# source_arm — one probe per name, because dash's `command -v` stops at its first
# operand and the three-operand form would prove one function while looking like three.
source_arm() {
  step "SOURCE — a POSIX sh defines the three functions and prints nothing"
  local out code want
  out="$("${POSIX_SH[@]}" -c '. "$1"
for f in packet_artifact packet_format packets_json; do command -v "$f"; done' _ "${LIB}" 2>&1)"
  code=$?
  want=$'packet_artifact\npacket_format\npackets_json'
  if [ "${code}" -eq 0 ] && [ "${out}" = "${want}" ]; then
    ok "${POSIX_SH[*]} defines all three, and sourcing prints nothing"
  else
    fail "sourcing lib-packets.sh under ${POSIX_SH[*]} printed: [${out}]"
  fi
}

map_arm() {
  step "MAP — all seven engines resolve; an unknown one prints nothing and returns 1"
  local got want a b arc f frc
  got="$("${POSIX_SH[@]}" -c '. "$1"
for e in postgres mysql mongo minio redis mssql dynamodb; do
  printf "%s %s\n" "$(packet_artifact "$e")" "$(packet_format "$e")"
done' _ "${LIB}")"
  want='postgres-all.sql.gz pg_dumpall_sql_gz
mysql-all.sql.gz mysqldump_sql_gz
mongo.archive.gz mongodump_archive_gz
minio.tar.gz tar_gz
redis.rdb rdb
mssql-all.tar.gz mssql_bak_tar_gz
dynamodb-all.tar.gz dynamodb_json_tar_gz'
  [ "${got}" = "${want}" ] && ok "7 engines -> artefact and format, exactly as specified" ||
    fail "the mapping drifted: got [${got}]"
  a="$("${POSIX_SH[@]}" -c '. "$1"; packet_artifact nope' _ "${LIB}" 2>/dev/null)"
  arc=$?
  f="$("${POSIX_SH[@]}" -c '. "$1"; packet_format nope' _ "${LIB}" 2>/dev/null)"
  frc=$?
  if [ "${arc}" -eq 1 ] && [ -z "${a}" ] && [ "${frc}" -eq 1 ] && [ -z "${f}" ]; then
    ok "packet_artifact/packet_format nope -> rc 1 and no output"
  else
    fail "an unknown engine is still guessed (artifact rc=${arc} [${a}], format rc=${frc} [${f}])"
  fi
}

packets_arm() {
  step "PACKETS — the array is jq-valid, ordered, and hashed off the real bytes"
  local out pg_sum rd_sum pg_bytes rd_bytes
  if ! command -v jq >/dev/null 2>&1; then
    skip "jq is not installed — packets_json is never parsed, so this gate cannot claim PASS"
    return
  fi
  out="$("${POSIX_SH[@]}" -c '. "$1"; packets_json "$2" postgres redis' _ "${LIB}" "${SEEDS}")"
  printf '%s\n' "${out}" | jq -e 'length == 2 and (map(.id) == ["postgres", "redis"])' >/dev/null 2>&1 &&
    ok "two packets, ids in the order given, each on its own line" ||
    fail "packets_json did not produce two ordered packets: [${out}]"
  pg_sum="$(sha256sum "${SEEDS}/postgres-all.sql.gz" | cut -d' ' -f1)"
  rd_sum="$(sha256sum "${SEEDS}/redis.rdb" | cut -d' ' -f1)"
  pg_bytes="$(wc -c <"${SEEDS}/postgres-all.sql.gz" | tr -d ' ')"
  rd_bytes="$(wc -c <"${SEEDS}/redis.rdb" | tr -d ' ')"
  printf '%s\n' "${out}" | jq -e '
    (.[0] | keys_unsorted == ["id", "engine", "artifact", "sha256", "bytes", "format", "target", "mode", "depends_on"])
    and .[0].id == .[0].engine and .[0].target.database == "*"
    and .[0].mode == "replace" and .[0].depends_on == []' >/dev/null 2>&1 &&
    ok "packet keys in the specified order, with target/mode/depends_on as specified" ||
    fail "the packet object shape drifted from the specified form"
  printf '%s\n' "${out}" | grep -c '^    {"id": "' | grep -qx 2 && [ "$(printf '%s\n' "${out}" | sed -n '1p')" = '[' ] &&
    [ "$(printf '%s\n' "${out}" | tail -1)" = '  ]' ] && ok "one packet per line at 4 spaces, array opened [ and closed at 2" ||
    fail "the block does not nest under a 2-space key: [${out}]"
  printf '%s\n' "${out}" | jq -e --arg ps "${pg_sum}" --arg pb "${pg_bytes}" --arg rs "${rd_sum}" --arg rb "${rd_bytes}" \
    '.[0].sha256 == $ps and (.[0].bytes | tostring) == $pb and
     .[1].sha256 == $rs and (.[1].bytes | tostring) == $rb' >/dev/null 2>&1 &&
    ok "sha256 and bytes match sha256sum/wc -c of the files themselves" ||
    fail "a packet describes bytes that are not the file on disk"
  [ "$("${POSIX_SH[@]}" -c '. "$1"; packets_json "$2"' _ "${LIB}" "${SEEDS}")" = '[]' ] &&
    ok "no engine -> exactly []" ||
    fail "packets_json with no ENGINE does not print []"
}

missing_arm() {
  step "MISSING — a dump that is not on disk fails closed, and stdout stays empty"
  local out code err unknown ucode uout
  out="$("${POSIX_SH[@]}" -c '. "$1"; packets_json "$2" postgres mysql' _ "${LIB}" "${SEEDS}" 2>"${WORK}/err")"
  code=$?
  if [ "${code}" -ne 0 ] && [ -z "${out}" ]; then
    ok "mysql absent -> rc ${code}, and nothing on stdout"
  else
    fail "a missing dump still produced stdout (rc=${code}): [${out}]"
  fi
  err="$(cat "${WORK}/err")"
  printf '%s' "${err}" | grep -qF 'mysql' && printf '%s' "${err}" | grep -qF 'mysql-all.sql.gz' &&
    ok "the stderr line names the engine and the file it expected" ||
    fail "the stderr line does not name mysql / mysql-all.sql.gz: [${err}]"
  uout="$("${POSIX_SH[@]}" -c '. "$1"; packets_json "$2" postgres nope' _ "${LIB}" "${SEEDS}" 2>"${WORK}/uerr")"
  ucode=$?
  [ "${ucode}" -ne 0 ] && [ -z "${uout}" ] && ok "an unknown engine inside a real list also fails closed" ||
    fail "an unknown engine was silently dropped instead of failing the whole array"
}

names_arm() {
  step "NAMES — the artefact names are the ones vault-restore.sh resolves"
  local body eng file missing
  body="$(fn_body "${VR}" dump_for)"
  missing=""
  for eng in postgres mysql mongo minio redis; do
    file="$("${POSIX_SH[@]}" -c '. "$1"; packet_artifact "$2"' _ "${LIB}" "${eng}")"
    printf '%s\n' "${body}" | grep -qF -- "${file}" || missing="${missing} ${file}"
  done
  for file in mssql-all.tar.gz dynamodb-all.tar.gz; do
    grep -qF -- "${file}" "${VR}" || missing="${missing} ${file}"
  done
  [ -z "${missing}" ] &&
    ok "dump_for names the five core dumps, and the mssql/dynamodb tarballs are read by those names" ||
    fail "vault-seed would write names vault-restore never opens:${missing}"
}

manifest_arm() {
  step "MANIFEST — the four v1 keys are untouched and still first"
  local body a b c d
  body="$(fn_body "${VS}" write_manifest)"
  a="$(printf '%s\n' "${body}" | grep -nF '"created_utc"' | head -1 | cut -d: -f1)"
  b="$(printf '%s\n' "${body}" | grep -nF '"source"' | head -1 | cut -d: -f1)"
  c="$(printf '%s\n' "${body}" | grep -nF '"captured"' | head -1 | cut -d: -f1)"
  d="$(printf '%s\n' "${body}" | grep -nF '"skipped"' | head -1 | cut -d: -f1)"
  if [ -n "${a}" ] && [ -n "${b}" ] && [ -n "${c}" ] && [ -n "${d}" ] &&
    [ "${a}" -lt "${b}" ] && [ "${b}" -lt "${c}" ] && [ "${c}" -lt "${d}" ]; then
    ok "created_utc, source, captured, skipped, in that order"
  else
    fail "write_manifest no longer writes the four v1 keys in order"
  fi
  printf '%s\n' "${body}" | grep -qF '"captured": [${cap:-}]' &&
    printf '%s\n' "${body}" | grep -qF '"skipped": [${skp:-}]' &&
    ok "captured and skipped still carry the computed lists" ||
    fail "a v1 key is now written with a hard-coded value"
  printf '%s\n' "${body}" | grep -qF '"manifest_version": 2' &&
    printf '%s\n' "${body}" | grep -qF '"packets":' &&
    printf '%s\n' "${body}" | grep -qF 'packets_json' &&
    grep -qF 'lib-packets.sh' "${VS}" &&
    ok "manifest_version 2 and the packets block, computed by packets_json from the sourced lib" ||
    fail "manifest_version, the packets block or the lib-packets.sh source line is missing"
  printf '%s\n' "${body}" | grep -qE 'packets=\$\(packets_json .*\) *\|\|' &&
    printf '%s\n' "${body}" | grep -qF 'die "cannot describe the captured packets' &&
    ok "a packets_json failure dies BEFORE the manifest is opened" ||
    fail "packets_json can fail without stopping the write — a manifest naming dumps that are not there"
}

source_arm
map_arm
packets_arm
missing_arm
names_arm
manifest_arm

if [ "${rc}" -eq 0 ]; then
  printf '%s[M221] PASS — manifest v2 names every captured dump, and the names are the ones restore opens%s\n' "${_G}" "${_0}"
else
  printf '%s[M221] FAIL%s\n' "${_R}" "${_0}"
fi
exit "${rc}"
