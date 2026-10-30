#!/bin/sh
# Postgres entrypoint under ENGINE_TLS=1 (orchestrators/compose/docker-compose.engine-tls.yml,
# docs/adr/0011-g5a-postgres-accept-tls.md): adds accept-mode TLS — ssl=on, plaintext
# still allowed — then hands over to the image's own docker-entrypoint.sh unchanged.
#
# Mounted from the repo, not baked into the image, so a pulled :latest behaves the same.
# The key is copied into a tmpfs owned by postgres: Postgres refuses a key it does not
# own at 0600, the bind mount keeps the host owner, and PGDATA would carry the key into
# every backup (G5a-C3). Asked for TLS with no cert, it refuses to start rather than
# fall back to plaintext.
set -eu

src=/etc/engine-tls
dst=/run/engine-tls

if [ ! -s "$src/engine.pem" ] || [ ! -s "$src/engine-key.pem" ]; then
  echo "ENGINE_TLS=1 but no engine cert in $src: run scripts/certs/generate-engine-cert.sh" >&2
  exit 1
fi

chown postgres:postgres "$dst"
chmod 700 "$dst"
install -m 600 -o postgres -g postgres "$src/engine-key.pem" "$dst/server.key"
install -m 644 -o postgres -g postgres "$src/engine.pem" "$dst/server.crt"

exec docker-entrypoint.sh "$@" -c ssl=on \
  -c ssl_cert_file="$dst/server.crt" -c ssl_key_file="$dst/server.key"
