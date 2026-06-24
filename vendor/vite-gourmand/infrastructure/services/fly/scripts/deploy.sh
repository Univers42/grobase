#!/bin/bash
set -euo pipefail

APP_NAME="${FLY_APP:-vite-gourmand-withered-glitter-7902}"
FLY_CONFIG="${FLY_CONFIG:-infrastructure/services/fly/config/fly.toml}"

cd "${PROJECT_ROOT:-/workspace}"

echo "Deploying $APP_NAME with $FLY_CONFIG"
flyctl deploy -a "$APP_NAME" -c "$FLY_CONFIG"