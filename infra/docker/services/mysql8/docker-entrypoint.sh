#!/bin/sh
# File: docker/services/mysql8/docker-entrypoint.sh
#
# First-boot initializer for the self-built Oracle MySQL 8.4 service, with the env contract of
# ../mysql/docker-entrypoint.sh: MYSQL_ROOT_PASSWORD MYSQL_DATABASE MYSQL_USER MYSQL_PASSWORD.
# `mysqld --initialize-insecure --init-file` runs the bootstrap SQL inside initialization, so no
# temporary server is needed. The SQL file is 0600 and gone before the real server starts, and
# no password reaches argv. Users get caching_sha2_password, the 8.4 default.
#
# INIT_DONE is written only after initialization succeeds. A boot that died mid-init leaves
# files without it, and --initialize refuses a non-empty datadir: the container stays down
# instead of serving a root with no password.
set -eu

DATADIR=/var/lib/mysql
INIT_DONE="$DATADIR/.grobase-initialized"

for _arg in "$@"; do
  case "$_arg" in
  --version | -V | --help | -? | --print-defaults) exec "$@" ;;
  esac
done

# SQL literals for values from the environment: quote and backslash doubled. The lines are
# written with printf, never echo: dash's echo turns the doubled backslash back into one.
# A trailing newline in a value is dropped by the command substitution.
sql_str() { printf "'%s'" "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/''/g")"; }
sql_ident() { printf '`%s`' "$(printf '%s' "$1" | sed 's/`/``/g')"; }

ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
DATABASE="${MYSQL_DATABASE:-}"
USER_NAME="${MYSQL_USER:-}"
USER_PASSWORD="${MYSQL_PASSWORD:-}"

if [ ! -f "$INIT_DONE" ]; then
  echo "[entrypoint] initializing fresh datadir at $DATADIR"
  init="$(mktemp)"
  trap 'rm -f "$init"' EXIT
  {
    if [ -n "$ROOT_PASSWORD" ]; then
      printf '%s\n' "ALTER USER 'root'@'localhost' IDENTIFIED BY $(sql_str "$ROOT_PASSWORD");"
      printf '%s\n' "CREATE USER 'root'@'%' IDENTIFIED BY $(sql_str "$ROOT_PASSWORD");"
      printf '%s\n' "GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION;"
    fi
    if [ -n "$DATABASE" ]; then
      printf '%s\n' "CREATE DATABASE $(sql_ident "$DATABASE") CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;"
    fi
    if [ -n "$USER_NAME" ]; then
      printf '%s\n' "CREATE USER $(sql_str "$USER_NAME")@'%' IDENTIFIED BY $(sql_str "$USER_PASSWORD");"
      if [ -n "$DATABASE" ]; then
        printf '%s\n' "GRANT ALL ON $(sql_ident "$DATABASE").* TO $(sql_str "$USER_NAME")@'%';"
      fi
    fi
  } >"$init"
  mysqld --initialize-insecure --datadir="$DATADIR" --init-file="$init"
  rm -f "$init"
  trap - EXIT
  : >"$INIT_DONE"
  echo "[entrypoint] initialization complete"
fi

if [ "$#" -eq 0 ]; then
  set -- mysqld
fi
case "$1" in
mysqld) exec "$@" --datadir="$DATADIR" --bind-address=0.0.0.0 --port=3306 ;;
*) exec "$@" ;;
esac
