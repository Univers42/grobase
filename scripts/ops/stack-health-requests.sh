#!/bin/sh
# stack-health-requests.sh — legs 4 and 5 of `make health`: do the engines and the gateway
# answer real requests? (legs 1-3, the container and network checks, are stack-health.sh)
#
#   4. engines  each running database engine executes an authenticated query with the
#               credentials found in the env file — the check that catches an env file
#               re-minted or pulled over volumes initialised with other passwords
#   5. gateway  every plain route prefix in kong.yml is requested through Kong with the
#               anon key and must not come back as a gateway error (no answer, 502, 503,
#               504); /auth/v1/health and /rest/v1/ must answer 200
#
# Ponytail: leg 4 covers postgres, mongo, mysql, mariadb, mssql and redis. MinIO,
# CockroachDB, DynamoDB-local and Trino are NOT logged in to here; their container
# healthcheck (leg 1) and TCP edges (leg 2) are all that vouches for them.
#
# Ponytail: in leg 5 a 401/403 is produced by a Kong plugin BEFORE the upstream is called,
# so it proves the gateway is alive but says nothing about that upstream — such routes are
# counted separately as "refused at the gateway", never as verified. Regex routes (`~/…`)
# are skipped: there is no literal path to request. A route whose upstream host has no
# running container is reported as outside the running shape — so a service that SHOULD be
# up but was never created reads as "not in the shape" here, not as an error.
#
# Usage:
#   sh scripts/ops/stack-health-requests.sh           # both legs
#   sh scripts/ops/stack-health-requests.sh engines   # leg 4 only
#   sh scripts/ops/stack-health-requests.sh gateway   # leg 5 only
#   sh scripts/ops/stack-health-requests.sh routes    # print "path upstream-host" from kong.yml (gate use)
#   sh scripts/ops/stack-health-requests.sh --help
# Exit: 0 every leg passed · 1 at least one leg failed.
set -eu

PROJECT="${COMPOSE_PROJECT_NAME:-mini-baas}"
ENV_FILE="${ENV_FILE:-.env}"
KONG_YML="${KONG_YML:-infra/docker/services/kong/conf/kong.yml}"
ENGINES="postgres mongo mysql mariadb mssql redis"
TIMEOUT="${HEALTH_REQUEST_TIMEOUT:-5}"

# getenv prints the value of KEY from the env file. Values are used, never printed.
getenv() {
  sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null | head -n 1
}

# engine_login runs one authenticated query inside engine $1's container, the password
# travelling in the exec environment so it never appears in a process list.
engine_login() {
  case "$1" in
  postgres)
    docker exec -e PGPASSWORD="$(getenv POSTGRES_PASSWORD)" -e U="$(getenv POSTGRES_USER)" "$PROJECT-postgres" \
      sh -c 'psql -h 127.0.0.1 -U "${U:-postgres}" -d postgres -tAc "select 1"'
    ;;
  mongo)
    docker exec -e P="$(getenv MONGO_INITDB_ROOT_PASSWORD)" -e U="$(getenv MONGO_INITDB_ROOT_USERNAME)" "$PROJECT-mongo" \
      mongosh --quiet admin --eval 'db.auth(process.env.U, process.env.P)'
    ;;
  mysql) docker exec -e MYSQL_PWD="$(getenv MYSQL_ROOT_PASSWORD)" "$PROJECT-mysql" mysql -uroot -N -e 'select 1' ;;
  mariadb)
    docker exec -e MYSQL_PWD="$(getenv MARIADB_ROOT_PASSWORD)" "$PROJECT-mariadb" \
      sh -c 'c=mariadb; command -v "$c" >/dev/null || c=mysql; "$c" -uroot -N -e "select 1"'
    ;;
  mssql)
    docker exec -e SQLCMDPASSWORD="$(getenv MSSQL_SA_PASSWORD)" "$PROJECT-mssql" \
      sh -c '"$(ls /opt/mssql-tools*/bin/sqlcmd | tail -n 1)" -C -S localhost -U sa -b -Q "select 1"'
    ;;
  redis) docker exec -e REDISCLI_AUTH="$(getenv REDIS_PASSWORD)" "$PROJECT-redis" redis-cli ping | grep -q PONG ;;
  esac
}

# check_engines logs in to every running engine and fails when one refuses the env file's
# credentials. An engine that is not part of the running shape is stated, not failed.
check_engines() {
  running="$(docker ps --format '{{.Names}}')"
  failed=0
  for engine in $ENGINES; do
    if ! printf '%s\n' "$running" | grep -qx "$PROJECT-$engine"; then
      printf '  • %s — not running, not checked\n' "$engine"
    elif engine_login "$engine" >/dev/null 2>&1; then
      printf '  ✓ %s accepts the credentials in %s\n' "$engine" "$ENV_FILE"
    else
      failed=1
      printf '  ✗ %s REJECTS the credentials in %s (make reconcile-credentials)\n' "$engine" "$ENV_FILE"
    fi
  done
  return "$failed"
}

# route_table prints "path upstream-host" for every literal route path declared inline in
# kong.yml, the host being that of the enclosing service's url.
route_table() {
  awk '
    /(^| )url: / { host = $0; sub(/.*url: */, "", host); sub(/^[a-z]+:\/\//, "", host); sub(/[:\/ ].*/, "", host) }
    /(^| )paths: *\[/ && match($0, /\[.*\]/) {
      count = split(substr($0, RSTART + 1, RLENGTH - 2), path, ",")
      for (i = 1; i <= count; i++) { gsub(/[ "]/, "", path[i]); if (path[i] ~ /^\//) print path[i], host }
    }' "$KONG_YML" | sort -u
}

# live_hosts prints every name a running container of the project answers to: its
# container name without the project prefix, and its compose service name.
live_hosts() {
  docker ps --filter "label=com.docker.compose.project=$PROJECT" \
    --format '{{.Names}} {{.Label "com.docker.compose.service"}}' | sed "s/^$PROJECT-//" | tr ' ' '\n'
}

# check_routes requests, in parallel, every route whose upstream is running and fails on a
# gateway error. A route to a service outside the running shape is stated, not failed.
check_routes() {
  hosts="$(live_hosts)"
  route_table | awk -v hosts="$hosts" 'BEGIN { split(hosts, list, "\n"); for (i in list) live[list[i]] = 1 }
    { print (($2 in live) ? "GO " : "OFF ") $1 }' >"$TMP/routes"
  {
    sed -n 's/^OFF //p' "$TMP/routes" | sed 's/^/off /'
    sed -n 's/^GO //p' "$TMP/routes" |
      xargs -P 8 -I '{}' curl -s -o /dev/null -m "$TIMEOUT" -w '%{http_code} {}\n' -H "apikey: $2" "http://localhost:$1{}" || true
  } | sort -k2 | awk '
    $1 == "off" { off++; next }
    $1 == "000" || $1 == "502" || $1 == "503" || $1 == "504" { bad++; printf "  ✗ %s — HTTP %s, the gateway cannot reach the upstream\n", $2, $1; next }
    $1 == "401" || $1 == "403" { refused++; next }
    { answered++ }
    END { printf "  → %d routes: %d answered by the upstream · %d refused at the gateway (upstream not exercised) · %d upstream not in the running shape · %d gateway errors\n", NR, answered, refused, off, bad
          exit (bad > 0 || answered + refused == 0) }'
}

# gateway_code prints the HTTP status Kong returns for GET $2 on port $1 with anon key $3.
gateway_code() {
  curl -s -o /dev/null -m "$TIMEOUT" -w '%{http_code}' -H "apikey: $3" "http://localhost:$1$2" || true
}

# check_gateway runs the route sweep, then requires 200 from the two anon-readable endpoints.
check_gateway() {
  port="$(docker port "$PROJECT-kong" 8000/tcp 2>/dev/null | sed -n '1s/.*://p')"
  key="$(getenv ANON_KEY)"
  failed=0
  check_routes "${port:-8000}" "$key" || failed=1
  for path in /auth/v1/health /rest/v1/; do
    code="$(gateway_code "${port:-8000}" "$path" "$key")"
    if [ "$code" = 200 ]; then
      printf '  ✓ %s → 200\n' "$path"
    else
      failed=1
      printf '  ✗ %s — HTTP %s%s\n' "$path" "$code" "$([ "$code" = 401 ] && printf ' (the ANON_KEY in %s is not the one the stack runs with)' "$ENV_FILE")"
    fi
  done
  return "$failed"
}

main() {
  failed=0
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  case "${1:-all}" in
  routes)
    route_table
    return 0
    ;;
  -h | --help)
    sed -n '2,/^# Exit:/s/^# \{0,1\}//p' "$0"
    return 0
    ;;
  esac
  if [ "${1:-all}" != gateway ]; then
    printf 'Engines — an authenticated query with the credentials in %s\n' "$ENV_FILE"
    check_engines || failed=1
  fi
  if [ "${1:-all}" != engines ]; then
    printf 'Gateway — HTTP through Kong\n'
    check_gateway || failed=1
  fi
  return "$failed"
}

main "$@"
