#!/bin/sh
# Entrypoint for an engine selected in ENGINE_TLS_ENGINES (docs/adr/0012-g5b-engine-accept-tls.md):
# adds accept-mode TLS, then hands over to the image's own entrypoint, passed as "$@".
#
# These images run non-root and refuse a 0600 key they do not own, and the bind mount keeps
# the host owner. So the overlay starts this as root only to copy the key into a tmpfs owned
# by the image's uid, then setpriv drops to that uid before the engine starts: PID 1 never
# runs the engine as root (G5b-C3). Asked for TLS with no cert, it refuses to start rather
# than fall back to plaintext (G5b-C8).
set -eu

src=/etc/engine-tls
dst=/run/engine-tls
name=${ENGINE_TLS_NAME:?the overlay sets ENGINE_TLS_NAME}
uid=${ENGINE_TLS_UID:?the overlay sets ENGINE_TLS_UID}
gid=${ENGINE_TLS_GID:?the overlay sets ENGINE_TLS_GID}

if [ ! -s "$src/engine.pem" ] || [ ! -s "$src/engine-key.pem" ]; then
  echo "$name TLS is on but no engine cert in $src: run scripts/certs/generate-engine-cert.sh $name" >&2
  exit 1
fi
if ! setpriv --help 2>&1 | grep -q -- --reuid; then
  echo "$name TLS: this image's setpriv cannot drop root (BusyBox?); rebuild the image" >&2
  exit 1
fi
if [ "$(id -u)" != 0 ]; then
  echo "$name TLS: the overlay must start this as user 0 to hand the key over" >&2
  exit 1
fi

chown "$uid:$gid" "$dst"
chmod 700 "$dst"
install -m 600 -o "$uid" -g "$gid" "$src/engine-key.pem" "$dst/server.key"
install -m 644 -o "$uid" -g "$gid" "$src/engine.pem" "$dst/server.crt"
install -m 644 -o "$uid" -g "$gid" "$src/ca.pem" "$dst/ca.pem"

# Flag sets measured against each image (G5b-C6); plaintext keeps working on the usual port.
case "$name" in
mongo)
  (umask 077 && cat "$dst/server.key" "$dst/server.crt" >"$dst/server.pem")
  chown "$uid:$gid" "$dst/server.pem"
  set -- "$@" --tlsMode allowTLS --tlsCertificateKeyFile "$dst/server.pem" \
    --tlsCAFile "$dst/ca.pem" --tlsAllowConnectionsWithoutCertificates
  ;;
redis)
  # TLS on its own port; 6379 stays plaintext for the ~20 consumers that dial it.
  set -- "$@" --tls-port 6380 --tls-cert-file "$dst/server.crt" --tls-key-file "$dst/server.key" \
    --tls-ca-cert-file "$dst/ca.pem" --tls-auth-clients no
  ;;
mariadb | mysql)
  # The mysql service is MariaDB 11.4 too. Replaces the self-signed cert MariaDB serves by default; require_secure_transport stays off.
  set -- "$@" --ssl-cert="$dst/server.crt" --ssl-key="$dst/server.key" --ssl-ca="$dst/ca.pem"
  ;;
*)
  echo "engine TLS: no flag set for $name" >&2
  exit 1
  ;;
esac

exec setpriv --reuid="$uid" --regid="$gid" --clear-groups "$@"
