#!/bin/sh
# hypertube-catalog-bulk.sh — bulk-seed thousands of real public-domain films
# from archive.org's collection:feature_films into the Hypertube Mongo catalog.
# Loads the gitignored .hypertube-baas.env state, then runs the zero-dep Node
# seeder inside a node:20-alpine container on the mini-baas docker network
# (so it reaches Kong at mini-baas-kong:8000, not the host loopback). Idempotent.
set -eu

REPO_DIR="$(unset CDPATH; cd -- "$(dirname -- "$0")/../.." && pwd)"
STATE_ENV="${REPO_DIR}/.hypertube-baas.env"
NET="${HT_DOCKER_NET:-mini-baas_mini-baas}"
KONG_IN_NET="${HT_KONG_IN_NET:-http://mini-baas-kong:8000}"

# load_state sources the tenant state file, aborting if the seeder ran first.
load_state() {
  [ -f "$STATE_ENV" ] || {
    printf 'error: %s not found — run hypertube-tenant.sh first\n' "$STATE_ENV" >&2
    exit 1
  }
  set -a
  # shellcheck disable=SC1090
  . "$STATE_ENV"
  set +a
}

# run_seeder invokes the bulk catalog seeder in a node:20-alpine container.
run_seeder() {
  docker run --rm --network "$NET" \
    -e HT_KONG_URL="$KONG_IN_NET" \
    -e HT_ANON_APIKEY="$HT_ANON_APIKEY" \
    -e HT_API_KEY="$HT_API_KEY" \
    -e HT_MONGO_DB_ID="$HT_MONGO_DB_ID" \
    -e HT_CATALOG_TARGET="${HT_CATALOG_TARGET:-1500}" \
    -v "${REPO_DIR}:/r" -w /r \
    node:20-alpine node scripts/seed/hypertube-catalog-bulk.mjs
}

load_state
run_seeder
