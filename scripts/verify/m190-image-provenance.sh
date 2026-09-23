#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m190-image-provenance.sh — an image older than its source must be refused,  #
#  and an unrelated commit must not make it look older                         #
#                                                                              #
#  scripts/ops/image-provenance.sh stamps images with the commit they were     #
#  built from and, before `make up`, refuses one built before its build        #
#  context last changed (the grobase-realtime:latest-lagged-the-commit case,   #
#  issue #19). This gate runs it against a THROWAWAY git repository and        #
#  throwaway images labelled with chosen commits, where every answer is known: #
#    C1 touches svc/, C2 touches other/ only, C3 touches svc/ again            #
#    image labelled C3              -> ok, exit 0                              #
#    ... then C4 touches other/     -> still ok (precision: not every commit)  #
#    image labelled C1              -> STALE, exit 1                           #
#    image labelled C1, ALLOW=1     -> exit 0, still reported                  #
#    image with no label            -> unproven, exit 0                        #
#    override, clean / dirty svc/   -> label C4 / C4-dirty                     #
#                                                                              #
#  Mutant: M190_TOOL=scripts/test/mutants/fixtures/provenance-approve-all.sh   #
#  (a checker that approves everything) must turn this gate red (manifest row  #
#  provenance-blind).                                                          #
#                                                                              #
#  Its own temp repo and images, removed by an EXIT trap.                      #
# **************************************************************************** #
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TOOL="${M190_TOOL:-${ROOT}/scripts/ops/image-provenance.sh}"
case "${TOOL}" in /*) ;; *) TOOL="${ROOT}/${TOOL}" ;; esac
BASE_IMAGE="${M190_BASE_IMAGE:-curlimages/curl:latest}"
IMG="m190-img-$$"
REPO="$(mktemp -d)"
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M190] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M190] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}
cleanup() {
  docker image rm -f "${IMG}:c1" "${IMG}:c3" "${IMG}:none" "${IMG}:current" >/dev/null 2>&1 || true
  rm -rf "${REPO}"
}
trap cleanup EXIT

step "0/3 a throwaway repository with a known history"
command -v docker >/dev/null 2>&1 || fail "docker is required"
[ -f "${TOOL}" ] || fail "${TOOL} not found"
docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1 || docker pull -q "${BASE_IMAGE}" >/dev/null || fail "cannot pull ${BASE_IMAGE}"
g() { git -C "${REPO}" -c user.name=m190 -c user.email=m190@example.invalid "$@"; }
g init -q
mkdir -p "${REPO}/svc" "${REPO}/other"
printf 'FROM %s\n' "${BASE_IMAGE}" >"${REPO}/svc/Dockerfile"
echo 1 >"${REPO}/svc/a" && g add -A && g commit -qm c1 && C1=$(g rev-parse HEAD)
echo 1 >"${REPO}/other/x" && g add -A && g commit -qm c2
echo 1 >"${REPO}/svc/b" && g add -A && g commit -qm c3 && C3=$(g rev-parse HEAD)
cat >"${REPO}/config.json" <<EOF
{"name": "m190", "services": {"svc": {"image": "${IMG}:current", "build": {"context": "${REPO}/svc"}}}}
EOF
ok "c1 (svc) -> c2 (other) -> c3 (svc)"

build_as() { # <tag> [revision]
  local label=()
  [ -z "${2:-}" ] || label=(--label "org.opencontainers.image.revision=$2")
  docker build -q "${label[@]}" -t "${IMG}:$1" "${REPO}/svc" >/dev/null
  docker tag "${IMG}:$1" "${IMG}:current"
}

step "1/3 the verdicts"
bad=0
expect() { # <description> <want-rc> <want-substring> <rc> <output>
  if [ "$4" = "$2" ] && printf '%s' "$5" | grep -q -- "$3"; then
    printf '  ✓ %-44s rc=%s, "%s"\n' "$1" "$4" "$3"
  else
    printf '  \033[0;31m✗ %s: wanted rc=%s and "%s", got rc=%s: %s\033[0m\n' "$1" "$2" "$3" "$4" "$(printf '%s' "$5" | tr '\n' ' ' | cut -c1-160)"
    bad=$((bad + 1))
  fi
}
run() { # <description> <want-rc> <want-substring> [env...]
  local out rc=0
  out=$(env "${@:4}" GROBASE_PROVENANCE_REPO="${REPO}" bash "${TOOL}" check <"${REPO}/config.json" 2>&1) || rc=$?
  expect "$1" "$2" "$3" "$rc" "$out"
}
build_as c3 "${C3}"
run "built at c3 (last svc change)" 0 "1 ok"
echo 2 >"${REPO}/other/y" && g add -A && g commit -qm c4 && C4=$(g rev-parse HEAD)
run "then c4 touches other/ only" 0 "1 ok"
build_as c1 "${C1}"
run "built at c1, svc changed in c3" 1 "STALE"
run "same, GROBASE_ALLOW_STALE_IMAGES=1" 0 "1 stale" GROBASE_ALLOW_STALE_IMAGES=1
build_as none ""
run "no revision label" 0 "unproven"

step "2/3 the override stamps HEAD, and -dirty for an uncommitted context"
out=$(GROBASE_PROVENANCE_REPO="${REPO}" bash "${TOOL}" override "${REPO}/config.json" </dev/null 2>&1 || true)
expect "override on a clean svc/" 0 "\"${C4}\"" 0 "${out}"
echo 3 >>"${REPO}/svc/a"
out=$(GROBASE_PROVENANCE_REPO="${REPO}" bash "${TOOL}" override "${REPO}/config.json" </dev/null 2>&1 || true)
expect "override with svc/ modified" 0 "\"${C4}-dirty\"" 0 "${out}"

step "3/3 verdict"
[ "${bad}" -eq 0 ] || fail "${bad} provenance verdict(s) wrong"
ok "stale images refused, unrelated commits ignored, missing evidence reported"
