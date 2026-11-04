#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m267-shape-names.sh — a name that means no stack is refused                 #
#                                                                              #
#  An unknown PACKAGE or EDITION resolved to no profile, and compose with no   #
#  profile starts the seven core containers. `make all PACKAGE=enterprise`,    #
#  an alias packages.json promises, printed success over them on 2026-11-04.   #
#  Hermetic: make -n, nothing is started.                                      #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT" || exit 1
rc=0
ok() { printf '  ✓ %s\n' "$1"; }
fail() {
  printf '[M267] FAIL — %s\n' "$1"
  rc=1
}
check() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: got '$2', expected '$3'"; fi; }
mk() { env -u PROFILES -u PACKAGE -u EDITION make --no-print-directory "$@"; }
variable() { # <name> [make args]
  v=$1
  shift
  mk --eval="_m267: ; @echo \$($v)" _m267 "$@" 2>/dev/null
}
profiles() { variable ACTIVE_PROFILES "$@"; }
says() { mk _require-shape "$@" 2>&1; }
code() {
  mk _require-shape "$@" >/dev/null 2>&1
  printf '%s' "$?"
}

max=$(profiles PACKAGE=max)
[ -n "$max" ] || fail "PACKAGE=max resolved to no profile"
check "enterprise is max" "$(profiles PACKAGE=enterprise)" "$max"
for p in $(variable PACKAGES) enterprise; do
  check "PACKAGE=$p is a stack" "$(code "PACKAGE=$p")" 0
  [ -n "$(profiles "PACKAGE=$p")" ] || fail "PACKAGE=$p resolves to no profile"
done
for e in $(variable EDITIONS); do
  check "EDITION=$e is known" "$(code "EDITION=$e")" 0
done

for bad in standard enterprize; do
  check "PACKAGE=$bad is refused" "$(code "PACKAGE=$bad")" 2
done
check "... naming the choices" "$(says PACKAGE=standard | grep -c 'unknown PACKAGE=standard: use basic')" 1
check "EDITION=quary is refused" "$(code EDITION=quary)" 2
check "... naming the choices" "$(says EDITION=quary | grep -c 'unknown EDITION=quary: use lean')" 1
for binary in nano free; do
  check "PACKAGE=$binary is refused" "$(code "PACKAGE=$binary")" 2
  check "... sending it to its target" "$(says "PACKAGE=$binary" | grep -c 'make nano-up')" 1
done
check "raw PROFILES= stays the override" "$(code PROFILES=anything PACKAGE=standard)" 0

# -n prints the plan without running it, so this reads its first step.
for verb in all up pull build; do
  check "make $verb refuses before anything else" \
    "$(mk -n "$verb" PACKAGE=standard 2>/dev/null | head -n1 | grep -c 'unknown PACKAGE=standard')" 1
done

# The catalog cannot gain a name the Makefile has never heard of.
for name in $(jq -r '(.packages | keys[]), (.aliases | keys[])' infra/config/packages/packages.json); do
  check "packages.json's $name is known here" "$(says "PACKAGE=$name" | grep -c 'unknown PACKAGE')" 0
done

exit "$rc"
