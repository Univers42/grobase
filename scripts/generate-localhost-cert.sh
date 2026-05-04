#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CERT_DIR=${TRACK_BINOCLE_CERT_DIR:-"$REPO_DIR/certs"}
CA_NAME="Track Binocle Local Development CA"
CA_KEY="$CERT_DIR/track-binocle-local-ca-key.pem"
CA_CERT="$CERT_DIR/track-binocle-local-ca.pem"
SERVER_KEY="$CERT_DIR/localhost-key.pem"
SERVER_CSR="$CERT_DIR/localhost.csr"
SERVER_CERT="$CERT_DIR/localhost.pem"
OPENSSL_CONFIG="$CERT_DIR/localhost-openssl.cnf"
SERVER_EXT="$CERT_DIR/localhost-ext.cnf"

mkdir -p "$CERT_DIR"

cat > "$OPENSSL_CONFIG" <<'EOF'
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
CN = localhost

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
IP.1 = 127.0.0.1
IP.2 = ::1
EOF

cat > "$SERVER_EXT" <<'EOF'
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
IP.1 = 127.0.0.1
IP.2 = ::1
EOF

if [ ! -s "$CA_KEY" ] || [ ! -s "$CA_CERT" ]; then
  rm -f "$CA_KEY" "$CA_CERT"
  openssl genrsa -out "$CA_KEY" 4096 >/dev/null 2>&1
  openssl req -x509 -new -nodes \
    -key "$CA_KEY" \
    -sha256 \
    -days 3650 \
    -subj "/CN=$CA_NAME" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out "$CA_CERT" >/dev/null 2>&1
fi

rm -f "$SERVER_KEY" "$SERVER_CSR" "$SERVER_CERT"
openssl genrsa -out "$SERVER_KEY" 2048 >/dev/null 2>&1
openssl req -new \
  -key "$SERVER_KEY" \
  -out "$SERVER_CSR" \
  -config "$OPENSSL_CONFIG" >/dev/null 2>&1
openssl x509 -req \
  -in "$SERVER_CSR" \
  -CA "$CA_CERT" \
  -CAkey "$CA_KEY" \
  -CAcreateserial \
  -out "$SERVER_CERT" \
  -days 397 \
  -sha256 \
  -extfile "$SERVER_EXT" >/dev/null 2>&1

chmod 600 "$CA_KEY" "$SERVER_KEY"
chmod 644 "$CA_CERT" "$SERVER_CERT"
rm -f "$SERVER_CSR" "$OPENSSL_CONFIG" "$SERVER_EXT"

printf 'Generated local HTTPS certificate chain:\n'
printf '  CA certificate : %s\n' "$CA_CERT"
printf '  Server cert    : %s\n' "$SERVER_CERT"
printf '  Server key     : %s\n' "$SERVER_KEY"
openssl x509 -in "$SERVER_CERT" -noout -subject -issuer -dates -ext subjectAltName
