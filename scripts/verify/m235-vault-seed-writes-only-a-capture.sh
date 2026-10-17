#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m235-vault-seed-writes-only-a-capture.sh — a seed run that captured       #
#  nothing leaves the seed set alone, and SHA256SUMS lists the seed set only  #
#                                                                              #
#  2026-10-15, `make vault42-seed` on a host whose stack runs in a VM: every  #
#  engine SKIPPED, and vault-seed.sh still rewrote MANIFEST.json to           #
#  "captured: []" (grobase-import refuses that; a restore reads it as no      #
#  coverage) and re-hashed every top-level file of ./secrets into SHA256SUMS, #
#  four personal credential files included — their names and hashes then go  #
#  to every teammate, whose checkout never receives them.                     #
#                                                                              #
#  Arms: NONE (no engine: exit 1, the seed dir unchanged byte for byte) ·     #
#        ONE (redis only: captured [redis]; SHA256SUMS lists MANIFEST.json    #
#        and the archives, never *.env or a suffix-less file; it verifies).   #
#                                                                              #
#  Runs the real script against a fake `docker` on PATH: no stack, no         #
#  network, no credential read.                                               #
#                                                                              #
# **************************************************************************** #
set -uo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VS="${ROOT}/scripts/ops/vault-seed.sh"

_B=$'\033[0;36m' _G=$'\033[0;32m' _R=$'\033[0;31m' _0=$'\033[0m'
rc=0
step() { printf '%s[M235] %s%s\n' "${_B}" "$1" "${_0}"; }
ok() { printf '%s  ✓ %s%s\n' "${_G}" "$1" "${_0}"; }
fail() {
  printf '%s[M235] FAIL — %s%s\n' "${_R}" "$1" "${_0}"
  rc=1
}

[ -f "${VS}" ] || {
  fail "missing ${VS#"${ROOT}"/}"
  exit 1
}
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# fake_docker RUNNING — a docker whose `ps` lists RUNNING and whose redis answers like a
# finished BGSAVE; anything else fails, as a missing engine would.
fake_docker() {
  mkdir -p "${work}/bin"
  cat >"${work}/bin/docker" <<EOF
#!/bin/sh
case "\$1" in
ps) [ -z "$1" ] || echo "$1" ;;
exec) case "\$*" in *"INFO persistence"*) echo rdb_bgsave_in_progress:0 ;; esac ;;
cp) printf 'REDIS0011 fake rdb' >"\$3" ;;
*) exit 1 ;;
esac
EOF
  chmod +x "${work}/bin/docker"
}

# A seed dir as a checkout's ./secrets holds it: a capture, its record, and personal files.
seed_dir() {
  rm -rf "${work}/seeds" && mkdir -p "${work}/seeds"
  (cd "${work}/seeds" &&
    printf 'pg' | gzip >postgres-all.sql.gz &&
    printf '{"captured": ["postgres"], "skipped": []}\n' >MANIFEST.json &&
    printf 'FT_PASSWORD=x\n' >someone.env &&
    printf 'FT_PASSWORD=y\n' >my_vault &&
    sha256sum MANIFEST.json postgres-all.sql.gz >SHA256SUMS)
}
state() { (cd "${work}/seeds" && find . -type f -exec sha256sum {} + | sort); }
seed() { PATH="${work}/bin:${PATH}" SEED_DIR="${work}/seeds" sh "${VS}" >"${work}/out" 2>&1; }

step "NONE — no engine running"
fake_docker ""
seed_dir
before="$(state)"
if seed; then fail "a run that captured nothing exited 0"; else ok "a run that captured nothing fails"; fi
grep -q "nothing was captured" "${work}/out" && ok "it says why" || fail "no reason given: $(tail -1 "${work}/out")"
[ "$(state)" = "${before}" ] && ok "the seed dir is unchanged, byte for byte" ||
  fail "the seed dir changed: $(diff <(echo "${before}") <(state) | tr '\n' ' ')"

step "ONE — redis only"
fake_docker mini-baas-redis
seed_dir
if seed; then ok "the run exits 0"; else fail "the run failed: $(tail -1 "${work}/out")"; fi
[ "$(jq -c .captured "${work}/seeds/MANIFEST.json" 2>/dev/null)" = '["redis"]' ] &&
  ok "MANIFEST.json records captured [redis]" || fail "MANIFEST.json does not record captured [redis]"
listed="$(awk '{ print $2 }' "${work}/seeds/SHA256SUMS" | tr '\n' ' ')"
[ "${listed}" = "MANIFEST.json postgres-all.sql.gz redis.rdb " ] &&
  ok "SHA256SUMS lists MANIFEST.json and the archives only" || fail "SHA256SUMS lists: ${listed}"
(cd "${work}/seeds" && sha256sum -c --quiet SHA256SUMS) && ok "SHA256SUMS verifies" || fail "SHA256SUMS does not verify"
[ ! -e "${work}/seeds/.SHA256SUMS.tmp" ] && ok "no temp file left" || fail ".SHA256SUMS.tmp left behind"

exit "${rc}"
