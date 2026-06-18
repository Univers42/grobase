#!/usr/bin/env bash
# File: docker/services/mongo/docker-entrypoint.sh
#
# Compact equivalent of the official mongo image docker-entrypoint.sh.
# Responsibilities:
#   1. exec mongod with the args compose appends
#      (--replSet rs0 --bind_ip_all --keyFile /etc/mongo/rs-keyfile).
#   2. On a FRESH data dir, when MONGO_INITDB_ROOT_USERNAME is set, create the
#      root user before the real server comes up — using a temporary localhost-
#      only mongod with auth/keyfile DISABLED (the localhost exception lets us
#      create the first user; the official image does the same dance).
# Subsequent boots (data dir already initialised) skip straight to exec.
set -Eeuo pipefail

# Normalise args like the official image:
#   * first arg starts with '-'  -> it's mongod flags; prepend `mongod`
#     (this is the compose case: command=["--replSet","--bind_ip_all",...]).
#   * first arg is `mongod`      -> server invocation (our default CMD).
#   * anything else (mongosh / bash / `mongod --version`) -> run as-is.
if [ "${1:-}" != "${1#-}" ] && [ -n "${1:-}" ]; then
  set -- mongod "$@"
fi

# If this is not a server boot, just run it.
if [ "${1:-}" != "mongod" ]; then
  exec "$@"
fi

DB_PATH="/data/db"
# Resolve --dbpath if the caller overrode it.
_args=("$@")
for ((i = 0; i < ${#_args[@]}; i++)); do
  case "${_args[$i]}" in
  --dbpath) DB_PATH="${_args[$((i + 1))]:-$DB_PATH}" ;;
  --dbpath=*) DB_PATH="${_args[$i]#--dbpath=}" ;;
  esac
done

_already_initialised() {
  # A populated data dir has WiredTiger metadata.
  [ -f "${DB_PATH}/WiredTiger" ]
}

_should_init() {
  [ -n "${MONGO_INITDB_ROOT_USERNAME:-}" ] && [ -n "${MONGO_INITDB_ROOT_PASSWORD:-}" ] && ! _already_initialised
}

if _should_init; then
  echo "[entrypoint] fresh data dir — bootstrapping root user '${MONGO_INITDB_ROOT_USERNAME}'"

  # The init server's only job is to create the first user via the localhost
  # exception, so run a TEMPORARY mongod with a FIXED minimal arg set
  # (dbpath only, bound to loopback) — we deliberately drop the caller's
  # --replSet/--keyFile/--bind_ip_all flags. It is fully torn down before the
  # real server starts, so reusing 127.0.0.1:27017 is safe. Run it backgrounded
  # by the shell (not --fork) so a startup failure surfaces immediately.
  INIT_LOG="$(mktemp)"
  mongod --dbpath "$DB_PATH" --bind_ip 127.0.0.1 --port 27017 --noauth \
    --logpath "$INIT_LOG" --logappend &
  INIT_PID=$!

  # Wait for the temp server to accept a ping on loopback.
  ready=0
  for _ in $(seq 1 30); do
    if ! kill -0 "$INIT_PID" 2>/dev/null; then break; fi # died early
    if mongosh --quiet --host 127.0.0.1 --port 27017 \
      --eval 'db.runCommand({ ping: 1 }).ok' >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  if [ "$ready" != "1" ]; then
    echo "[entrypoint] FATAL: temp init mongod failed to start; log follows:" >&2
    cat "$INIT_LOG" >&2 || true
    kill "$INIT_PID" 2>/dev/null || true
    exit 1
  fi

  # Create the root user. Credentials go via env (read inside JS) so quoting /
  # special chars are safe.
  MONGO_INITDB_ROOT_USERNAME="$MONGO_INITDB_ROOT_USERNAME" \
    MONGO_INITDB_ROOT_PASSWORD="$MONGO_INITDB_ROOT_PASSWORD" \
    mongosh --quiet --host 127.0.0.1 --port 27017 admin --eval '
        db.getSiblingDB("admin").createUser({
            user: process.env.MONGO_INITDB_ROOT_USERNAME,
            pwd: process.env.MONGO_INITDB_ROOT_PASSWORD,
            roles: [ { role: "root", db: "admin" } ]
        });
        print("[entrypoint] root user created");
    '

  # Stop the temp server and wait for it to exit fully (releases the dbpath
  # lock before the real server starts).
  mongosh --quiet --host 127.0.0.1 --port 27017 admin \
    --eval 'db.shutdownServer()' >/dev/null 2>&1 || true
  wait "$INIT_PID" 2>/dev/null || true
  rm -f "$INIT_LOG"
  echo "[entrypoint] init complete — starting server with auth"
fi

exec "$@"
