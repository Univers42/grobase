#!/usr/bin/env sh
# serve.sh — run the Canagrou SPA server in a node container (Docker-first).
# Serves over HTTPS by default (protects the login/portal connection) using a
# self-signed localhost cert generated once into ./certs; set NO_TLS=1 for HTTP.
# Mounts the parent so the sibling services/ layer is reachable. The SPA talks
# only to this origin (same-origin reverse proxy → Kong), so there is no CORS.
#   PORT=8123 sh serve.sh        # https://localhost:8123
#   NO_TLS=1 PORT=8123 sh serve.sh
set -eu
PORT="${PORT:-8123}"
WEBDIR="$(cd "$(dirname "$0")" && pwd)"
APPDIR="$(cd "$WEBDIR/.." && pwd)"
REPO="$(cd "$WEBDIR/../../.." && pwd)"
CERTDIR="$WEBDIR/certs"
# Prefer the project's CA-signed localhost cert (certs/localhost.pem, issued by
# the Track Binocle CA that `make certs-trust-local` installs) so the BROWSER
# shows SECURE. Fall back to a self-signed cert only if it's absent.
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
  -v "$APPDIR":/canagrou -w /canagrou/web node:22-alpine node serve.mjs
