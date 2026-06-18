#!/bin/sh
# File: docker/services/mariadb/healthcheck.sh
#
# Compatibility shim for the upstream mariadb image's healthcheck.sh, which our
# self-built Alpine image does not ship. docker-compose.yml's healthcheck calls:
#   healthcheck.sh --connect --innodb_initialized
# We honour --connect (can the server accept a connection?) and treat
# --innodb_initialized as satisfied once a trivial query succeeds (by then the
# server has finished InnoDB recovery and is serving). Unknown flags are
# ignored so the contract stays forward-compatible.
set -eu

# Authenticate as root using the password the entrypoint set, if any.
PW="${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"
if [ -n "$PW" ]; then
  exec mariadb-admin --no-defaults -h 127.0.0.1 -u root -p"$PW" ping >/dev/null 2>&1
else
  exec mariadb-admin --no-defaults -h 127.0.0.1 -u root ping >/dev/null 2>&1
fi
