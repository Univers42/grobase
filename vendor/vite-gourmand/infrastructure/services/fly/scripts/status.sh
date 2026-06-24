#!/bin/bash
set -euo pipefail

APP_NAME="${FLY_APP:-vite-gourmand-withered-glitter-7902}"

echo "Application status for $APP_NAME"
flyctl status -a "$APP_NAME"

echo ""
echo "Assigned IPs"
flyctl ips list -a "$APP_NAME"

echo ""
echo "Services"
flyctl services list -a "$APP_NAME"

echo ""
echo "Recent releases"
flyctl releases -a "$APP_NAME" --json 2>/dev/null | node -e "
const data = JSON.parse(require('fs').readFileSync('/dev/stdin', 'utf8'));
if (Array.isArray(data)) {
  data.slice(0, 5).forEach((release) => {
    console.log('  ' + release.Version + ' - ' + release.Status + ' - ' + (release.Description || 'N/A') + ' - ' + release.CreatedAt);
  });
}
" 2>/dev/null || flyctl releases -a "$APP_NAME"