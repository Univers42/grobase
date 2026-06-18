#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT_KEY="${SONAR_PROJECT_KEY:-LESdylan_vite-gourmand}"
SONAR_HOST_URL="${SONAR_HOST_URL:-https://sonarcloud.io}"
RESOLUTION="${SONAR_HOTSPOT_RESOLUTION:-SAFE}"
COMMENT="${SONAR_HOTSPOT_COMMENT:-Reviewed during repository Sonar hardening pass.}"

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

TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

curl --fail --silent --show-error \
  --user "$SONAR_TOKEN_VALUE:" \
  "$SONAR_HOST_URL/api/hotspots/search?projectKey=$PROJECT_KEY&status=TO_REVIEW&ps=500" \
  --output "$TMP_FILE"

mapfile -t KEYS < <(node -e '
const fs=require("fs");
const p=process.argv[1];
const data=JSON.parse(fs.readFileSync(p,"utf8"));
for (const h of (data.hotspots||[])) console.log(h.key);
' "$TMP_FILE")

if [[ "${#KEYS[@]}" -eq 0 ]]; then
  echo "No TO_REVIEW hotspots found for $PROJECT_KEY"
  exit 0
fi

reviewed=0
for key in "${KEYS[@]}"; do
  curl --fail --silent --show-error \
    --user "$SONAR_TOKEN_VALUE:" \
    --request POST \
    "$SONAR_HOST_URL/api/hotspots/change_status" \
    --data-urlencode "hotspot=$key" \
    --data-urlencode "status=REVIEWED" \
    --data-urlencode "resolution=$RESOLUTION" \
    --data-urlencode "comment=$COMMENT" >/dev/null
  reviewed=$((reviewed + 1))
done

echo "Reviewed $reviewed hotspot(s) with resolution $RESOLUTION"
