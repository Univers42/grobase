#!/usr/bin/env sh
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    generate-engine-cert.sh                            :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/30 10:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/10/30 10:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Issues the server certificate an engine container presents when ENGINE_TLS=1
# (docs/adr/0011-g5a-postgres-accept-tls.md), signed by the local CA that
# generate-localhost-cert.sh owns. Output, under ENGINE_TLS_CERT_DIR (default
# certs/engines): engine.pem, engine-key.pem (0600) and ca.pem, the public CA a
# client passes as sslrootcert. The CA key itself never leaves certs/.
#
# Deliberately NOT called by expose.sh, `make certs` or the WAF CI steps: the
# cert existing must never be what turns TLS on (G5a-C1). Renewal: re-run, then
# recreate postgres; the running server holds a tmpfs copy of the old key.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
CERT_DIR=${TRACK_BINOCLE_CERT_DIR:-"$REPO_DIR/certs"}
OUT_DIR=${ENGINE_TLS_CERT_DIR:-"$CERT_DIR/engines"}
CA_KEY="$CERT_DIR/track-binocle-local-ca-key.pem"
CA_CERT="$CERT_DIR/track-binocle-local-ca.pem"
KEY="$OUT_DIR/engine-key.pem"
CERT="$OUT_DIR/engine.pem"

# Every in-network name a client dials the central Postgres by: the service,
# its `db` alias, the container name, and the host-port forms.
SANS="DNS:postgres,DNS:db,DNS:mini-baas-postgres,DNS:localhost,IP:127.0.0.1"

if [ ! -s "$CA_KEY" ] || [ ! -s "$CA_CERT" ]; then
  printf 'No local CA in %s: run make certs (generate-localhost-cert.sh) first.\n' "$CERT_DIR" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
chmod 755 "$OUT_DIR"

if [ -s "$KEY" ] && [ -s "$CERT" ] &&
  openssl verify -CAfile "$CA_CERT" "$CERT" >/dev/null 2>&1 &&
  openssl x509 -checkend 2592000 -noout -in "$CERT" >/dev/null 2>&1 &&
  openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null | grep -q 'DNS:postgres, DNS:db'; then
  printf 'Using existing engine certificate %s\n' "$CERT"
else
  ext=$(mktemp)
  csr=$(mktemp)
  trap 'rm -f "$ext" "$csr"' EXIT
  printf '%s\n' "basicConstraints = critical,CA:FALSE" \
    "keyUsage = critical,digitalSignature,keyEncipherment" \
    "extendedKeyUsage = serverAuth" "subjectAltName = $SANS" >"$ext"
  rm -f "$KEY" "$CERT"
  (umask 077 && openssl genrsa -out "$KEY" 2048 >/dev/null 2>&1)
  openssl req -new -key "$KEY" -subj "/CN=postgres" -out "$csr" >/dev/null 2>&1
  openssl x509 -req -in "$csr" -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$CERT" -days 397 -sha256 -extfile "$ext" >/dev/null 2>&1
  printf 'New engine certificate: a running postgres keeps the old one until recreated.\n'
fi

chmod 600 "$KEY"
cp "$CA_CERT" "$OUT_DIR/ca.pem"
chmod 644 "$CERT" "$OUT_DIR/ca.pem"
openssl x509 -in "$CERT" -noout -subject -enddate -ext subjectAltName
