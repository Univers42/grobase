#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m66-netseg.sh — the network-segmentation overlay (G-Net) keeps the public   #
#  edge and the scrapers away from the engines and vault, and every real       #
#  engine client can still reach its engine.                                   #
#                                                                              #
#  Renders the real services (every profile), no stack needed:                 #
#    (1) parity: the base alone puts every service on `mini-baas` only         #
#    (2) with the overlay — on the dev stack and on the prod stack (base +     #
#        prod overlay + this one, what `make prod-up` runs) — the engines sit  #
#        on net-data only, vault on net-vault only, postgres keeps alias db;   #
#        (3) and (4) run on both stacks too                                    #
#    (3) waf, kong, studio, playground, loki, promtail, functions-runtime,     #
#        mailpit and minio share no bridge with an engine or vault, and        #
#        prometheus none with an engine                                        #
#    (4) every client shares a bridge with the engine it dials: each engine    #
#        host named in a service's own environment/command, plus the edges     #
#        that live in config files, code defaults or tenant mounts (EDGES)     #
#  Live, when the running stack was started with the overlay (NETSEG=1):       #
#    (5) from kong's network namespace postgres and vault are unreachable by   #
#        IP; from query-router's both connect by name                          #
#  Otherwise (5) prints SKIP.                                                  #
#                                                                              #
#  Ponytail: (4) finds env/command edges by hostname, so an engine reached     #
#  through a variable only .env sets (env_file) or a code default is seen      #
#  only if EDGES lists it — a new such client must be added there. The live    #
#  stack is the backstop: a missed edge shows as an unhealthy service.         #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OVERLAY="${M66_OVERLAY:-${ROOT}/orchestrators/compose/docker-compose.netseg.yml}"
PROD="${ROOT}/orchestrators/compose/docker-compose.prod.yml"
ENGINES="postgres mysql mariadb cockroach mssql mongo redis dynamodb-local"
UNTRUSTED="waf kong studio playground loki promtail functions-runtime mailpit minio"
ROUTERS="query-router data-plane-router-rust adapter-registry-go"
EDGES="debezium>postgres debezium>redis trino>postgres trino>mysql trino>mongo
grafana>postgres db-bootstrap>postgres pg-meta>postgres pg-migrate>postgres storage-router>redis
outbox-relay>redis tenant-control>postgres vault-init>vault prometheus>vault"
BUSYBOX="busybox:1.36"
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M66] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M66] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# render writes the merged config of the compose files $@ to stdout as JSON.
render() {
  local files=()
  for f in "$@"; do files+=(-f "${f}"); done
  docker compose "${files[@]}" --profile '*' config --no-env-resolution --format json 2>/dev/null
}

# nets prints the sorted, comma-joined networks of service $1 in config $2.
nets() {
  jq -r --arg s "$1" '.services[$s].networks // {} | keys | sort | join(",")' "$2"
}

# share reports whether services $1 and $2 have a network in common in $3.
share() {
  jq -e --arg a "$1" --arg b "$2" '(.services[$a].networks // {} | keys) as $x
    | (.services[$b].networks // {} | keys) | any(. as $n | $x | index($n))' "$3" >/dev/null
}

# declared_edges prints "client>engine" for every engine host (or container
# name) that a service's own environment, command or entrypoint names as a URL
# host (//host, @host) or as host:port.
declared_edges() {
  jq -r --arg e "${ENGINES} vault" '($e | split(" ")) as $eng
    | .services as $s | [$s | to_entries[] | {k: .key, n: (.value.container_name // .key)}] as $names
    | $s | to_entries[] | .key as $c
    | ([(.value.environment // {})[] | tostring] + [.value.command // "", .value.entrypoint // "" | tostring] | join(" ")) as $t
    | $names[] | select((.k | IN($eng[])) and .k != $c)
    | "(//|@)(\(.k)|\(.n))([:/]|$)|(^|[ ,=\"])(\(.k)|\(.n)):[0-9]+" as $re | select($t | test($re)) | "\($c)>\(.k)"' "$1" | sort -u
}

parity() {
  local bad
  render "${ROOT}/docker-compose.yml" >"${WORK}/base.json" || fail "base compose does not render"
  bad="$(jq -r '.services | to_entries[] | select((.value.networks // {} | keys) != ["mini-baas"]) | .key' "${WORK}/base.json")"
  [ -z "${bad}" ] || fail "base puts these services off the flat bridge: ${bad//$'\n'/ }"
  [ "$(jq -r '.networks | keys | join(",")' "${WORK}/base.json")" = mini-baas ] || fail "base defines networks besides mini-baas"
  ok "(1) base alone: $(jq '.services | length' "${WORK}/base.json") services, all on mini-baas only"
}

# placement checks the engines and vault sit only on their own bridge in $1.
placement() {
  local e
  for e in ${ENGINES}; do
    [ "$(nets "${e}" "$1")" = net-data ] || fail "${e} is on '$(nets "${e}" "$1")', want net-data only"
  done
  [ "$(nets vault "$1")" = net-vault ] || fail "vault is on '$(nets vault "$1")', want net-vault only"
  jq -e '.services.postgres.networks["net-data"].aliases | index("db")' "$1" >/dev/null ||
    fail "postgres lost its db alias"
  ok "(2) engines on net-data only, vault on net-vault only, postgres keeps alias db"
}

# isolation checks no untrusted service shares a bridge with an engine or vault in $1.
isolation() {
  local u e
  for u in ${UNTRUSTED}; do
    for e in ${ENGINES} vault; do
      ! share "${u}" "${e}" "$1" || fail "${u} shares a bridge with ${e}"
    done
  done
  for e in ${ENGINES}; do
    ! share prometheus "${e}" "$1" || fail "prometheus shares a bridge with ${e}"
  done
  ok "(3) $(wc -w <<<"${UNTRUSTED}") edge/observability/sandbox services reach no engine or vault; prometheus no engine"
}

# reachability checks every client shares a bridge with the engine it dials in $1.
reachability() {
  local n=0 r e c
  {
    declared_edges "$1"
    printf '%s\n' ${EDGES}
    for r in ${ROUTERS}; do for e in ${ENGINES} vault; do echo "${r}>${e}"; done; done
  } | sort -u >"${WORK}/edges" || fail "edge scan failed"
  [ "$(declared_edges "$1" | wc -l)" -ge 20 ] || fail "env/command scan found under 20 edges — broken?"
  while IFS='>' read -r c e; do
    share "${c}" "${e}" "$1" || fail "${c} dials ${e} but shares no bridge with it"
    n=$((n + 1))
  done <"${WORK}/edges"
  ok "(4) all ${n} client→engine/vault edges share a bridge"
}

# probe runs nc -z from the network namespace of container $1 to $2:$3.
probe() {
  docker run --rm --net "container:$1" "${BUSYBOX}" nc -z -w 3 "$2" "$3" >/dev/null 2>&1
}

# ip_on prints container $1's address on the network whose name ends in $2.
ip_on() {
  docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{$v.IPAddress}}{{"\n"}}{{end}}' "$1" 2>/dev/null |
    awk -v n="$2" '$1 ~ (n "$") { print $2 }'
}

live() {
  local pg vault
  docker inspect mini-baas-postgres >/dev/null 2>&1 && pg="$(ip_on mini-baas-postgres _net-data)" && [ -n "${pg}" ] || {
    printf '  SKIP (5): no running stack started with the overlay (make up NETSEG=1)\n'
    return 0
  }
  vault="$(ip_on mini-baas-vault _net-vault)"
  ! probe mini-baas-kong "${pg}" 5432 || fail "kong reaches postgres (${pg}:5432)"
  [ -z "${vault}" ] || ! probe mini-baas-kong "${vault}" 8200 || fail "kong reaches vault (${vault}:8200)"
  probe mini-baas-query-router postgres 5432 || fail "query-router cannot reach postgres:5432"
  [ -z "${vault}" ] || probe mini-baas-query-router vault 8200 || fail "query-router cannot reach vault:8200"
  ok "(5) live: kong → postgres${vault:+/vault} refused by IP; query-router → postgres${vault:+/vault} connects"
}

# segmented renders compose files $2… to $1 and runs (2)–(4) on it.
segmented() {
  local out="$1"
  shift
  render "$@" >"${out}" || fail "$* does not render"
  placement "${out}"
  isolation "${out}"
  reachability "${out}"
}

step "static: the real services' networks with and without the overlay"
parity
step "dev stack: base + overlay"
segmented "${WORK}/dev.json" "${ROOT}/docker-compose.yml" "${OVERLAY}"
step "prod stack: base + prod overlay + overlay (make prod-up)"
segmented "${WORK}/prod.json" "${ROOT}/docker-compose.yml" "${PROD}" "${OVERLAY}"
step "live: the running stack, if segmented"
live
printf '\033[0;32m[M66] OK — engines and vault are off the app bridge; every client still reaches them, the edge does not\033[0m\n'
