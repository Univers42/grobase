#!/bin/sh
# stack-health-requests.sh — legs 4 to 6 of `make health`: do the engines, the gateway and
# the monitoring answer real requests? (legs 1-3, containers and network: stack-health.sh)
#
#   4. engines     each running engine executes a query with the credentials found in the
#                  env file — the check that catches an env file re-minted or pulled over
#                  volumes initialised with other passwords
#   5. gateway     every literal route in kong.yml is requested through Kong, first with
#                  the anon key and, when a Kong plugin refuses that, with the service-role
#                  key; none may come back as a gateway error (no answer, 502, 503, 504),
#                  and /auth/v1/health and /rest/v1/ must answer 200
#   6. monitoring  Prometheus has no scrape target down and no alert firing
#
# Ponytail: in leg 4 cockroach (started --insecure), trino and a redis without
# REDIS_PASSWORD have no credential to get wrong: for them the query proves the engine
# executes statements, not that a password matches. DynamoDB-local accepts any credential
# and is not queried at all; its healthcheck (leg 1) and TCP edges (leg 2) vouch for it.
#
# Ponytail: leg 5 decides "refused at the gateway" from the body — a 401/403 carrying
# Kong's `"request_id"` field was produced by a plugin before the upstream was called. An
# upstream that itself emits that field would be misread as a gateway refusal (it would be
# under-counted as verified, never falsely passed). Routes are requested with GET on the
# bare prefix, so a 404 or 405 from the upstream counts as "the upstream answered". Regex
# routes (`~/…`) have no literal path and are skipped. A route whose upstream host has no
# running container is reported as outside the running shape: pass the shape to
# `make health` (PACKAGE= / EDITION=) to have leg 1 fail on a service that should exist.
#
# Ponytail: leg 6 reads Prometheus' own view, so a service Prometheus does not scrape, or
# a rule that does not exist, is silence here, not health. Without a Prometheus container
# the leg is stated as not run.
#
# Usage:
#   sh scripts/ops/stack-health-requests.sh              # legs 4-6
#   sh scripts/ops/stack-health-requests.sh engines      # leg 4 only
#   sh scripts/ops/stack-health-requests.sh gateway      # leg 5 only
#   sh scripts/ops/stack-health-requests.sh monitoring   # leg 6 only
#   sh scripts/ops/stack-health-requests.sh routes       # print "path upstream-host" from kong.yml (gate use)
#   sh scripts/ops/stack-health-requests.sh --help
# Exit: 0 every leg passed · 1 at least one leg failed.
set -eu

PROJECT="${COMPOSE_PROJECT_NAME:-mini-baas}"
ENV_FILE="${ENV_FILE:-.env}"
KONG_YML="${KONG_YML:-infra/docker/services/kong/conf/kong.yml}"
ENGINES="postgres mongo mysql mariadb mssql redis minio cockroach trino"
TIMEOUT="${HEALTH_REQUEST_TIMEOUT:-5}"
PROM="http://localhost:9090/api/v1/query?query="

# getenv prints the value of KEY from the env file. Values are used, never printed.
getenv() {
  sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null | head -n 1
}

# sql_login runs one authenticated query inside SQL engine $1's container, the password
# travelling in the exec environment so it never appears in a process list.
sql_login() {
  case "$1" in
  postgres)
    docker exec -e PGPASSWORD="$(getenv POSTGRES_PASSWORD)" -e U="$(getenv POSTGRES_USER)" "$PROJECT-postgres" \
      sh -c 'psql -h 127.0.0.1 -U "${U:-postgres}" -d postgres -tAc "select 1"'
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
  cockroach) docker exec "$PROJECT-cockroach" cockroach sql --insecure -e 'select 1' ;;
  esac
}

# engine_login runs one query inside engine $1's container with the env file's credentials;
# MinIO's travel on stdin as a curl config for a SigV4-signed ListBuckets.
engine_login() {
  case "$1" in
  mongo)
    docker exec -e P="$(getenv MONGO_INITDB_ROOT_PASSWORD)" -e U="$(getenv MONGO_INITDB_ROOT_USERNAME)" "$PROJECT-mongo" \
      mongosh --quiet admin --eval 'db.auth(process.env.U, process.env.P)'
    ;;
  redis) docker exec -e REDISCLI_AUTH="$(getenv REDIS_PASSWORD)" "$PROJECT-redis" redis-cli ping | grep -q PONG ;;
  minio)
    printf 'user = "%s:%s"\n' "$(getenv MINIO_ROOT_USER)" "$(getenv MINIO_ROOT_PASSWORD)" |
      docker exec -i "$PROJECT-minio" curl -fsS -o /dev/null -K - --aws-sigv4 'aws:amz:us-east-1:s3' http://localhost:9000/
    ;;
  trino)
    docker exec "$PROJECT-trino" curl -fsS -X POST -H 'X-Trino-User: stack-health' -d 'select 1' \
      http://localhost:8080/v1/statement | grep -q '"id"'
    ;;
  *) sql_login "$1" ;;
  esac
}

# check_engines queries every running engine in parallel and fails when one refuses. An
# engine that is not part of the running shape is stated, not failed.
check_engines() {
  running="$(docker ps --format '{{.Names}}')"
  for engine in $ENGINES; do
    if printf '%s\n' "$running" | grep -qx "$PROJECT-$engine"; then
      { engine_login "$engine" >/dev/null 2>&1 && echo ok || echo fail; } >"$TMP/engine-$engine" &
    else
      echo off >"$TMP/engine-$engine"
    fi
  done
  wait
  for engine in $ENGINES; do
    read -r verdict <"$TMP/engine-$engine"
    printf '%s %s\n' "$verdict" "$engine"
  done | awk -v env="$ENV_FILE" '
    $1 == "ok" { printf "  ✓ %s answers a query with the credentials in %s\n", $2, env; next }
    $1 == "off" { printf "  • %s — not running, not checked\n", $2; next }
    { bad++; printf "  ✗ %s REJECTS the credentials in %s (make reconcile-credentials)\n", $2, env }
    END { exit (bad > 0) }'
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

# route_verdict requests GET $2 through Kong on port $1 with the anon key, then with the
# service-role key if a Kong plugin refused, and prints "<upstream|refused|error> code path".
route_verdict() {
  verdict=error
  for name in ANON_KEY SERVICE_ROLE_KEY; do
    reply="$(curl -s -m "$TIMEOUT" -w '\n%{http_code}' -H "apikey: $(getenv "$name")" "http://localhost:$1$2" || true)"
    code="$(printf '%s\n' "$reply" | tail -n 1)"
    case "$code" in
    000 | 502 | 503 | 504) verdict=error ;;
    401 | 403) if printf '%s' "$reply" | grep -q '"request_id"'; then verdict=refused; else verdict=upstream; fi ;;
    *) verdict=upstream ;;
    esac
    [ "$verdict" = refused ] || break
  done
  printf '%s %s %s\n' "$verdict" "$code" "$2"
}

# check_routes requests, in parallel, every route whose upstream is running and fails on a
# gateway error. A route to a service outside the running shape is stated, not failed.
check_routes() {
  hosts="$(live_hosts)"
  route_table | awk -v hosts="$hosts" 'BEGIN { split(hosts, list, "\n"); for (i in list) live[list[i]] = 1 }
    { print (($2 in live) ? "GO " : "OFF ") $1, $2 }' >"$TMP/routes"
  {
    sed -n 's/^OFF \([^ ]*\) \(.*\)/off - \1 \2/p' "$TMP/routes"
    sed -n 's/^GO \([^ ]*\) .*/\1/p' "$TMP/routes" | xargs -P 8 -n 1 sh "$0" route "$1"
  } | sort -k3 | awk '
    $1 == "off" { off++; printf "  • %s — upstream %s is not in the running shape\n", $3, $4; next }
    $1 == "error" { bad++; printf "  ✗ %s — HTTP %s, the gateway cannot reach the upstream\n", $3, $2; next }
    $1 == "refused" { refused++; printf "  • %s — HTTP %s from a Kong plugin with both keys, upstream not exercised\n", $3, $2; next }
    { answered++ }
    END { printf "  → %d routes: %d answered by the upstream · %d refused at the gateway · %d outside the running shape · %d gateway errors\n", NR, answered, refused, off, bad
          exit (bad > 0 || answered == 0) }'
}

# check_gateway runs the route sweep, then requires 200 from the two anon-readable endpoints.
check_gateway() {
  port="$(docker port "$PROJECT-kong" 8000/tcp 2>/dev/null | sed -n '1s/.*://p')"
  failed=0
  check_routes "${port:-8000}" || failed=1
  for path in /auth/v1/health /rest/v1/; do
    code="$(curl -s -o /dev/null -m "$TIMEOUT" -w '%{http_code}' -H "apikey: $(getenv ANON_KEY)" "http://localhost:${port:-8000}$path" || true)"
    if [ "$code" = 200 ]; then
      printf '  ✓ %s → 200\n' "$path"
    else
      failed=1
      printf '  ✗ %s — HTTP %s%s\n' "$path" "$code" "$([ "$code" = 401 ] && printf ' (the ANON_KEY in %s is not the one the stack runs with)' "$ENV_FILE")"
    fi
  done
  return "$failed"
}

# prom_labels prints the value of label $2 for every series the instant query $1 (already
# url-encoded) returns, one per line.
prom_labels() {
  docker exec "$PROJECT-prometheus" /bin/busybox wget -qO- "$PROM$1" | grep -o "\"$2\":\"[^\"]*\"" | cut -d'"' -f4 | sort -u
}

# check_monitoring fails when Prometheus reports a scrape target down or an alert firing.
check_monitoring() {
  if ! docker ps --format '{{.Names}}' | grep -qx "$PROJECT-prometheus"; then
    printf '  • NOT RUN — no prometheus container in the running shape\n'
    return 0
  fi
  total="$(prom_labels up instance | grep -c . || true)"
  down="$(prom_labels 'up%3D%3D0' instance | tr '\n' ' ')"
  firing="$(prom_labels 'ALERTS%7Balertstate%3D%22firing%22%7D' alertname | tr '\n' ' ')"
  if [ "$total" -eq 0 ]; then
    printf '  ✗ Prometheus returned no scrape target at all\n'
    return 1
  fi
  [ -z "$down" ] && printf '  ✓ %s scrape targets, none down\n' "$total" || printf '  ✗ scrape targets DOWN: %s\n' "$down"
  [ -z "$firing" ] && printf '  ✓ no alert firing\n' || printf '  ✗ alerts FIRING: %s\n' "$firing"
  [ -z "$down$firing" ]
}

# run_legs runs the legs selected by $1 (all, engines, gateway, monitoring).
run_legs() {
  failed=0
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  if [ "$1" = all ] || [ "$1" = engines ]; then
    printf 'Engines — a query with the credentials in %s\n' "$ENV_FILE"
    check_engines || failed=1
  fi
  if [ "$1" = all ] || [ "$1" = gateway ]; then
    printf 'Gateway — HTTP through Kong, anon key then service-role key\n'
    check_gateway || failed=1
  fi
  if [ "$1" = all ] || [ "$1" = monitoring ]; then
    printf 'Monitoring — what Prometheus sees\n'
    check_monitoring || failed=1
  fi
  return "$failed"
}

main() {
  case "${1:-all}" in
  routes) route_table ;;
  route) route_verdict "$2" "$3" ;;
  all | engines | gateway | monitoring) run_legs "${1:-all}" ;;
  *) sed -n '2,/^# Exit:/s/^# \{0,1\}//p' "$0" ;;
  esac
}

main "$@"
