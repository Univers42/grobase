#!/usr/bin/env bash
# hub-mirror.sh — copy the images CI published to GHCR for one main commit onto
# their Docker Hub names, by digest: every platform, nothing rebuilt.
#
# dlesieur/mini-baas-* on Docker Hub are the names people pull, but grobase
# publishes to GHCR only. Hub was last fed by the groot monorepo's
# baas-release.yml (baas-v1.3.0, 2026-06-14), so by 2026-10-07 every Hub copy
# was four months behind main. .github/workflows/hub-mirror.yml runs this after
# CI succeeds on main. The source is grobase-<svc>:sha-<commit>, the tag CI's
# publish jobs add for each main commit, so Hub gets what CI built for it.
#
# Ponytail: the map below is the whole contract. A service CI starts publishing
# is not mirrored until it is added here; a service CI stops publishing fails
# the run (its sha- tag is missing), which is the signal to drop it.
#
# Usage: hub-mirror.sh <full commit sha>      (after `docker login docker.io`)
# Env:   HUB_NAMESPACE  Docker Hub namespace (default: dlesieur)
# Exit:  0 when every image was copied; 1 naming each one that was not; 2 on misuse.
set -uo pipefail

# grobase-<service> on GHCR : repository on Docker Hub.
MAP=(
  ai-service:mini-baas-ai-service
  analytics-service:mini-baas-analytics-service
  email-service:mini-baas-email-service
  gdpr-service:mini-baas-gdpr-service
  log-service:mini-baas-log-service
  mongo-api:mini-baas-mongo-api
  newsletter-service:mini-baas-newsletter-service
  outbox-relay:mini-baas-outbox-relay
  permission-engine:mini-baas-permission-engine
  postgres:mini-baas-postgres
  query-router:mini-baas-query-router
  schema-service:mini-baas-schema-service
  session-service:mini-baas-session-service
  storage-router:mini-baas-storage-router
  vault:mini-baas-vault
  waf:mini-baas-waf
  gotrue:mini-baas-infra-gotrue
  kong:mini-baas-infra-kong
  mongo:mini-baas-infra-mongo
  postgres:mini-baas-infra-postgres
  postgrest:mini-baas-infra-postgrest
  realtime:mini-baas-infra-realtime
  redis:mini-baas-infra-redis
)

# main copies every MAP entry for commit $1 and reports each one.
main() {
  local sha="${1:-}" hub="${HUB_NAMESPACE:-dlesieur}" pair src dst out failed=""
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || {
    echo "usage: hub-mirror.sh <full 40-character commit sha>" >&2
    return 2
  }
  for pair in "${MAP[@]}"; do
    src="ghcr.io/univers42/grobase-${pair%%:*}:sha-$sha"
    dst="docker.io/$hub/${pair#*:}"
    if out=$(docker buildx imagetools create --tag "$dst:latest" --tag "$dst:sha-$sha" "$src" 2>&1); then
      echo "ok   $src -> $dst"
    else
      echo "FAIL $src -> $dst"
      printf '%s\n' "$out" | tail -n 3 | sed 's/^/     /'
      failed="$failed ${pair#*:}"
    fi
  done
  if [ -n "$failed" ]; then
    echo "hub-mirror: not copied:$failed" >&2
    return 1
  fi
}

main "$@"
