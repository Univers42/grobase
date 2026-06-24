#!/usr/bin/env sh
# serve.sh — run the built Nimbus SPA in a node container (Docker-first). Serves
# the dist/ build over HTTPS by default using the project's CA-signed localhost
# cert (falls back to self-signed, then HTTP via NO_TLS=1). The SPA talks only to
# this origin (same-origin reverse proxy → Kong), so there is no CORS.
#   PORT=8124 sh serve.sh        # https://localhost:8124
#   NO_TLS=1 PORT=8124 sh serve.sh
set -eu
PORT="${PORT:-8124}"
WEBDIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$WEBDIR/../../.." && pwd)"
CERTDIR="$WEBDIR/certs"
if [ "${NO_TLS:-0}" != "1" ]; then
  mkdir -p "$CERTDIR"
  if [ -f "$REPO/certs/localhost.pem" ] && [ -f "$REPO/certs/localhost-key.pem" ]; then
    cp "$REPO/certs/localhost.pem" "$CERTDIR/cert.pem"
    cp "$REPO/certs/localhost-key.pem" "$CERTDIR/key.pem"
  elif [ ! -f "$CERTDIR/cert.pem" ] && command -v openssl >/dev/null 2>&1; then
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$CERTDIR/key.pem" -out "$CERTDIR/cert.pem" \
      -days 365 -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1 || true
  fi
fi
exec docker run --rm --network host -e PORT="$PORT" ${NO_TLS:+-e NO_TLS="$NO_TLS"} \
  -v "$WEBDIR":/nimbus -w /nimbus node:22-alpine node serve.mjs
