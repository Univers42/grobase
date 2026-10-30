#!/bin/sh
# render-kong-config.sh TEMPLATE OUT — write Kong's declarative config from the
# template, substituting every __PLACEHOLDER__ from the environment.
#
# KONG_CORS_ORIGIN_DEV_LIST (comma-separated) becomes one CORS origin per item; empty
# or unset adds none, so production ships only the configured KONG_CORS_ORIGIN_*
# origins (H-15: localhost dev ports used to be hard-coded, credentials: true).
# GROBASE_PUBLIC_ADDRESSES (comma-separated hosts/IPs) adds the origins
# public-origins.sh derives — mounted next to this script; unset/empty adds none.
# Exits non-zero, before Kong starts, if any __PLACEHOLDER__ survives.
set -eu

tmpl="$1"
out="$2"
dev="$(mktemp)"
trap 'rm -f "$dev" "$out.minio"' EXIT

printf '%s\n' "${KONG_CORS_ORIGIN_DEV_LIST:-}" | tr ',' '\n' |
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' -e 's|^|        - |' >"$dev"

if [ -n "${GROBASE_PUBLIC_ADDRESSES:-}" ]; then
  public="$(sh "$(dirname -- "$0")/public-origins.sh" "$GROBASE_PUBLIC_ADDRESSES" "${KONG_CORS_ORIGIN_DEV_LIST:-}")"
  printf '%s\n' "$public" | sed 's|^|        - |' >>"$dev"
fi

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

# KONG_MINIO_CA_FILE (set by docker-compose.engine-tls-minio.yml) moves the storage
# service to https://minio:9000, verified against that CA only (ADR 0030 MH8).
if [ -n "${KONG_MINIO_CA_FILE:-}" ]; then
  if [ ! -r "$KONG_MINIO_CA_FILE" ] || grep -q 'PRIVATE KEY' "$KONG_MINIO_CA_FILE"; then
    printf 'render-kong-config: KONG_MINIO_CA_FILE %s is unreadable or holds a key\n' "$KONG_MINIO_CA_FILE" >&2
    exit 1
  fi
  if ! awk -v id=a44a81c4-3810-45a6-b8a7-ff6b3941a994 -v ca="$KONG_MINIO_CA_FILE" '
    $0 == "    url: http://minio:9000" {
      print "    url: https://minio:9000"; print "    tls_verify: true"
      print "    ca_certificates: [" id "]"; hit = 1; next
    }
    { print }
    END {
      if (!hit) exit 1
      print "ca_certificates:"; print "  - id: " id; print "    cert: |"
      while ((getline line < ca) > 0) print "      " line
    }' "$out" >"$out.minio"; then
    printf 'render-kong-config: no storage url http://minio:9000 in %s\n' "$tmpl" >&2
    exit 1
  fi
  mv "$out.minio" "$out"
fi

if left="$(grep -oE '__[A-Z0-9_]+__' "$out" | sort -u | tr '\n' ' ')" && [ -n "$left" ]; then
  printf 'render-kong-config: unsubstituted placeholders in %s: %s\n' "$out" "$left" >&2
  exit 1
fi
