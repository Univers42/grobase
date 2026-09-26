# shellcheck shell=sh
# lib-netseg.sh — sourced helper for sidecar `docker run --network` calls that
# must reach an engine. Under the netseg overlay (make up NETSEG=1, make prod-up)
# the engines sit on net-data, not the app bridge, so a sidecar on
# mini-baas_mini-baas cannot reach them. Sets no shell options.

# engine_net prints the first network container $1 is attached to, or $2 when
# the container does not exist (not running in this edition).
# Ponytail: "first" is right for the engines, which the overlay puts on exactly
# one bridge; for a multi-homed container it is whichever docker lists first.
engine_net() {
  _en="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$1" 2>/dev/null | awk '{ print $1 }')"
  printf '%s\n' "${_en:-$2}"
}
