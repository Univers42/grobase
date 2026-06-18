#!/bin/sh
# File: docker/services/mysql/docker-entrypoint.sh
#
# First-boot initializer for our self-built Alpine "mysql" service. Alpine has
# no MySQL 8 package; the Alpine-native MySQL-compatible server is MariaDB
# (mariadbd ships the mysqld/mysqld_safe symlinks and speaks the MySQL wire
# protocol). This replaces the upstream mysql image entrypoint and honours the
# same env contract docker-compose.yml relies on:
#   MYSQL_ROOT_PASSWORD  MYSQL_DATABASE  MYSQL_USER  MYSQL_PASSWORD
# On an already-initialized datadir it is a no-op and just execs the server.
#
# WIRE-PROTOCOL CAVEAT: MariaDB 11.4 is MySQL-wire-compatible (clients, JDBC,
# the Rust mysql adapter, mysqladmin ping all work) but it is NOT byte-identical
# to Oracle MySQL 8.4. It does not implement MySQL-8-only server features such
# as caching_sha2_password as the on-disk default, the CLONE plugin, or
# 8.0+ JSON_TABLE/window-function edge cases. For this stack (analytical
# federation + tenant CRUD via the query-router) that surface is unused, so
# MariaDB is the correct Alpine-native substitute. If a future feature strictly
# needs the MySQL 8 wire/plugin surface, this service must instead build Oracle
# MySQL from source (no Alpine package exists) — note left intentionally.
set -eu

DATADIR=/var/lib/mysql

# A bare informational invocation (e.g. `mysqld --version`, `--help`) must not
# trigger datadir initialization — just run the binary and exit.
for _arg in "$@"; do
  case "$_arg" in
  --version | -V | --help | -? | --print-defaults) exec "$@" ;;
  esac
done

ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
DATABASE="${MYSQL_DATABASE:-}"
USER_NAME="${MYSQL_USER:-}"
USER_PASSWORD="${MYSQL_PASSWORD:-}"

if [ ! -d "$DATADIR/mysql" ]; then
  echo "[entrypoint] initializing fresh datadir at $DATADIR"
  install -d -m 0755 -o mysql -g mysql "$DATADIR"
  mariadb-install-db \
    --user=mysql \
    --datadir="$DATADIR" \
    --auth-root-authentication-method=normal \
    --skip-test-db \
    --rpm >/dev/null

  BOOTSTRAP="$(mktemp)"
  {
    echo "FLUSH PRIVILEGES;"
    if [ -n "$ROOT_PASSWORD" ]; then
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

  mariadbd --user=mysql --datadir="$DATADIR" --bootstrap <"$BOOTSTRAP"
  rm -f "$BOOTSTRAP"
  echo "[entrypoint] initialization complete"
fi

if [ "$#" -eq 0 ]; then
  set -- mysqld
fi
case "$1" in
mysqld | mariadbd) exec "$@" --user=mysql --datadir="$DATADIR" ;;
*) exec "$@" ;;
esac
