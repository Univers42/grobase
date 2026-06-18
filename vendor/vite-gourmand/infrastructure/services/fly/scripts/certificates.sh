#!/bin/bash
set -euo pipefail

APP_NAME="${FLY_APP:-vite-gourmand-withered-glitter-7902}"
HOSTS="${HOSTS:-vite-gourmand.fr www.vite-gourmand.fr}"
CREATE_CERTS="${CREATE_CERTS:-false}"

cd "${PROJECT_ROOT:-/workspace}"

echo "Fly app: $APP_NAME"
echo "Certificate hosts: $HOSTS"
echo ""

echo "Assigned Fly IPs"
flyctl ips list -a "$APP_NAME"

echo ""
echo "Certificate setup"
for host in $HOSTS; do
    if [[ "$CREATE_CERTS" == "true" ]]; then
        echo "Requesting/refreshing Fly managed certificate for $host"
        flyctl certs add "$host" -a "$APP_NAME"
    else
        echo "Dry run for $host. Set CREATE_CERTS=true to run: flyctl certs add $host -a $APP_NAME"
    fi

    echo ""
    echo "Current certificate status for $host:"
    flyctl certs show "$host" -a "$APP_NAME" || true
    echo ""
done

cat <<EOF
DNS reminder:
1. Run: flyctl ips list -a $APP_NAME
2. For vite-gourmand.fr, create A/AAAA records to the Fly IPs.
3. For www.vite-gourmand.fr, create a CNAME to $APP_NAME.fly.dev or A/AAAA records to the Fly IPs.
4. Re-run this script, then verify with: scripts/security/verify-production-https.sh
EOF