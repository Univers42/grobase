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
# Issues the server certificate an engine container presents under engine TLS,
# signed by the local CA that generate-localhost-cert.sh owns. Usage:
#   generate-engine-cert.sh            postgres, ENGINE_TLS=1 (ADR 0011)
#   generate-engine-cert.sh mongo      ENGINE_TLS_ENGINES="mongo" (ADR 0012)
#   generate-engine-cert.sh redis      ENGINE_TLS_ENGINES="redis" (ADR 0012)
#   generate-engine-cert.sh mariadb    ENGINE_TLS_ENGINES="mariadb" (ADR 0012)
#   generate-engine-cert.sh mysql      ENGINE_TLS_ENGINES="mysql" (ADR 0012)
#   generate-engine-cert.sh mysql8     ENGINE_TLS_ENGINES="mysql8" (ADR 0026)
#   generate-engine-cert.sh mssql      ENGINE_TLS_ENGINES="mssql" (ADR 0012)
#   generate-engine-cert.sh cockroach  ENGINE_TLS_ENGINES="cockroach" (ADR 0029)
# Output, under ENGINE_TLS_CERT_DIR (default certs/engines for postgres,
# certs/engine-tls/<engine> for the others): engine.pem, engine-key.pem (0600)
# and ca.pem, the public CA a client verifies against. The CA key never leaves
# certs/. Each engine gets a sibling directory, never one nested in another's
# mount, so no engine container can read another's key (G5b-C5).
# cockroach also gets the root client cert (CN=root, clientAuth) that sets the
# first SQL password, in the sibling <dir>-client (ENGINE_TLS_CLIENT_CERT_DIR):
# only the cockroach overlay mounts it, never an application container.
#
# Deliberately NOT called by expose.sh, `make certs` or the WAF CI steps: the
# cert existing must never be what turns TLS on (G5a-C1). Renewal: re-run, then
# recreate the engine; the running server holds a tmpfs copy of the old key.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
CERT_DIR=${TRACK_BINOCLE_CERT_DIR:-"$REPO_DIR/certs"}
ENGINE=${1:-postgres}
CA_KEY="$CERT_DIR/track-binocle-local-ca-key.pem"
CA_CERT="$CERT_DIR/track-binocle-local-ca.pem"

# Every in-network name a client dials the engine by: the service, its aliases,
# the container name, and the host-port forms.
case "$ENGINE" in
postgres)
  SANS="DNS:postgres,DNS:db,DNS:mini-baas-postgres,DNS:localhost,IP:127.0.0.1"
  OUT_DIR=${ENGINE_TLS_CERT_DIR:-"$CERT_DIR/engines"}
  ;;
mongo)
  SANS="DNS:mongo,DNS:mini-baas-mongo,DNS:localhost,IP:127.0.0.1"
  OUT_DIR=${ENGINE_TLS_CERT_DIR:-"$CERT_DIR/engine-tls/mongo"}
  ;;
redis)
  SANS="DNS:redis,DNS:mini-baas-redis,DNS:localhost,IP:127.0.0.1"
  OUT_DIR=${ENGINE_TLS_CERT_DIR:-"$CERT_DIR/engine-tls/redis"}
  ;;
mariadb)
  SANS="DNS:mariadb,DNS:mini-baas-mariadb,DNS:localhost,IP:127.0.0.1"
  OUT_DIR=${ENGINE_TLS_CERT_DIR:-"$CERT_DIR/engine-tls/mariadb"}
  ;;
mysql)
  SANS="DNS:mysql,DNS:mini-baas-mysql,DNS:localhost,IP:127.0.0.1"
  OUT_DIR=${ENGINE_TLS_CERT_DIR:-"$CERT_DIR/engine-tls/mysql"}
  ;;
mysql8)
  SANS="DNS:mysql8,DNS:mini-baas-mysql8,DNS:localhost,IP:127.0.0.1"
  OUT_DIR=${ENGINE_TLS_CERT_DIR:-"$CERT_DIR/engine-tls/mysql8"}
  ;;
mssql)
  SANS="DNS:mssql,DNS:mini-baas-mssql,DNS:localhost,IP:127.0.0.1"
  OUT_DIR=${ENGINE_TLS_CERT_DIR:-"$CERT_DIR/engine-tls/mssql"}
  ;;
cockroach)
  SANS="DNS:cockroach,DNS:mini-baas-cockroach,DNS:localhost,IP:127.0.0.1"
  OUT_DIR=${ENGINE_TLS_CERT_DIR:-"$CERT_DIR/engine-tls/cockroach"}
  ;;
*)
  printf 'Unknown engine %s: expected postgres, mongo, redis, mariadb, mysql, mysql8, mssql or cockroach.\n' "$ENGINE" >&2
  exit 2
  ;;
esac
KEY="$OUT_DIR/engine-key.pem"
CERT="$OUT_DIR/engine.pem"
# How openssl prints these SANs, so the reuse check matches this engine's whole set.
SANS_SHOWN=$(printf '%s' "$SANS" | sed 's/,/, /g; s/IP:/IP Address:/g')

# issue_leaf KEY CERT CN EKU [SANS]: a new key and a leaf the local CA signs for 397 days.
issue_leaf() {
  ext=$(mktemp)
  csr=$(mktemp)
  trap 'rm -f "$ext" "$csr"' EXIT
  printf '%s\n' "basicConstraints = critical,CA:FALSE" \
    "keyUsage = critical,digitalSignature,keyEncipherment" "extendedKeyUsage = $4" >"$ext"
  [ -z "${5:-}" ] || printf 'subjectAltName = %s\n' "$5" >>"$ext"
  rm -f "$1" "$2"
  (umask 077 && openssl genrsa -out "$1" 2048 >/dev/null 2>&1)
  openssl req -new -key "$1" -subj "/CN=$3" -out "$csr" >/dev/null 2>&1
  openssl x509 -req -in "$csr" -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$2" -days 397 -sha256 -extfile "$ext" >/dev/null 2>&1
  rm -f "$ext" "$csr"
}

# root_client_cert DIR: client.root.crt/.key, the cert cockroach's `cockroach sql
# --certs-dir` logs in with as root (a secure node refuses root's password until
# one is set, and an insecure node refuses to set one: devil g5-cockroach CR3/CR4).
root_client_cert() {
  mkdir -p "$1"
  chmod 755 "$1"
  if [ -s "$1/client.root.key" ] && [ -s "$1/client.root.crt" ] &&
    openssl verify -CAfile "$CA_CERT" -purpose sslclient "$1/client.root.crt" >/dev/null 2>&1 &&
    openssl x509 -checkend 2592000 -noout -in "$1/client.root.crt" >/dev/null 2>&1 &&
    openssl x509 -in "$1/client.root.crt" -noout -subject -nameopt RFC2253 | grep -qxF 'subject=CN=root'; then
    printf 'Using existing root client certificate %s\n' "$1/client.root.crt"
  else
    issue_leaf "$1/client.root.key" "$1/client.root.crt" root clientAuth
    printf 'New root client certificate in %s\n' "$1"
  fi
  chmod 600 "$1/client.root.key"
  chmod 644 "$1/client.root.crt"
}

if [ ! -s "$CA_KEY" ] || [ ! -s "$CA_CERT" ]; then
  printf 'No local CA in %s: run make certs (generate-localhost-cert.sh) first.\n' "$CERT_DIR" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
chmod 755 "$OUT_DIR"

if [ -s "$KEY" ] && [ -s "$CERT" ] &&
  openssl verify -CAfile "$CA_CERT" "$CERT" >/dev/null 2>&1 &&
  openssl x509 -checkend 2592000 -noout -in "$CERT" >/dev/null 2>&1 &&
  openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null | grep -qxF "    $SANS_SHOWN"; then
  printf 'Using existing engine certificate %s\n' "$CERT"
else
  issue_leaf "$KEY" "$CERT" "$ENGINE" serverAuth "$SANS"
  printf 'New engine certificate: a running %s keeps the old one until recreated.\n' "$ENGINE"
fi

chmod 600 "$KEY"
cp "$CA_CERT" "$OUT_DIR/ca.pem"
chmod 644 "$CERT" "$OUT_DIR/ca.pem"
openssl x509 -in "$CERT" -noout -subject -enddate -ext subjectAltName
[ "$ENGINE" != cockroach ] || root_client_cert "${ENGINE_TLS_CLIENT_CERT_DIR:-"$OUT_DIR-client"}"
