#!/bin/sh
# Healthcheck of the cockroach engine-TLS overlay (docs/adr/0029-g5-cockroach-secure-mode.md).
# Healthy means a password DSN can log in: the first run of each boot sets root's password from
# the compose secret, logged in with the root client cert, so `up --wait` returns only after it.
# The password reaches cockroach on stdin, never in argv or the container env (devil CR3).
# ALTER ... PASSWORD with the same value is a no-op, so a repeat after a restart is harmless.
set -eu

certs=/run/engine-tls/certs
marker=/run/engine-tls/root-password-set
sql() { cockroach sql --certs-dir="$certs" --host=127.0.0.1:26257 "$@"; }

if [ ! -e "$marker" ]; then
  pw=$(cat /run/secrets/cockroach_password)
  # Hex only: the value is spliced into SQL, so anything else is refused, never quoted.
  case "$pw" in '' | *[!0-9a-f]*) exit 1 ;; esac
  printf "ALTER USER root WITH PASSWORD '%s';\n" "$pw" | sql >/dev/null
  : >"$marker"
fi
sql -e 'SELECT 1' >/dev/null
