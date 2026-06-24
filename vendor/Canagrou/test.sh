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

if [[ "${WHAT}" == "all" || "${WHAT}" == "browser" ]]; then
  run "browser (Playwright e2e over HTTPS — every flow + edge case)"
  PW_IMAGE="mcr.microsoft.com/playwright:v1.49.1-jammy"
  if docker image inspect "${PW_IMAGE}" >/dev/null 2>&1; then
    [ -f "${HERE}/web/certs/cert.pem" ] || { mkdir -p "${HERE}/web/certs"; openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "${HERE}/web/certs/key.pem" -out "${HERE}/web/certs/cert.pem" -days 365 -subj "/CN=localhost" \
      -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1 || true; }
    docker rm -f canagrou-web >/dev/null 2>&1
    docker run -d --name canagrou-web --network host -e PORT=8123 -v "${HERE}":/canagrou -w /canagrou/web "${NODE_IMAGE}" node serve.mjs >/dev/null 2>&1
    docker run --rm -v "${HERE}/web":/web -w /web "${NODE_IMAGE}" sh -c '[ -d node_modules/playwright ] || npm i playwright@1.49.1 --silent' >/dev/null 2>&1
    curl -sk -o /dev/null --retry 15 --retry-delay 1 --retry-connrefused https://localhost:8123/ 2>/dev/null || true
    # Clean test-created data before each suite so the feed stays light: the
    # feed loads counts per card (N+1), and accumulated posts across suites would
    # blow Kong's per-IP rate limits (429). Keeps any human account.
    clean_re='^(full_|feed_|noprof|bro_|tag_|tagtest|feeduser|dup|seq|exec|smoke_|m146|in_|cors|diag|tester_|intest|rt|p)'
    for spec in browser-full.mjs browser-feed.mjs browser-profileless.mjs browser-e2e.mjs; do
      docker exec mini-baas-postgres psql -U postgres -d canagrou -c "DELETE FROM profiles WHERE username ~* '${clean_re}';" >/dev/null 2>&1 || true
      docker run --rm --network host -v "${HERE}/web":/web -w /web -e SPA_URL=https://localhost:8123 "${PW_IMAGE}" sh -c "node test/${spec}" || rc=1
    done
    docker rm -f canagrou-web >/dev/null 2>&1
  else
    note "skipped: pull ${PW_IMAGE} to enable the real-browser suite"
  fi
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
