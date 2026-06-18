#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

load_sonar_token() {
  if [[ -n "${SONAR_TOKEN:-}" ]]; then
    printf '%s' "$SONAR_TOKEN"
    return
  fi

  local env_file="$REPO_ROOT/.env.production"
  if [[ -f "$env_file" ]]; then
    awk -F= '$1 == "SONAR_TOKEN" { sub(/^[^=]*=/, ""); print; exit }' "$env_file" \
      | tr -d '\r' \
      | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
  fi
}

SONAR_TOKEN_VALUE="$(load_sonar_token)"
if [[ -z "$SONAR_TOKEN_VALUE" ]]; then
  echo "SONAR_TOKEN is required. Export it or define it in .env.production." >&2
  exit 1
fi

cd "$REPO_ROOT"

if command -v sonar-scanner >/dev/null 2>&1; then
  SONAR_TOKEN="$SONAR_TOKEN_VALUE" sonar-scanner "$@"
else
  SONAR_TOKEN="$SONAR_TOKEN_VALUE" npx --yes sonar-scanner "$@"
fi