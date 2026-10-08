#!/bin/sh
# public-origins.sh ADDRESSES [URLS] [SUFFIX] — the browser origins under which this
# grobase is reached, derived from GROBASE_PUBLIC_ADDRESSES. One origin per line.
#
#   ADDRESSES  comma list of hostnames / IPv4 / IPv6 — no scheme, no port, no path
#              (a LAN IP, a VM bridge IP, a router's public IP, a ts.net name, …).
#   URLS       comma list of origins or URLs; every one whose host is localhost or
#              127.0.0.1 is re-emitted once per address, port and path kept, so the
#              dev list (http://localhost:5173, …) follows each address. Prod passes
#              an empty dev list, so it gets only the https:// base origins.
#   SUFFIX     appended to each https://<address> base origin (GoTrue passes /**).
#
# Exit 2, printing nothing, on an address with a character outside [A-Za-z0-9.:-]:
# a `*` or `/` would become a credentialed wildcard or a forged origin.
# Builtins only — it runs in GoTrue's scratch image (busybox sh, no sed/awk links).
# Consumers: kong/render-kong-config.sh (CORS), gotrue's command (URI_ALLOW_LIST),
# scripts/certs/generate-localhost-cert.sh (validation only).
#
# Ponytail: an IPv6 URL entry ([::1]:5173) is not rewritten, only localhost and
# 127.0.0.1 — list IPv6 dev origins explicitly. Any address containing `:` is taken
# as IPv6 and bracketed, so `host:port` is refused by design, not parsed.
set -eu

# fail prints the reason on stderr and exits 2.
fail() {
  printf 'public-origins: %s\n' "$1" >&2
  exit 2
}

# check_address refuses an empty or non-host address.
check_address() {
  case "$1" in
  '' | *[!A-Za-z0-9.:-]*) fail "invalid address '$1' (hostname or IP only, no scheme/port/path)" ;;
  esac
}

# emit prints origin $1 once: localhost and 127.0.0.1 entries rewrite to the same
# origin, so `seen` (space-delimited) drops the repeat.
emit() {
  case "$seen" in *" $1 "*) return 0 ;; esac
  seen="$seen $1 "
  printf '%s\n' "$1"
}

# rewrite_local emits URL $1 with its host replaced by $2, when that host is
# localhost or 127.0.0.1; emits nothing otherwise.
rewrite_local() {
  case "$1" in *://*) ;; *) return 0 ;; esac
  scheme=${1%%://*}
  rest=${1#*://}
  hostport=${rest%%/*}
  path=${rest#"$hostport"}
  name=${hostport%%:*}
  port=${hostport#"$name"}
  case "$name" in
  localhost | 127.0.0.1) emit "$scheme://$2$port$path" ;;
  esac
}

# main validates every address first, then prints the base origin and the
# rewritten URLs for each.
main() {
  set -f
  seen=' '
  IFS=', '
  for a in $1; do check_address "$a"; done
  for a in $1; do
    case "$a" in *:*) host="[$a]" ;; *) host=$a ;; esac
    emit "https://$host${3:-}"
    for u in ${2:-}; do rewrite_local "$u" "$host"; done
  done
}

[ "$#" -ge 1 ] || fail 'usage: public-origins.sh ADDRESSES [URLS] [SUFFIX]'
main "$@"
