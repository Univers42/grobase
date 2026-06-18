#!/usr/bin/env bash
# **************************************************************************** #
#  test.sh — run the Canagrou-on-Grobase test suite from one entrypoint.        #
#                                                                              #
#  Kept OUT of the core gate battery (run-gate-battery.sh) on purpose: Canagrou #
#  is a vendored playground, so its tests don't gate core product CI. Layers:   #
#    web:wiring   offline node:test of the web client lib request shapes        #
#    web:smoke    live: the real web lib end-to-end against the running stack   #
#    gate:m146    live: the full auth→post→like→comment→storage→realtime→       #
#                 reflection gate                                               #
#    flutter      offline `flutter test` (skipped if no flutter toolchain)      #
#                                                                              #
#  Usage:  bash vendor/Canagrou/test.sh [web|gate|flutter|all]   (default all)  #
#  Live layers need the stack up (Kong, gotrue, query, storage, realtime).      #
# **************************************************************************** #
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../.." && pwd)"
NODE_IMAGE="${NODE_IMAGE:-node:22-alpine}"
WHAT="${1:-all}"
rc=0

run() { printf '\n\033[0;36m── %s ──\033[0m\n' "$1"; }
note() { printf '\033[0;33m  … %s\033[0m\n' "$*"; }

if [[ "${WHAT}" == "all" || "${WHAT}" == "web" ]]; then
  run "web:wiring (offline, node:test)"
  docker run --rm -v "${HERE}/web":/web -w /web "${NODE_IMAGE}" node --test test/wiring.test.mjs || rc=1

  run "web:smoke (live — needs the stack up + seed run)"
  if [[ -f "${HERE}/web/.env" ]]; then
    docker run --rm --network host -v "${HERE}/web":/web -w /web "${NODE_IMAGE}" node test/smoke.mjs || rc=1
  else
    note "skipped: vendor/Canagrou/web/.env missing — run scripts/seed/canagrou-tenant.sh"
  fi
fi

if [[ "${WHAT}" == "all" || "${WHAT}" == "gate" ]]; then
  run "gate:m146 (live e2e)"
  bash "${REPO_ROOT}/scripts/verify/m146-canagrou-roundtrip.sh" || rc=1
fi

if [[ "${WHAT}" == "all" || "${WHAT}" == "flutter" ]]; then
  run "flutter (offline unit/widget)"
  if docker image inspect ghcr.io/cirruslabs/flutter:stable >/dev/null 2>&1; then
    docker run --rm -v "${HERE}/mobile":/app -w /app ghcr.io/cirruslabs/flutter:stable \
      sh -c 'flutter pub get && flutter test' || rc=1
  else
    note "skipped: no flutter toolchain image (ghcr.io/cirruslabs/flutter:stable). Run: cd mobile && flutter test"
  fi
fi

if [[ "${rc}" == "0" ]]; then
  printf '\n\033[0;32m[canagrou] ALL REQUESTED TESTS GREEN\033[0m\n'
else
  printf '\n\033[0;31m[canagrou] some tests FAILED (rc=%s)\033[0m\n' "${rc}"
fi
exit "${rc}"
