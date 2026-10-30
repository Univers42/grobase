#!/usr/bin/env bash
# m261-redis-acl.sh — Redis ACL password, stage 1 (G5, ADR 0028, RA1–RA11).
#
# Static: the default render ignores REDIS_PASSWORD, make composes the overlay only on
# REDIS_ACL=1 (RA1); every base *REDIS*_URL plus the Debezium sink gets the login (RA4); the
# redis render carries no secret (RA2); ACL+TLS ≡ TLS+ACL (RA10); the rebind reads it (RA11).
# Live, own project: inspect carries no password/hash (RA2); health fails a wrong one (RA5);
# redis://redis:6379 is still served (RA8); go-redis, ioredis, Debezium refuse a wrong one,
# hold app, CLIENT LIST has 0 user=default (RA4); redis boots under both overlays (RA10).
#
# Caveat: the stack's own services are not booted (fixed container_name values would collide
# with a running stack); each client library is fed the value rendered for a real consumer
# instead. The Rust redis crate (realtime, data-plane-router; behind flags off by default) is
# not exercised. Counts only: no value is printed.
# Needs the .env (with REDIS_PASSWORD) and localhost cert compose interpolates, as m260.
# Env: M261_PROJECT (m261) · M261_IMAGE (redis image) · M261_TMP. An EXIT trap removes all.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ACL="orchestrators/compose/docker-compose.redis-acl.yml"
TLS="orchestrators/compose/docker-compose.engine-tls-redis.yml"
PROBES="${ROOT}/scripts/verify/m261-redis-acl"
PROJECT="${M261_PROJECT:-m261}"
CONTAINER="${PROJECT}-redis"
NET="${PROJECT}_mini-baas"
GO_IMAGE="${M261_GO_IMAGE:-golang:1.26-bookworm}"
NODE_IMAGE="${M261_NODE_IMAGE:-node:20-alpine}"
PG_IMAGE="${M261_PG_IMAGE:-mirror.gcr.io/library/postgres:16-alpine}"
PROBE_NAMES=(go ioredis debezium debezium-wrong postgres)
WORK=""

step() { printf '\033[0;36m[M261] %s\033[0m\n' "$*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M261] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

# dc OVERLAY... ARGS — compose under this project; the overlays come first, then the rename.
dc() {
  local -a files=(-f "${ROOT}/docker-compose.yml")
  while [[ "${1:-}" == *.yml ]]; do files+=(-f "${ROOT}/$1") && shift; done
  docker compose -p "${PROJECT}" --project-directory "${ROOT}" "${files[@]}" -f "${WORK}/rename.yml" "$@"
}
cleanup() {
  [[ -z "${WORK}" ]] && return
  for n in "${PROBE_NAMES[@]}"; do docker rm -fv "${PROJECT}-${n}" >/dev/null 2>&1 || true; done
  dc "${ACL}" "${TLS}" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}

# render OUT OVERLAY... — every profile's config as JSON; ENV_FILE (optional) replaces .env.
render() {
  local out="$1" o
  local -a files=(-f "${ROOT}/docker-compose.yml")
  shift
  for o in "$@"; do files+=(-f "${ROOT}/${o}"); done
  docker compose --project-directory "${ROOT}" ${ENV_FILE:+--env-file "${ENV_FILE}"} "${files[@]}" \
    --profile '*' config --format json >"${WORK}/${out}" 2>"${WORK}/render.err" ||
    fail "compose cannot render ${out}: $(grep -c . "${WORK}/render.err") error lines"
}
# secret_hits FILE — strings in FILE that contain the password or its sha256.
secret_hits() {
  jq --rawfile p "${WORK}/pw" --rawfile h "${WORK}/hash" \
    '[.. | strings | select(contains($p) or contains($h))] | length' "$1"
}
pairs='[.services | to_entries[] | .key as $s | (.value.environment // {}) | to_entries[]
  | select(.key | test("REDIS[A-Z_]*_URL$")) | {s: $s, k: .key, v: .value}]'

# make_dc — the compose command make would run, from the Makefile's own DC.
make_dc() {
  env -u REDIS_ACL ${REDIS_ACL:+REDIS_ACL="${REDIS_ACL}"} make -s --no-print-directory -C "${ROOT}" \
    --eval 'm261-dc: ; @echo $(DC)' m261-dc
}

static_default() {
  ENV_FILE="${WORK}/nokey.env" render nokey.json
  render base.json
  cmp -s "${WORK}/nokey.json" "${WORK}/base.json" || fail "minting REDIS_PASSWORD changed the default render"
  [[ "$(jq '[.. | strings | select(test("redis://app:|\\$\\{?REDIS_PASSWORD"))] | length' "${WORK}/base.json")" == 0 ]] ||
    fail "the default render names the redis app login"
  make_dc | grep -q redis-acl && fail "make composes the ACL overlay without REDIS_ACL=1"
  REDIS_ACL=1 make_dc | grep -q redis-acl || fail "REDIS_ACL=1 does not compose the ACL overlay"
  ok "RA1: default render identical with and without REDIS_PASSWORD; make composes it only on REDIS_ACL=1"
}

static_overlay() {
  render acl.json "${ACL}"
  local base names creds plain
  base="$(jq -c "${pairs} | map([.s, .k]) | sort" "${WORK}/base.json")"
  [[ "$(jq -c "${pairs} | map([.s, .k]) | sort" "${WORK}/acl.json")" == "${base}" ]] ||
    fail "the overlay's *REDIS*_URL (service, name) set differs from the base's"
  read -r names plain creds < <(jq -r "${pairs} | [(map(.k) | unique | length),
    (map(select(.v | startswith(\"redis://app:\") | not)) | length), length] | @tsv" "${WORK}/acl.json")
  [[ "${plain}" == 0 ]] || fail "${plain} of ${creds} *REDIS*_URL values lack the app login"
  jq -e '.services.debezium.environment | .DEBEZIUM_SINK_REDIS_USER == "app" and (.DEBEZIUM_SINK_REDIS_PASSWORD | length) > 0' \
    "${WORK}/acl.json" >/dev/null || fail "the Debezium sink is not given the app login"
  jq -e --slurpfile b "${WORK}/base.json" '.services.redis.command[0:3] == ["sh", "/usr/local/bin/redis-acl.sh", "serve"]
    and .services.redis.command[3:] == $b[0].services.redis.command' "${WORK}/acl.json" >/dev/null ||
    fail "the overlay's redis command drifted from the base command"
  [[ "$(jq '.services.redis' "${WORK}/acl.json" | secret_hits /dev/stdin)" == 0 ]] ||
    fail "the rendered redis service carries the password or its hash"
  ok "RA4: ${creds}/${creds} pairs over ${names} names credentialed, no new name; Debezium sink user/password set"
  ok "RA2: redis' command is the base command behind the wrapper; its render carries the secret 0 times"
}

static_orders() {
  local norm='.services |= map_values(if .volumes then .volumes |= sort_by(.target) else . end)'
  export ENGINE_TLS_REDIS_CERT_DIR="${WORK}/redis"
  render acl-tls.json "${ACL}" "${TLS}"
  render tls-acl.json "${TLS}" "${ACL}"
  cmp -s <(jq -S "${norm}" "${WORK}/acl-tls.json") <(jq -S "${norm}" "${WORK}/tls-acl.json") ||
    fail "ACL+TLS and TLS+ACL render differently (volumes order aside)"
  jq -e '.services.redis | .entrypoint[1] == "/usr/local/bin/engine-tls-drop.sh" and .command[1] == "/usr/local/bin/redis-acl.sh"' \
    "${WORK}/acl-tls.json" >/dev/null || fail "the combined render lost the TLS entrypoint or the ACL command"
  ok "RA10: ACL+TLS ≡ TLS+ACL once volumes are sorted; TLS keeps the entrypoint, ACL the command"
}

# The rebind script's own jq over two fixtures: the overlay login, then a missing one.
static_rebind() {
  local prog fixture
  prog="$(eval "$(sed -n '/^redis_program()/,/^}/p;/^config_program()/,/^}/p' \
    "${ROOT}/scripts/ops/grobase-import-rebind.sh")" && config_program)"
  fixture='[{"Name":"/mini-baas-redis","Args":["sh","/usr/local/bin/redis-acl.sh","serve"],"Config":{"Env":["VAULT_ENC_KEY=t"]}},
    {"Name":"/mini-baas-x","Config":{"Env":["VAULT_ENC_KEY=t","OUTBOX_REDIS_URL=redis://app:fixture@redis:6379"]}}]'
  jq -e --rawfile srcenv <(echo VAULT_ENC_KEY=s) "${prog}" <<<"${fixture}" |
    jq -e '.targets[] | select(.engine == "redis") | .user == "app" and .password == "fixture"' >/dev/null ||
    fail "grobase-import-rebind.sh does not read the overlay's redis login"
  jq --rawfile srcenv <(echo VAULT_ENC_KEY=s) "${prog}" <<<"$(jq -c 'del(.[1])' <<<"${fixture}")" >/dev/null 2>&1 &&
    fail "grobase-import-rebind.sh rebinds an ACL redis without a login"
  ok "RA11: the rebind config takes app's login from the consumers' URLs, refuses an ACL redis without one"
}

boot() {
  if ! dc "$@" up -d --wait --wait-timeout 120 --no-build --pull missing redis >"${WORK}/up.log" 2>&1; then
    tail -5 "${WORK}/up.log" >&2
    docker logs --tail 10 "${CONTAINER}" >&2 2>&1 || true
    fail "redis under $* did not become healthy"
  fi
}

live_redis() {
  boot "${ACL}"
  docker inspect "${CONTAINER}" >"${WORK}/inspect.json"
  [[ "$(secret_hits "${WORK}/inspect.json")" == 0 ]] || fail "docker inspect of redis carries the password or its hash"
  ok "RA2: redis healthy as app; docker inspect carries the password 0 times, its sha256 0 times"
  docker exec -i "${CONTAINER}" sh /usr/local/bin/redis-acl.sh health /dev/stdin <"${WORK}/pw" ||
    fail "the env file's REDIS_PASSWORD does not log in as app (stack-health leg 4)"
  echo not-the-password | docker exec -i "${CONTAINER}" sh /usr/local/bin/redis-acl.sh health /dev/stdin &&
    fail "the healthcheck passed a wrong password"
  local legacy=0
  docker exec -e REDISCLI_AUTH=not-the-password "${CONTAINER}" redis-cli --user app ping 2>/dev/null | grep -q PONG || legacy=$?
  ok "RA5: health fails a wrong password (a plain 'redis-cli --user app ping' with it: grep PONG exit ${legacy})"
  docker run --rm --entrypoint sh -v "${ROOT}/infra/docker/services/redis/redis-acl.sh:/s.sh:ro" \
    "$(jq -r '.[0].Config.Image' "${WORK}/inspect.json")" /s.sh serve redis-server >/dev/null 2>&1 &&
    fail "serve started redis with no secret"
  [[ "$(docker exec "${CONTAINER}" redis-cli ACL WHOAMI)" == default ]] || fail "nopass redis-cli is not default"
  docker run --rm --network "${NET}" "$(jq -r '.[0].Config.Image' "${WORK}/inspect.json")" \
    redis-cli -u redis://redis:6379 ping | grep -qx PONG || fail "redis://redis:6379 is not served"
  ok "RA8: serve refuses an empty secret; credential-free redis://redis:6379 (seed, m27 mounts) still PONGs as default"
}

# url_env OUT SERVICE NAME — M261_RIGHT_URL/M261_WRONG_URL from that service's rendered value.
url_env() {
  jq -r --arg s "$2" --arg k "$3" '.services[$s].environment[$k] as $u
    | "M261_RIGHT_URL=\($u)", "M261_WRONG_URL=\($u | sub(":[^:@/]+@"; ":not-the-password@"))",
      "M261_PLAIN_URL=redis://redis:6379"' "${WORK}/acl.json" >"${WORK}/$1"
}

# go_probe MODE DOCKER_ARGS... — goredis_probe.go built against src/control-plane's go.mod.
go_probe() {
  local mode="$1"
  shift
  docker run "$@" --network "${NET}" --env-file "${WORK}/go.env" -e CGO_ENABLED=0 \
    -v "${ROOT}/src/control-plane:/ro:ro" -v "${PROBES}/goredis_probe.go:/in/main.go:ro" \
    -v mini-baas-gomod:/go/pkg/mod -v mini-baas-gobuild:/root/.cache/go-build "${GO_IMAGE}" \
    sh -c 'mkdir /tmp/w && cp /ro/go.mod /ro/go.sum /in/main.go /tmp/w && cd /tmp/w && exec go run . "$0"' "${mode}"
}

start_clients() {
  url_env go.env webhook-dispatcher WEBHOOK_REDIS_URL
  url_env ioredis.env outbox-relay OUTBOX_REDIS_URL
  go_probe check --rm >"${WORK}/go-check.log" 2>&1 || { tail -5 "${WORK}/go-check.log" >&2 && fail "go-redis check failed"; }
  sed 's/^/    /' "${WORK}/go-check.log"
  go_probe hold -d --name "${PROJECT}-go" >/dev/null
  docker run -d --name "${PROJECT}-ioredis" --network "${NET}" --env-file "${WORK}/ioredis.env" \
    -e M261_IOREDIS=/tmp/n/node_modules/ioredis -v "${PROBES}/ioredis-probe.cjs:/in/probe.cjs:ro" "${NODE_IMAGE}" \
    sh -c 'npm install -s --no-audit --no-fund --prefix /tmp/n ioredis@5.11.0 && exec node /in/probe.cjs' >/dev/null
}

start_debezium() {
  printf 'POSTGRES_USER=postgres\nPOSTGRES_DB=postgres\nPOSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 16)" >"${WORK}/pg.env"
  docker run -d --name "${PROJECT}-postgres" --network "${NET}" --network-alias postgres \
    --env-file "${WORK}/pg.env" "${PG_IMAGE}" -c wal_level=logical >/dev/null
  wait_for postgres 'ready to accept connections' 60
  until docker exec "${PROJECT}-postgres" psql -qU postgres -c \
    'create table if not exists outbox_events (id bigserial primary key, payload jsonb)' >/dev/null 2>&1; do sleep 1; done
  jq -r '.services.debezium.environment | "DEBEZIUM_SINK_REDIS_USER=\(.DEBEZIUM_SINK_REDIS_USER)",
    "DEBEZIUM_SINK_REDIS_PASSWORD=\(.DEBEZIUM_SINK_REDIS_PASSWORD)"' "${WORK}/acl.json" >"${WORK}/dbz.env"
  sed 's/^DEBEZIUM_SINK_REDIS_PASSWORD=.*/&-not/' "${WORK}/dbz.env" >"${WORK}/dbz-wrong.env"
  local name
  for name in debezium debezium-wrong; do
    docker run -d --name "${PROJECT}-${name}" --network "${NET}" --env-file "${WORK}/pg.env" \
      --env-file "${WORK}/${name/debezium/dbz}.env" \
      -v "${ROOT}/infra/docker/services/debezium/application.properties:/debezium/config/application.properties:ro" \
      "$(jq -r '.services.debezium.image' "${WORK}/acl.json")" >/dev/null
  done
}

# wait_for NAME PATTERN SECONDS — until NAME's log matches; fail on exit or timeout.
wait_for() {
  local c="${PROJECT}-$1" i
  for ((i = 0; i < $3; i += 2)); do
    # Not grep -q: an early exit SIGPIPEs docker logs and pipefail would read it as no match.
    docker logs "${c}" 2>&1 | grep -E "$2" >/dev/null && return 0
    [[ "$(docker inspect -f '{{.State.Running}}' "${c}")" == true ]] || break
    sleep 2
  done
  docker logs --tail 15 "${c}" 2>&1 | grep -vE 'redis://|PASSWORD' | sed 's/^/    /' >&2
  fail "$1 did not log /$2/ within $3 s"
}

# tally [IP] — "N user=U lib-name=L" per kind of connection CLIENT LIST shows (from IP).
tally() {
  docker exec "${CONTAINER}" sh -c 'REDISCLI_AUTH=$(cat /run/secrets/redis_acl_password) redis-cli --no-auth-warning --user app CLIENT LIST' |
    grep -F " addr=${1:-}" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^(user|lib-name)=/) k = k " " $i; print k; k = "" }' |
    sort | uniq -c | tr -s ' ' | paste -sd';'
}
ip_of() { docker inspect -f "{{(index .NetworkSettings.Networks \"${NET}\").IPAddress}}" "${PROJECT}-$1"; }

live_clients() {
  start_clients
  start_debezium
  wait_for go 'holding' 120
  wait_for ioredis 'holding' 180
  { docker logs "${PROJECT}-go" && docker logs "${PROJECT}-ioredis"; } 2>&1 | grep -E '^(go-redis|ioredis):' | sed 's/^/    /'
  local name users all
  for name in go ioredis debezium; do
    for _ in $(seq 60); do
      users="$(tally "$(ip_of "${name}"):")" && [[ -n "${users}" ]] && break
      sleep 2
    done
    [[ "${users}" =~ ^\ ?[0-9]+\ user=app\  ]] && [[ "${users}" != *';'* ]] ||
      fail "${name} connections: '${users:-none}', want only user=app"
    ok "${name}: ${users}"
  done
  wait_for debezium-wrong 'WRONGPASS' 120
  [[ -z "$(tally "$(ip_of debezium-wrong):")" ]] || fail "Debezium with a wrong password holds a connection"
  ok "debezium with a wrong password: WRONGPASS in its log, no connection held"
  all="$(tally)"
  [[ "${all}" != *user=default* ]] || fail "CLIENT LIST still shows user=default: ${all}"
  ok "RA4: CLIENT LIST while go-redis, ioredis and Debezium hold: ${all} — user=default 0"
}

live_both() {
  local n
  for n in "${PROBE_NAMES[@]}"; do docker rm -fv "${PROJECT}-${n}" >/dev/null; done
  boot "${TLS}" "${ACL}"
  [[ "$(docker exec "${CONTAINER}" redis-cli CONFIG GET tls-port | tail -1)" == 6380 ]] || fail "no TLS on 6380"
  [[ "$(docker exec "${CONTAINER}" sh -c 'REDISCLI_AUTH=$(cat /run/secrets/redis_acl_password) redis-cli --no-auth-warning --tls --cacert /etc/engine-tls/ca.pem -h redis -p 6380 --user app ACL WHOAMI')" == app ]] ||
    fail "app does not log in over TLS"
  ok "RA10: under TLS+ACL redis is healthy, serves TLS on 6380, app logs in over rediss"
}

step "0/4 preconditions"
command -v jq >/dev/null 2>&1 || fail "jq is required"
[[ -f "${ROOT}/.env" ]] || fail "no .env: run scripts/env/assemble-env.sh"
umask 077
WORK="$(mktemp -d "${M261_TMP:-${TMPDIR:-/tmp}}/m261.XXXXXX")"
trap cleanup EXIT
sed -n 's/^REDIS_PASSWORD=//p' "${ROOT}/.env" | head -1 | tr -d '\n' >"${WORK}/pw"
[[ -s "${WORK}/pw" ]] || fail "REDIS_PASSWORD is unset in .env: run make env"
sha256sum <"${WORK}/pw" | cut -d' ' -f1 | tr -d '\n' >"${WORK}/hash"
grep -v '^REDIS_PASSWORD=' "${ROOT}/.env" >"${WORK}/nokey.env"
printf 'services:\n  redis:\n    container_name: %s\n    ports: !reset []\n' "${CONTAINER}" >"${WORK}/rename.yml"
[[ -z "${M261_IMAGE:-}" ]] || printf '    image: %s\n' "${M261_IMAGE}" >>"${WORK}/rename.yml"
mkdir -p "${WORK}/redis"
TRACK_BINOCLE_CERT_DIR="${WORK}" MINI_BAAS_WAF_TLS_GID=none GROBASE_PUBLIC_ADDRESSES='' \
  sh "${ROOT}/scripts/certs/generate-localhost-cert.sh" >/dev/null
TRACK_BINOCLE_CERT_DIR="${WORK}" ENGINE_TLS_CERT_DIR="${WORK}/redis" \
  sh "${ROOT}/scripts/certs/generate-engine-cert.sh" redis >/dev/null
rm -f "${WORK}/track-binocle-local-ca-key.pem"
ok ".env has REDIS_PASSWORD (set); throwaway engine cert minted"

step "1/4 static: renders"
static_default
static_overlay
static_orders
static_rebind

step "2/4 live: redis behind the ACL overlay (project ${PROJECT})"
live_redis

step "3/4 live: go-redis, ioredis, Debezium with the rendered values"
live_clients

step "4/4 live: redis behind TLS + ACL"
live_both
printf '\033[0;32m[M261] ALL GATES GREEN — stage 1: app user live, default still on (stage 2 is its own ruling)\033[0m\n'
