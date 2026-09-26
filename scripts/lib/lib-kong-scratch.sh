# shellcheck shell=bash
# lib-kong-scratch.sh — sourced by gates that boot a throwaway Kong on the repo
# kong.yml, rendered by the repo's own render-kong-config.sh from dummy keys
# (m206, m207, m208). Bash only; sets no shell options, defines no variables.
# The dummy keys: anon apikey `scratch-anon`, service apikey `scratch-service`.

# kong_scratch_start runs Kong container $1 from image $2 on docker network $3
# ("none" for no network); every further argument goes to `docker run` before
# the image (extra -e, --network-alias). Returns docker's status.
kong_scratch_start() {
  local name="$1" image="$2" net="$3" root
  shift 3
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  docker run -d --name "${name}" --network "${net}" --memory 1g "$@" \
    -v "${root}/infra/docker/services/kong/conf/kong.yml:/etc/kong/kong.yml.tmpl:ro" \
    -v "${root}/infra/docker/services/kong/render-kong-config.sh:/etc/kong/render-kong-config.sh:ro" \
    -e KONG_DATABASE=off -e KONG_DECLARATIVE_CONFIG=/tmp/kong.yml -e KONG_NGINX_WORKER_PROCESSES=1 \
    -e KONG_MEM_CACHE_SIZE=64m -e KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES=cjson.safe \
    -e KONG_PUBLIC_API_KEY=scratch-anon -e KONG_SERVICE_API_KEY=scratch-service -e KONG_CORS_ORIGIN_DEV_LIST= \
    -e KONG_CORS_ORIGIN_APP=https://app.example -e KONG_CORS_ORIGIN_PLAYGROUND=https://app.example \
    -e KONG_CORS_ORIGIN_STUDIO=https://app.example -e KONG_CORS_ORIGIN_FRONTEND=https://app.example \
    -e JWT_SECRET=scratch-dummy-jwt-secret-scratch-dummy -e GOTRUE_JWT_ISS=http://localhost:8000/auth/v1 \
    -e KONG_ANON_UUID=cd4f782c-ac87-5081-b322-b54834d15651 --entrypoint sh "${image}" \
    -ec 'sh /etc/kong/render-kong-config.sh /etc/kong/kong.yml.tmpl /tmp/kong.yml
      exec /docker-entrypoint.sh kong docker-start' >/dev/null
}

# kong_scratch_wait waits up to 60 s for Kong $1's proxy :8000 to accept a
# connection; returns 1 (after printing its last log lines) if it never does.
kong_scratch_wait() {
  local _
  for _ in $(seq 1 60); do
    docker exec "$1" bash -c 'exec 3<>/dev/tcp/127.0.0.1/8000' 2>/dev/null && return 0
    sleep 1
  done
  docker logs "$1" 2>&1 | tail -n3 >&2
  return 1
}

# kong_scratch_get prints Kong $1's raw HTTP/1.0 answer to GET $3 on port $2,
# sent from inside the container (127.0.0.1; the image ships no curl), with
# each further argument as one header line ("Name: value"). Prints REFUSED
# when nothing listens.
kong_scratch_get() {
  local name="$1" port="$2" req h
  printf -v req 'GET %s HTTP/1.0\r\nHost: localhost\r\n' "$3"
  shift 3
  for h in "$@"; do printf -v req '%s%s\r\n' "${req}" "${h}"; done
  docker exec -e REQ="${req}"$'\r\n' "${name}" bash -c \
    'exec 3<>/dev/tcp/127.0.0.1/$0 && printf "%s" "$REQ" >&3 && cat <&3' "${port}" 2>/dev/null ||
    printf 'REFUSED\n'
}

# kong_scratch_status prints just the HTTP status of kong_scratch_get "$@".
kong_scratch_status() { kong_scratch_get "$@" | head -n1 | tr -d '\r' | awk '{ print ($1 == "REFUSED") ? "REFUSED" : $2 }'; }
