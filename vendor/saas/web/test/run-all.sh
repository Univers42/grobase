#!/bin/sh
# run-all.sh — run the Nimbus browser + a11y + console/CSP suite in the Playwright
# Docker image (Docker-first; no host browsers). Each spec runs with --network host
# so the container reaches https://localhost:8124. Exits non-zero on any failure.
#
#   sh test/run-all.sh                  # all specs
#   SPA_URL=https://localhost:8124 sh test/run-all.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WEB="$(cd "$HERE/.." && pwd)"
PW_IMAGE="mcr.microsoft.com/playwright:v1.49.1-jammy"
SPA_URL="${SPA_URL:-https://localhost:8124}"
rc=0

if ! docker image inspect "$PW_IMAGE" >/dev/null 2>&1; then
  printf '\033[0;31m[nimbus-test] missing %s — pull it first\033[0m\n' "$PW_IMAGE" >&2
  exit 2
fi

# One-time: install playwright (runtime) + axe-core into test/node_modules so the
# specs can `import { chromium }` and a11y-axe can read axe.min.js.
printf '\033[0;36m── deps: playwright@1.49.1 + axe-core (in container) ──\033[0m\n'
docker run --rm -v "$HERE":/web/test -w /web/test "$PW_IMAGE" sh -c \
  '[ -d node_modules/playwright ] && [ -d node_modules/axe-core ] || npm i --no-save --silent playwright@1.49.1 axe-core@4.10.2' \
  || { printf '\033[0;31m[nimbus-test] dep install failed\033[0m\n' >&2; exit 2; }

run_spec() {
  spec="$1"
  printf '\n\033[0;36m── %s ──\033[0m\n' "$spec"
  docker run --rm --network host \
    -v "$WEB":/web -w /web/test \
    -e SPA_URL="$SPA_URL" \
    "$PW_IMAGE" node "$spec" || rc=1
}

for spec in \
  browser-landing.mjs \
  browser-auth.mjs \
  browser-register-is-real.mjs \
  browser-overview.mjs \
  browser-users.mjs \
  browser-inbox.mjs \
  browser-revenue-acid.mjs \
  browser-content.mjs \
  a11y-axe.mjs \
  console-csp.mjs
do
  run_spec "$spec"
done

if [ "$rc" -eq 0 ]; then
  printf '\n\033[0;32m[nimbus-test] ALL SUITES GREEN\033[0m\n'
else
  printf '\n\033[0;31m[nimbus-test] some suites FAILED (rc=%s)\033[0m\n' "$rc"
fi
exit "$rc"
