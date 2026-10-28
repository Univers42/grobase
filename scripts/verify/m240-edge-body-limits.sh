#!/usr/bin/env bash
# **************************************************************************** #
#  m240-edge-body-limits.sh — Kong never refuses a body the WAF lifted         #
#  The WAF lifts its 128 KB body limit on a few exact paths (hydrawn boards    #
#  2 MiB). Kong sat behind it at client_max_body_size 1m and answered 413 to   #
#  every whiteboard save between 1 and 2 MiB (2026-10-28, staged on b2b).      #
#  This gate holds Kong's limit, in every compose file that sets it, at or     #
#  above each WAF lift; MUTANT proves it refuses one byte below the largest.   #
#  Static, no stack.                                                           #
#  Caveat: reads literal `SecRequestBodyNoFilesLimit <bytes>` lines in the     #
#  WAF nginx.conf and literal KONG_NGINX_HTTP_CLIENT_MAX_BODY_SIZE values; a   #
#  lift set another way (a ctl: action in a rule, an env-substituted value)    #
#  is not seen, so the gate under-reports. Per-route request-size-limiting     #
#  plugins are deliberately smaller and not compared.                          #
# **************************************************************************** #
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WAF_CONF="${ROOT}/infra/docker/services/waf/conf/nginx.conf"
COMPOSE=("${ROOT}/orchestrators/compose/base/gateway.yml" "${ROOT}/orchestrators/compose/docker-compose.monolith.yml")
ok() { printf '\033[0;32m[M240] PASS: %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M240] FAIL: %s\033[0m\n' "$*" >&2
  exit 1
}

# nginx size syntax (1048576, 512k, 10m, 1g) to bytes.
to_bytes() {
  local v="${1,,}"
  case "$v" in
    *k) echo $((${v%k} * 1024)) ;;
    *m) echo $((${v%m} * 1024 * 1024)) ;;
    *g) echo $((${v%g} * 1024 * 1024 * 1024)) ;;
    *) echo "$v" ;;
  esac
}

# covers_lifts KONG_SIZE: exit 0 when Kong's limit is at or above every WAF lift.
covers_lifts() {
  local kong lift
  kong="$(to_bytes "$1")"
  for lift in "${LIFTS[@]}"; do
    [ "$kong" -ge "$lift" ] || return 1
  done
}

mapfile -t LIFTS < <(sed -n 's/.*SecRequestBodyNoFilesLimit \([0-9][0-9]*\).*/\1/p' "$WAF_CONF")
[ "${#LIFTS[@]}" -gt 0 ] || fail "no SecRequestBodyNoFilesLimit lift found in ${WAF_CONF} — the parse broke"
MAX_LIFT="$(printf '%s\n' "${LIFTS[@]}" | sort -n | tail -1)"

for f in "${COMPOSE[@]}"; do
  size="$(sed -n 's/.*KONG_NGINX_HTTP_CLIENT_MAX_BODY_SIZE: "\([0-9]*[kKmMgG]\{0,1\}\)".*/\1/p' "$f")"
  [ -n "$size" ] || fail "${f#"${ROOT}"/}: no KONG_NGINX_HTTP_CLIENT_MAX_BODY_SIZE — Kong falls back to nginx's 1m"
  covers_lifts "$size" || fail "${f#"${ROOT}"/}: Kong client_max_body_size ${size} is below the WAF's ${MAX_LIFT}-byte lift — Kong 413s bodies the WAF let through"
  ok "${f#"${ROOT}"/}: Kong ${size} >= largest WAF lift ${MAX_LIFT} bytes (${#LIFTS[@]} lifts)"
done

covers_lifts "$((MAX_LIFT - 1))" && fail "MUTANT: Kong one byte below the ${MAX_LIFT}-byte lift passed — the check is asleep"
ok "MUTANT: Kong one byte below the largest lift is refused"
