#!/bin/sh
# File: docker/services/mariadb/docker-entrypoint.sh
#
# Minimal first-boot initializer for our self-built Alpine MariaDB image. It
# replaces the upstream mariadb image's docker-entrypoint.sh (which we do NOT
# pull). It honours the same env contract docker-compose.yml relies on:
#   MARIADB_ROOT_PASSWORD  MARIADB_DATABASE  MARIADB_USER  MARIADB_PASSWORD
# (the MYSQL_* aliases are accepted too, so the same script backs the `mysql`
# service). On an already-initialized datadir it is a no-op and just execs the
# server.
set -eu

DATADIR=/var/lib/mysql

# A bare informational invocation (e.g. `mariadbd --version`, `--help`) must not
# trigger datadir initialization — just run the binary and exit.
for _arg in "$@"; do
  case "$_arg" in
  --version | -V | --help | -? | --print-defaults) exec "$@" ;;
  esac
done

# Accept both MARIADB_* and MYSQL_* spellings (compose uses MARIADB_* for the
# mariadb service and MYSQL_* for the mysql service).
ROOT_PASSWORD="${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"
DATABASE="${MARIADB_DATABASE:-${MYSQL_DATABASE:-}}"
USER_NAME="${MARIADB_USER:-${MYSQL_USER:-}}"
USER_PASSWORD="${MARIADB_PASSWORD:-${MYSQL_PASSWORD:-}}"

# Only the very first boot (empty datadir) runs initialization.
if [ ! -d "$DATADIR/mysql" ]; then
  echo "[entrypoint] initializing fresh MariaDB datadir at $DATADIR"
  install -d -m 0755 -o mysql -g mysql "$DATADIR"
  mariadb-install-db \
    --user=mysql \
    --datadir="$DATADIR" \
    --auth-root-authentication-method=normal \
    --skip-test-db \
    --rpm >/dev/null

  # Build the bootstrap SQL (root password, optional db + scoped user).
  BOOTSTRAP="$(mktemp)"
  {
    echo "FLUSH PRIVILEGES;"
    if [ -n "$ROOT_PASSWORD" ]; then
      # Set the password for root on both localhost and any-host so the
      # compose healthcheck (mysqladmin ping -u root -p…) works from 127.0.0.1.
      echo "ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PASSWORD}';"
      echo "CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${ROOT_PASSWORD}';"
      echo "GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION;"
    fi
    if [ -n "$DATABASE" ]; then
      echo "CREATE DATABASE IF NOT EXISTS \`${DATABASE}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    fi
    if [ -n "$USER_NAME" ]; then
      echo "CREATE USER IF NOT EXISTS '${USER_NAME}'@'%' IDENTIFIED BY '${USER_PASSWORD}';"
      if [ -n "$DATABASE" ]; then
        echo "GRANT ALL ON \`${DATABASE}\`.* TO '${USER_NAME}'@'%';"
      fi
    fi
    echo "FLUSH PRIVILEGES;"
  } >"$BOOTSTRAP"

  # Apply the bootstrap SQL offline via --bootstrap (no network, no socket).
  mariadbd --user=mysql --datadir="$DATADIR" --bootstrap --skip-networking=0 <"$BOOTSTRAP"
  rm -f "$BOOTSTRAP"
  echo "[entrypoint] initialization complete"
fi

# Hand off to the server (PID 1). Default args bind all interfaces on 3306.
if [ "$#" -eq 0 ]; then
  set -- mariadbd
fi
case "$1" in
mariadbd | mysqld) exec "$@" --user=mysql --datadir="$DATADIR" --skip-networking=0 --bind-address=0.0.0.0 ;;
*) exec "$@" ;;
esac
