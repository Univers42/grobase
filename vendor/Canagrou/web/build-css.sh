#!/usr/bin/env sh
# build-css.sh — compile Tailwind to a STATIC public/tailwind.css (Docker-first),
# so the SPA is styled without the runtime CDN (which CSP/networks may block).
# Re-run after adding/removing utility classes anywhere under src/ or services/.
set -eu
WEBDIR="$(cd "$(dirname "$0")" && pwd)"
APPDIR="$(cd "$WEBDIR/.." && pwd)"
exec docker run --rm -v "$APPDIR":/canagrou -w /canagrou/web node:22-alpine \
  sh -c 'npm i -D tailwindcss@3.4.17 --silent >/dev/null 2>&1 && \
         npx tailwindcss -c tailwind.config.js -i src/styles/tailwind.css -o public/tailwind.css --minify'
