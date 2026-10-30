#!/bin/sh
# redis-acl.sh — the one ACL user of the G5 Redis ACL overlay, stage 1
# (docs/adr/0028-g5-redis-acl-stage1.md; orchestrators/compose/docker-compose.redis-acl.yml).
#
#   serve CMD...    exec CMD... --user app on #<sha256> ~* &* +@all. The password stays in
#                   the compose secret file; redis-server's argv carries only its sha256.
#   health [FILE]   PING then ACL WHOAMI as app with the password in FILE (default: the
#                   secret). Healthy only when the reply is exactly "PONG" then "app".
#
# Stage 1 leaves the default user on and nopass (RA2): a client with no password keeps
# working. Turning default off is stage 2 and needs its own ruling (RA6).
#
# Caveat: redis-cli exits 0 on NOAUTH, and with a wrong password it prints WRONGPASS and
# carries on as default. So health compares the whole reply rather than the exit code or a
# grep for PONG: a fallback to default answers "default" to ACL WHOAMI and fails. A consumer
# library that fell back the same way would still be served until stage 2.
set -eu

user=app
secret=/run/secrets/redis_acl_password

# The secret holds the bare password; a trailing newline (a hand-made file) is not part of it.
password() { tr -d '\n' <"$1"; }

serve() {
  if [ ! -s "$secret" ]; then
    echo "redis ACL: no password in $secret — set REDIS_PASSWORD (make env) before REDIS_ACL=1" >&2
    exit 1
  fi
  hash=$(password "$secret" | sha256sum | cut -d' ' -f1)
  exec "$@" --user "$user" on "#$hash" '~*' '&*' '+@all'
}

# The password is read before the pipe, so FILE may be /dev/stdin (stack-health-requests.sh).
health() {
  auth=$(password "${1:-$secret}")
  reply=$(printf 'PING\nACL WHOAMI\n' |
    REDISCLI_AUTH=$auth redis-cli --no-auth-warning --user "$user" 2>&1) || return 1
  [ "$reply" = "$(printf 'PONG\n%s' "$user")" ]
}

case "${1:-}" in
serve)
  shift
  [ "$#" -gt 0 ] || {
    echo "usage: redis-acl.sh serve redis-server [ARGS...]" >&2
    exit 2
  }
  serve "$@"
  ;;
health)
  shift
  health "$@"
  ;;
*)
  echo "usage: redis-acl.sh serve CMD... | health [PASSWORD_FILE]" >&2
  exit 2
  ;;
esac
