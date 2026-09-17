# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    generate-localhost-cert.sh                         :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/31 17:57:21 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd) # script lives at scripts/certs/ → repo root is two up
CERT_DIR=${TRACK_BINOCLE_CERT_DIR:-"$REPO_DIR/certs"}
CA_NAME="Track Binocle Local Development CA"
CA_KEY="$CERT_DIR/track-binocle-local-ca-key.pem"
CA_CERT="$CERT_DIR/track-binocle-local-ca.pem"
SERVER_KEY="$CERT_DIR/localhost-key.pem"
SERVER_CSR="$CERT_DIR/localhost.csr"
SERVER_CERT="$CERT_DIR/localhost.pem"
OPENSSL_CONFIG="$CERT_DIR/localhost-openssl.cnf"
SERVER_EXT="$CERT_DIR/localhost-ext.cnf"

WAF_TLS_GID=${MINI_BAAS_WAF_TLS_GID:-101}

# The waf's nginx runs as uid/gid 101 and reads the key through a compose FILE
# secret, which bind-mounts the host inode as-is: compose (non-swarm) ignores the
# secret's uid/gid/mode keys, so host permissions ARE container permissions. The
# key must therefore be readable by gid 101 on the host without becoming
# world-readable. Three rungs, cheapest first; docker is the backstop because it
# is already a hard prerequisite and its daemon is root.
grant_waf_read() {
	if chgrp "$WAF_TLS_GID" "$1" 2>/dev/null; then
		chmod 640 "$1"
		return 0
	fi
	chmod 600 "$1"
	if command -v setfacl >/dev/null 2>&1 && setfacl -m "g:$WAF_TLS_GID:r" "$1" 2>/dev/null; then
		return 0
	fi
	docker run --rm -v "$CERT_DIR:/certs" --entrypoint sh busybox:1.37 -c \
		"chgrp $WAF_TLS_GID /certs/$(basename "$1") && chmod 640 /certs/$(basename "$1")" >/dev/null 2>&1
}

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
DNS.2 = host.docker.internal
DNS.3 = local-https-proxy
DNS.4 = track-binocle.test
DNS.5 = *.track-binocle.test
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
DNS.2 = host.docker.internal
DNS.3 = local-https-proxy
DNS.4 = track-binocle.test
DNS.5 = *.track-binocle.test
IP.1 = 127.0.0.1
IP.2 = ::1
EOF

ca_regenerated=0
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
  ca_regenerated=1
fi

server_needs_regen=1
if [ "$ca_regenerated" -eq 0 ] && [ -s "$SERVER_KEY" ] && [ -s "$SERVER_CERT" ]; then
  san=$(openssl x509 -in "$SERVER_CERT" -noout -ext subjectAltName 2>/dev/null || true)
  if openssl verify -CAfile "$CA_CERT" "$SERVER_CERT" >/dev/null 2>&1 \
    && openssl x509 -checkend 2592000 -noout -in "$SERVER_CERT" >/dev/null 2>&1; then
    case "$san" in
      *DNS:localhost*DNS:host.docker.internal*DNS:local-https-proxy*DNS:track-binocle.test*DNS:\*.track-binocle.test*IP\ Address:127.0.0.1*)
        server_needs_regen=0
        ;;
    esac
  fi
fi

if [ "$server_needs_regen" -eq 1 ]; then
  rm -f "$SERVER_KEY" "$SERVER_CSR" "$SERVER_CERT"
  openssl genrsa -out "$SERVER_KEY" 2048 >/dev/null 2>&1
  openssl req -new -key "$SERVER_KEY" -out "$SERVER_CSR" -config "$OPENSSL_CONFIG" >/dev/null 2>&1
  openssl x509 -req \
    -in "$SERVER_CSR" \
    -CA "$CA_CERT" \
    -CAkey "$CA_KEY" \
    -CAcreateserial \
    -out "$SERVER_CERT" \
    -days 397 \
    -sha256 \
    -extfile "$SERVER_EXT" >/dev/null 2>&1
else
  printf 'Using existing local HTTPS server certificate with required localhost SANs.\n'
fi

chmod 600 "$CA_KEY"
if ! grant_waf_read "$SERVER_KEY"; then
  printf 'Error: %s is not readable by the WAF gid %s (tried chgrp, setfacl, docker).\n' "$SERVER_KEY" "$WAF_TLS_GID" >&2
  printf '       The WAF will fail to start. Fix: sudo chgrp %s %s && sudo chmod 640 %s\n' "$WAF_TLS_GID" "$SERVER_KEY" "$SERVER_KEY" >&2
  exit 1
fi
chmod 644 "$CA_CERT" "$SERVER_CERT"
rm -f "$SERVER_CSR" "$OPENSSL_CONFIG" "$SERVER_EXT"

printf 'Generated local HTTPS certificate chain:\n'
printf '  CA certificate : %s\n' "$CA_CERT"
printf '  Server cert    : %s\n' "$SERVER_CERT"
printf '  Server key     : %s\n' "$SERVER_KEY"
openssl x509 -in "$SERVER_CERT" -noout -subject -issuer -dates -ext subjectAltName
