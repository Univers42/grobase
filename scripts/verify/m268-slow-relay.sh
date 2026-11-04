#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m268-slow-relay.sh — a real mail relay and a recreated service both work    #
#                                                                              #
#  Mailpit answers at once, so nothing here failed until a reset went through  #
#  Titan on 2026-11-04: GoTrue's 10 s limit cut the send, the token rolled     #
#  back and the mail arrived with a dead link; then Kong sent /email/v1/send   #
#  to the address of the container that had just been replaced.                #
#  Hermetic: reads the compose files, nothing is started.                      #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT" || exit 1
rc=0
ok() { printf '  ✓ %s\n' "$1"; }
fail() {
  printf '[M268] FAIL — %s\n' "$1"
  rc=1
}
check() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: got '$2', expected '$3'"; fi; }
setting() { # <compose file> <key>: the first value, quotes dropped
  sed -n "s/^[[:space:]]*$2:[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "orchestrators/compose/$1" | head -n1
}

# Kong's own default: a route with a shorter one would cut the request first.
KONG_PROXY_SECONDS=60
SESSION=$(sed -n 's/.*defaultTimeout = \([0-9]*\) \* time.Second.*/\1/p' src/control-plane/internal/smtpclient/smtpclient.go)
check "smtpclient's session limit is readable" "${SESSION:-none}" 30
check "no Kong route shortens the proxy timeout" \
  "$(grep -rlE '(read|write|connect)_timeout' infra/docker/services/kong/conf 2>/dev/null | wc -l)" 0

for f in base/auth-api.yml docker-compose.monolith.yml docker-compose.track-binocle.yml; do
  limit=$(setting "$f" GOTRUE_API_MAX_REQUEST_DURATION)
  seconds=${limit%s}
  case "$seconds" in '' | *[!0-9]*) seconds=0 ;; esac
  check "$f gives GoTrue longer than one SMTP session" "$([ "$seconds" -gt "${SESSION:-0}" ] && echo yes)" yes
  check "$f keeps GoTrue under Kong's proxy timeout" "$([ "$seconds" -lt "$KONG_PROXY_SECONDS" ] && echo yes)" yes
done

for f in base/gateway.yml docker-compose.monolith.yml; do
  check "$f bounds how long Kong keeps a name" "$(setting "$f" KONG_DNS_VALID_TTL)" 5
  check "$f never serves an expired name" "$(setting "$f" KONG_DNS_STALE_TTL)" 0
done

[ "$rc" = 0 ] && echo "[M268] ok"
exit "$rc"
