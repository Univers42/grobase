#!/usr/bin/env sh
# build-css.sh — compile the SPA in a node container (Docker-first), producing the
# dist/ bundle (Vite already inlines Tailwind via PostCSS). Use this when you want
# a production build without a host toolchain. For just-CSS iteration, run vite.
set -eu
WEBDIR="$(cd "$(dirname "$0")" && pwd)"
exec docker run --rm -v "$WEBDIR":/nimbus -w /nimbus \
  -v nimbus-web-nm:/nimbus/node_modules node:22-alpine \
  sh -c 'npm install --no-audit --no-fund --silent && npx vite build'
