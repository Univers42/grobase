#!/usr/bin/env bash
# Verify env coherence against the assembled .env:
#   - every MANDATORY generated secret is present
#   - every feature toggle that is ON has its (otherwise-optional) key set
# Exits non-zero on any gap. Run after `make env`.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/../.."
ENV=".env"
[ -f "$ENV" ] || {
  echo "no $ENV — run 'make env' first" >&2
  exit 1
}

val() { grep -m1 "^$1=" "$ENV" 2>/dev/null | cut -d= -f2-; }
miss=0

for k in JWT_SECRET POSTGRES_PASSWORD AUTHENTICATOR_PASSWORD \
  ADAPTER_REGISTRY_SERVICE_TOKEN ANON_KEY SERVICE_ROLE_KEY \
  MINIO_ROOT_PASSWORD; do
  [ -n "$(val "$k")" ] || {
    echo "MISSING mandatory secret: $k (run 'make env-secrets FORCE=1')"
    miss=1
  }
done

# A toggle that is ON makes its key mandatory; set those in .env.local.
require_when_on() {
  local toggle="$1"
  shift
  if [ "$(val "$toggle")" = "true" ]; then
    for k in "$@"; do
      [ -n "$(val "$k")" ] || {
        echo "$toggle=true but $k is blank — set it in .env.local"
        miss=1
      }
    done
  fi
}
require_when_on GOOGLE_OAUTH_ENABLED GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET
require_when_on GITHUB_OAUTH_ENABLED GITHUB_CLIENT_ID GITHUB_CLIENT_SECRET
require_when_on FORTYTWO_OAUTH_ENABLED FORTYTWO_CLIENT_ID FORTYTWO_CLIENT_SECRET

if [ "$miss" -eq 0 ]; then
  echo "env OK — mandatory secrets present; every enabled feature has its key."
else
  exit 1
fi
