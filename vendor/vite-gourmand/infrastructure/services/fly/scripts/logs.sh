#!/bin/bash
set -euo pipefail

APP_NAME="${FLY_APP:-vite-gourmand-withered-glitter-7902}"

echo "Streaming logs for $APP_NAME"
flyctl logs -a "$APP_NAME"