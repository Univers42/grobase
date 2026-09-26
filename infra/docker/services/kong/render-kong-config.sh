#!/bin/sh
# render-kong-config.sh TEMPLATE OUT — write Kong's declarative config from the
# template, substituting every __PLACEHOLDER__ from the environment.
#
# KONG_CORS_ORIGIN_DEV_LIST (comma-separated) becomes one CORS origin per item; empty
# or unset adds none, so production ships only the configured KONG_CORS_ORIGIN_*
# origins (H-15: localhost dev ports used to be hard-coded, credentials: true).
# Exits non-zero, before Kong starts, if any __PLACEHOLDER__ survives.
set -eu

tmpl="$1"
out="$2"
dev="$(mktemp)"
trap 'rm -f "$dev"' EXIT

printf '%s\n' "${KONG_CORS_ORIGIN_DEV_LIST:-}" | tr ',' '\n' |
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' -e 's|^|        - |' >"$dev"

sed \
  -e "/__KONG_CORS_ORIGIN_DEV_LIST__/{r $dev" -e 'd;}' \
  -e "s|__KONG_PUBLIC_API_KEY__|${KONG_PUBLIC_API_KEY:-}|g" \
  -e "s|__KONG_SERVICE_API_KEY__|${KONG_SERVICE_API_KEY:-}|g" \
  -e "s|__KONG_CORS_ORIGIN_APP__|${KONG_CORS_ORIGIN_APP:-}|g" \
  -e "s|__KONG_CORS_ORIGIN_PLAYGROUND__|${KONG_CORS_ORIGIN_PLAYGROUND:-}|g" \
  -e "s|__KONG_CORS_ORIGIN_STUDIO__|${KONG_CORS_ORIGIN_STUDIO:-}|g" \
  -e "s|__KONG_CORS_ORIGIN_FRONTEND__|${KONG_CORS_ORIGIN_FRONTEND:-}|g" \
  -e "s|__JWT_SECRET__|${JWT_SECRET:-}|g" \
  -e "s|__GOTRUE_JWT_ISS__|${GOTRUE_JWT_ISS:-}|g" \
  -e "s|__KONG_ANON_UUID__|${KONG_ANON_UUID:-}|g" \
  "$tmpl" >"$out"

if left="$(grep -oE '__[A-Z0-9_]+__' "$out" | sort -u | tr '\n' ' ')" && [ -n "$left" ]; then
  printf 'render-kong-config: unsubstituted placeholders in %s: %s\n' "$out" "$left" >&2
  exit 1
fi
