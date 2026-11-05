#!/usr/bin/env bash
# deploy-all.sh — what `make all` does: every service on this machine, from a fresh clone, with
# the team's data when vault42 credentials are here. The one command the project is judged on.
#
# ORDER
#   0. .env and the TLS certificate, which a fresh clone has neither of.
#   1. Images: pulled, because 50 of them built from source take far longer than a deployment
#      should, and built only when the registry cannot answer. BUILD=1 builds on purpose.
#   2. The stack.
#   3. The settle pass. Several services resolve a dependency once, at startup, and keep the
#      failure: on a cold start mongo-init lost its race with mongo and left ai-service,
#      analytics-service and mongo-api restart-looping, and realtime sat at 503 with healthy
#      dependencies. The one-shot again, then a restart of whatever is unhealthy.
#   4. The seeds (scripts/ops/set-seeds.sh). No credentials is an empty platform, not a failure,
#      so a machine with no vault access still deploys. A platform holding data is left alone.
#   5. `make health`, whose exit status is this one's: `make all` cannot print success over a
#      stack that does not work.
#
# Caveat: the pulled images are main's, so a checkout of an older or unmerged commit runs newer
# or older images than its tree. `make all BUILD=1` is the exact answer, and takes much longer.
#
#   bash scripts/ops/deploy-all.sh PACKAGE=max "ADDONS=observability engines"
set -u

cd "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)" || exit 1
SHAPE=("$@")

say() { printf '\n\033[1;36m▸\033[0m \033[1m%s\033[0m\n' "$*"; }
die() {
  printf '\033[31m✗\033[0m %s\n' "$*" >&2
  exit 1
}
mk() { make --no-print-directory "$@" "${SHAPE[@]}"; }

# Before images: compose interpolates every service to pull one, and refuses without .env.
say "configuration"
[ -f .env ] || make --no-print-directory env || die "make env failed"
[ -f certs/localhost.pem ] || make --no-print-directory certs || die "make certs failed"

say "images"
if [ "${BUILD:-0}" = 1 ]; then
  mk build || die "the build failed"
elif ! mk pull; then
  printf 'the registry did not answer: building from this tree instead\n'
  mk build || die "neither pull nor build produced the images"
fi

say "the stack"
mk up || die "make up failed"

say "settling"
if docker ps -a --format '{{.Names}}' | grep -qx mini-baas-mongo-init &&
  [ "$(docker inspect -f '{{.State.ExitCode}}' mini-baas-mongo-init 2>/dev/null)" != 0 ]; then
  docker start -a mini-baas-mongo-init >/dev/null 2>&1 || true
fi
for _ in 1 2 3 4 5 6; do
  starting=$(docker ps --filter name=mini-baas --filter health=starting --format '{{.Names}}')
  [ -z "$starting" ] && break
  sleep 15
done
for _ in 1 2 3; do
  sick=$(docker ps --filter name=mini-baas --filter health=unhealthy --format '{{.Names}}')
  [ -n "$sick" ] || break
  printf 'restarting: %s\n' "$(printf '%s' "$sick" | tr '\n' ' ')"
  # shellcheck disable=SC2086 # one name per line, none holds a space
  docker restart $sick >/dev/null 2>&1 || true
  sleep 45
done

say "data"
bash scripts/ops/set-seeds.sh --auto "${SHAPE[@]}" || die "the seeds did not load (the lines above)"

say "the verdict"
mk health HEALTH_WAIT="${HEALTH_WAIT:-180}" || die "the stack is not healthy: make logs, make ps"

printf '\n\033[32m✓\033[0m everything is up on this machine\n'
printf '    https://localhost:%s   the WAF, the front door\n' "$(docker port mini-baas-waf 443/tcp 2>/dev/null | head -n1 | sed 's/.*://')"
printf '    http://localhost:8000    the gateway\n'
printf '    make health · make ps · make logs SERVICE=<name>\n'
