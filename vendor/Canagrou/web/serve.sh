#!/usr/bin/env sh
# serve.sh — run the Canagrou SPA static server in a node container (Docker-first).
# Mounts the parent (vendor/Canagrou) so the sibling services/ plugin layer is
# reachable at /services/*. The SPA calls Kong cross-origin (CORS is open).
#   PORT=8123 sh serve.sh
set -eu
PORT="${PORT:-8123}"
WEBDIR="$(cd "$(dirname "$0")" && pwd)"
APPDIR="$(cd "$WEBDIR/.." && pwd)"
exec docker run --rm --network host -e PORT="$PORT" \
  -v "$APPDIR":/canagrou -w /canagrou/web node:22-alpine node serve.mjs
