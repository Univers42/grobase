#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m197-functions-net-jail.sh — tenant function code must not reach the        #
#  platform's internals; it may reach Kong's proxy through the relay           #
#                                                                              #
#  Tenant code runs in Deno Workers inside functions-runtime. With             #
#  net:"inherit" on the flat mini-baas network it opened kong:8001 (admin:     #
#  /key-auths hands out the service_role key), postgres, mongo, cockroach      #
#  (--insecure) … by name, by container IP, or by a DNS name it controls.      #
#  docker-compose.prod.yml / .cloud.yml jail it twice: functions-runtime alone #
#  on `functions-jail` behind one functions-relay (kernel), and                #
#  FUNCTIONS_NET_ALLOWLIST_ENABLED=1 (Deno Worker allowlist).                  #
#                                                                              #
#  LIVE, against the RUNNING stack's network (it must be up: a refusal from a  #
#  stack that is down proves nothing). Throwaway runtime/relay containers run  #
#  this tree's src/ on the local runtime image and are attached exactly as     #
#  the overlay render says (mini-baas = the live network, with NO alias, so    #
#  no live name is shadowed; any other network = a throwaway bridge). A probe  #
#  function deploys and runs in each leg and TCP-connects to every target:     #
#    base      the base render (today): kong:8001, Kong's raw IP, a hostile    #
#              DNS name for Kong's IP, postgres, mongo MUST be open — else     #
#              the gate is vacuous — and the jail check MUST fail here         #
#    kernel    overlay networks, allowlist forced OFF: internal targets still  #
#              refused (the jail alone holds); the Kong callback still 401s    #
#    allowlist base network, overlay allowlist + kong:8000, warm pool ON:      #
#              internal targets refused, kong:8000 open (the list alone holds, #
#              port-exact, on the warm-pool Worker path too)                   #
#    overlay   the overlay as shipped: every internal target refused, and      #
#              the relay's 3060/3025 and the runtime's own 127.0.0.1:3060      #
#              too; functions-relay:8000/functions/v1 answers Kong's 401;      #
#              deploy+invoke went in through the relay; the runtime process    #
#              reaches the secrets resolve (dispatcher's own answer) and only  #
#              that path (relay 404)                                           #
#                                                                              #
#  Needs .env (compose render), jq, the functions-runtime image locally, and   #
#  the stack up with kong/postgres/mongo. Missing any = FAIL.                  #
#  Mutant hooks: M197_OVERLAY=<path> checks another overlay; one that leaves   #
#  functions-runtime on mini-baas, or drops the Worker allowlist, goes red.    #
#  M197_SRC=<dir> runs another runtime src/; one whose Workers keep            #
#  net:"inherit" whatever the flag says goes red.                              #
#  Removes every container/network it creates (EXIT trap); never stops,        #
#  restarts or re-aliases a running mini-baas container.                       #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${ROOT}" || exit 1
OVERLAY="${M197_OVERLAY:-orchestrators/compose/docker-compose.prod.yml}"
SRC="${M197_SRC:-${ROOT}/infra/docker/services/functions-runtime/src}"
P="m197-$$"
TENANT="m197t$$"
TOKEN="m197-dummy-service-token"
T="$(mktemp -d)" || exit 1
chmod 700 "${T}"
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M197] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M197] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

# cleanup removes every m197 container and network of this run, then the temp dir.
cleanup() {
  docker ps -aq --filter "name=${P}-" | xargs -r docker rm -f >/dev/null 2>&1
  docker network ls -q --filter "name=${P}-" | xargs -r docker network rm >/dev/null 2>&1
  rm -rf "${T}"
}
trap cleanup EXIT

# render writes `docker compose <files> --profile '*' config` as JSON to $1.
render() {
  local out="$1"
  shift
  docker compose "$@" --profile '*' config --format json >"${out}" 2>"${T}/render.err" ||
    fail "compose render failed ($*): $(head -c 400 "${T}/render.err")"
}

# rt_env prints functions-runtime's env var $2 in render file $1 (empty when unset).
rt_env() { jq -r --arg k "$2" '.services["functions-runtime"].environment[$k] // ""' "$1"; }

# live_stack sets LIVE_NET (the running stack's network) and KONG_IP (its
# Kong's address there), failing when the stack is not up.
live_stack() {
  local kong
  LIVE_NET="$(jq -r '.networks["mini-baas"].name' "${T}/base.json")"
  docker network inspect "${LIVE_NET}" >/dev/null 2>&1 ||
    fail "network ${LIVE_NET} absent — bring the stack up (make up): refusals from a down stack are vacuous"
  kong="$(docker ps -q --filter "network=${LIVE_NET}" --filter label=com.docker.compose.service=kong | head -n1)"
  [ -n "${kong}" ] || fail "no running kong on ${LIVE_NET} (make up)"
  KONG_IP="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${LIVE_NET}\").IPAddress}}" "${kong}")"
  [ -n "${KONG_IP}" ] || fail "could not read kong's address on ${LIVE_NET}"
}

# ensure_net sets NET to the docker network for render network key $1: the
# live network for mini-baas, else a throwaway bridge created on first use.
ensure_net() {
  NET="${LIVE_NET}"
  [ "$1" = mini-baas ] && return 0
  NET="${P}-$1"
  docker network inspect "${NET}" >/dev/null 2>&1 && return 0
  docker network create --driver bridge "${NET}" >/dev/null || fail "could not create network ${NET}"
}

# alias_flags fills AL with "$1 <name>" pairs for service $2 on network key $3
# with render aliases $4 (comma list) — none on the live network.
alias_flags() {
  local a extra=()
  AL=()
  [ "$3" = mini-baas ] && return 0
  IFS=, read -ra extra <<<"$4"
  for a in "$2" "${extra[@]}"; do AL+=("$1" "${a}"); done
}

# launch creates container $1 as render service $2, attached to that service's
# networks in render file $3, then starts it; the remaining args are docker
# create args ending with the image and its command.
launch() {
  local c="$1" svc="$2" f="$3" key aliases first=1
  shift 3
  while read -r key aliases; do
    ensure_net "${key}"
    if [ "${first}" = 1 ]; then
      alias_flags --network-alias "${svc}" "${key}" "${aliases}"
      docker create --name "${c}" --network "${NET}" "${AL[@]}" "$@" >/dev/null || fail "docker create ${c}"
      first=0
    else
      alias_flags --alias "${svc}" "${key}" "${aliases}"
      docker network connect "${AL[@]}" "${NET}" "${c}" || fail "connect ${c} to ${NET}"
    fi
  done < <(jq -r --arg s "${svc}" '.services[$s].networks | to_entries[]
    | "\(.key) \((.value.aliases // []) | join(","))"' "${f}")
  [ "${first}" = 0 ] || fail "render ${f##*/} has no networks for ${svc}"
  docker start "${c}" >/dev/null || fail "docker start ${c}: $(docker logs "${c}" 2>&1 | tail -n3)"
}

# http_in makes one request from inside container $1 and prints the status,
# then the body ("000" and the error when nothing answers). $2 method, $3 URL,
# $4 body (may be empty), $5 headers as a JSON object.
http_in() {
  docker exec -e M="$2" -e U="$3" -e B="$4" -e H="$5" "$1" deno eval '
    try {
      const r = await fetch(Deno.env.get("U"), { method: Deno.env.get("M"), body: Deno.env.get("B") || undefined,
        headers: JSON.parse(Deno.env.get("H") || "{}"), signal: AbortSignal.timeout(20000) });
      console.log(r.status);
      console.log(await r.text());
    } catch (e) {
      console.log("000");
      console.log(String(e));
    }' 2>&1
}

# api calls the runtime API as tenant TENANT through container $1's own
# 127.0.0.1:3060 (the relay's ingress when $1 is the relay). $2 method, $3 path, $4 body.
api() {
  http_in "$1" "$2" "http://127.0.0.1:3060$3" "${4:-}" "{\"content-type\":\"application/json\",\"x-baas-tenant-id\":\"${TENANT}\"}"
}

# wait_api waits up to 30 s for /health/live through container $1.
wait_api() {
  local i
  for i in $(seq 1 30); do
    [ "$(api "$1" GET /health/live | head -n1)" = 200 ] && return 0
    sleep 1
  done
  fail "runtime not answering through $1: $(docker logs "${2:-$1}" 2>&1 | tail -n3)"
}


# probe_via deploys and invokes the probe through container $1's API and
# writes its per-target JSON result to $2.
probe_via() {
  local r args
  r="$(api "$1" POST /v1/functions "$(jq -n --rawfile c "${T}/probe.js" '{name: "m197probe", code: $c}')")"
  [ "$(head -n1 <<<"${r}")" = 201 ] || fail "deploy through $1: ${r:0:300}"
  args="$(jq -n --args '{targets: $ARGS.positional, urls: ["http://functions-relay:8000/functions/v1"]}' \
    "${INTERNAL[@]}" "${SIDE[@]}" functions-relay:8000 kong:8000)"
  r="$(api "$1" POST /v1/functions/m197probe/invoke "${args}")"
  [ "$(head -n1 <<<"${r}")" = 200 ] || fail "invoke through $1: ${r:0:300}"
  tail -n +2 <<<"${r}" >"$2"
}

# st prints result file $1's verdict for target $2.
st() { jq -r --arg t "$2" '.[$t] // "missing"' "$1"; }

# all_refused fails unless every target after $2 is refused in result file $1
# ($2 names the leg for the message).
all_refused() {
  local f="$1" leg="$2" t v
  shift 2
  for t in "$@"; do
    v="$(st "${f}" "${t}")"
    case "${v}" in refused:*) ;; *) fail "${leg}: tenant code reached ${t} (${v})" ;; esac
  done
}

# runtime_args fills RT with docker create args for a throwaway runtime whose
# net-policy/secrets env comes from render $1 — allowlist flag forced to $2
# when non-empty, ",$3" appended to its list when non-empty — plus args $4...
runtime_args() {
  local f="$1" flag="$2" more="$3" allow
  shift 3
  allow="$(rt_env "${f}" FUNCTIONS_NET_ALLOW)${more:+,${more}}"
  RT=(--cpus 0.5 --memory 256m --tmpfs /data --add-host "m197-rebind.test:${KONG_IP}" -v "${SRC}:/app:ro"
    -e FUNCTIONS_INVOKE_TIMEOUT_MS=15000 -e "INTERNAL_SERVICE_TOKEN=${TOKEN}"
    -e "FUNCTIONS_NET_ALLOWLIST_ENABLED=${flag:-$(rt_env "${f}" FUNCTIONS_NET_ALLOWLIST_ENABLED)}"
    -e "FUNCTIONS_NET_ALLOW=${allow}" -e "FUNCTION_SECRETS_URL=$(rt_env "${f}" FUNCTION_SECRETS_URL)" "$@" "${IMG}")
}

# leg_base runs the probe in today's shape and proves the gate is not vacuous:
# the core internals are open there and the jail check fails on them.
leg_base() {
  local t r="${T}/r-base.json"
  runtime_args "${T}/base.json" "" ""
  launch "${P}-rt" functions-runtime "${T}/base.json" "${RT[@]}"
  wait_api "${P}-rt"
  probe_via "${P}-rt" "${r}"
  docker rm -f "${P}-rt" >/dev/null
  for t in kong:8001 "${KONG_IP}:8001" m197-rebind.test:8001 postgres:5432 mongo:27017; do
    [ "$(st "${r}" "${t}")" = open ] || fail "base: ${t} is $(st "${r}" "${t}") — the live stack is not reachable, every refusal below would be vacuous"
  done
  (all_refused "${r}" base "${INTERNAL[@]}") 2>/dev/null &&
    fail "base: the jail check passes on the un-jailed attachment — the gate is vacuous"
  ok "base: $(jq '[.[] | select(. == "open")] | length' "${r}") targets open, incl. kong:8001, ${KONG_IP}:8001, m197-rebind.test:8001, postgres, mongo — jail check fails here, as it must"
}

# relay_up starts the throwaway functions-relay exactly as render $1 defines it.
relay_up() {
  local -a ep
  mapfile -t ep < <(jq -r '.services["functions-relay"].entrypoint[]? // empty' "$1")
  [ "${#ep[@]}" -gt 1 ] || fail "${1##*/} defines no functions-relay entrypoint — nothing bridges the jail"
  launch "${P}-relay" functions-relay "$1" --memory 64m --cpus 0.25 --tmpfs /data -v "${SRC}:/app:ro" \
    -e "FUNCTIONS_RELAY_TCP=$(jq -r '.services["functions-relay"].environment.FUNCTIONS_RELAY_TCP // ""' "$1")" \
    -e "FUNCTIONS_RELAY_HTTP=$(jq -r '.services["functions-relay"].environment.FUNCTIONS_RELAY_HTTP // ""' "$1")" \
    --entrypoint "${ep[0]}" "${IMG}" "${ep[@]:1}"
}

# leg_overlay runs the probe in the overlay's shape through the relay's
# ingress and checks both layers, the Kong callback and the secrets path.
leg_overlay() {
  local r="${T}/r-overlay.json"
  runtime_args "${T}/prod.json" "" ""
  launch "${P}-rt" functions-runtime "${T}/prod.json" "${RT[@]}"
  wait_api "${P}-relay" "${P}-rt"
  probe_via "${P}-relay" "${r}"
  all_refused "${r}" overlay "${INTERNAL[@]}" "${SIDE[@]}"
  [ "$(st "${r}" http://functions-relay:8000/functions/v1)" = http:401 ] ||
    fail "overlay: callback functions-relay:8000/functions/v1 = $(st "${r}" http://functions-relay:8000/functions/v1), want Kong's key-auth 401"
  ok "overlay: ${#INTERNAL[@]} internal targets + relay 3060/3025 + 127.0.0.1:3060 refused; deploy/invoke in through the relay; callback → Kong 401 (key-auth)"
  secrets_path "${P}-rt"
  docker rm -f "${P}-rt" >/dev/null
}

# secrets_path proves the runtime process in container $1 reaches the secrets
# resolve through the relay (the dispatcher's own answer to a dummy token)
# and nothing else of webhook-dispatcher (the relay's bare 404).
secrets_path() {
  local url r code
  url="$(rt_env "${T}/prod.json" FUNCTION_SECRETS_URL)"
  r="$(http_in "$1" GET "${url}?tenant=${TENANT}&function=m197probe" "" "{\"x-internal-service-token\":\"${TOKEN}\"}")"
  code="$(head -n1 <<<"${r}")"
  case "${code}" in
  401) grep -q 'service token' <<<"${r}" || fail "secrets resolve 401 is not webhook-dispatcher's: ${r:0:200}" ;;
  200) tail -n +2 <<<"${r}" | jq -e 'type == "object"' >/dev/null || fail "secrets resolve 200 is not a JSON object: ${r:0:200}" ;;
  *) fail "runtime → ${url}: ${r:0:200}" ;;
  esac
  r="$(http_in "$1" GET "${url%%/internal/*}/v1/webhooks" "" '{"x-baas-tenant-id":"victim"}')"
  [ "$(head -n1 <<<"${r}")" = 404 ] && [ -z "$(tail -n +2 <<<"${r}" | tr -d '[:space:]')" ] ||
    fail "the relay passes more than the resolve path: GET /v1/webhooks → ${r:0:200}"
  ok "secrets: runtime → relay → webhook-dispatcher resolve answers its own ${code}; /v1/webhooks → relay 404 (never forwarded)"
}

# leg_kernel runs the probe on the overlay's networks with the allowlist OFF.
leg_kernel() {
  local r="${T}/r-kernel.json"
  runtime_args "${T}/prod.json" 0 ""
  launch "${P}-rt" functions-runtime "${T}/prod.json" "${RT[@]}"
  wait_api "${P}-rt"
  probe_via "${P}-rt" "${r}"
  docker rm -f "${P}-rt" >/dev/null
  all_refused "${r}" "kernel (allowlist OFF)" "${INTERNAL[@]}"
  [ "$(st "${r}" http://functions-relay:8000/functions/v1)" = http:401 ] || fail "kernel: callback lost"
  ok "kernel alone: ${#INTERNAL[@]} internal targets refused (relay 3060/3025 + localhost open here: $(st "${r}" functions-relay:3025)/$(st "${r}" 127.0.0.1:3060) — the allowlist's job)"
}

# leg_allowlist runs the probe on the base network with the overlay's
# allowlist plus kong:8000, through the warm-pool Worker path.
leg_allowlist() {
  local r="${T}/r-allowlist.json"
  runtime_args "${T}/prod.json" "" kong:8000 -e FUNCTIONS_WARM_POOL=1
  launch "${P}-rt" functions-runtime "${T}/base.json" "${RT[@]}"
  wait_api "${P}-rt"
  probe_via "${P}-rt" "${r}"
  docker rm -f "${P}-rt" >/dev/null
  all_refused "${r}" "allowlist (no jail)" "${INTERNAL[@]}" 127.0.0.1:3060
  [ "$(st "${r}" kong:8000)" = open ] || fail "allowlist: listed kong:8000 is $(st "${r}" kong:8000)"
  ok "allowlist alone (warm pool): ${#INTERNAL[@]} internal targets + 127.0.0.1:3060 refused, listed kong:8000 open while kong:8001 is not"
}

# report prints each target's verdict per leg.
report() {
  local t
  printf '  %-44s %-22s %-22s %-22s %s\n' target base overlay kernel allowlist
  for t in "${INTERNAL[@]}" "${SIDE[@]}" functions-relay:8000 kong:8000 http://functions-relay:8000/functions/v1; do
    printf '  %-44s %-22s %-22s %-22s %s\n' "${t}" "$(st "${T}/r-base.json" "${t}")" "$(st "${T}/r-overlay.json" "${t}")" \
      "$(st "${T}/r-kernel.json" "${t}")" "$(st "${T}/r-allowlist.json" "${t}")"
  done
}

[ -f .env ] || fail ".env missing: compose cannot render (env_file: [.env]). make env"
command -v jq >/dev/null || fail "jq is required"
step "render base and base+overlay (${OVERLAY##*/})"
render "${T}/base.json" -f docker-compose.yml
render "${T}/prod.json" -f docker-compose.yml -f "${OVERLAY}"
IMG="${M197_IMAGE:-$(jq -r '.services["functions-runtime"].image' "${T}/prod.json")}"
docker image inspect "${IMG}" >/dev/null 2>&1 || fail "image ${IMG} not present locally (make build-svc-functions-runtime, or M197_IMAGE=<tag>)"
live_stack
INTERNAL=(kong:8001 kong:8002 mini-baas-kong:8001 "${KONG_IP}:8001" m197-rebind.test:8001 vault:8200 postgres:5432
  mongo:27017 cockroach:26257 cockroach:8080 redis:6379 webhook-dispatcher:3025 function-scheduler:3027)
SIDE=(functions-relay:3060 functions-relay:3025 127.0.0.1:3060)
# The probe function: TCP-connect to every body.targets entry (2 s cap), GET
# every body.urls entry; per entry: open / http:<code> / refused:<error name>.
cat >"${T}/probe.js" <<'EOF'
const late = (ms) => new Promise((resolve) => setTimeout(() => resolve("refused:timeout"), ms));
async function probe(t) {
  const i = t.lastIndexOf(":");
  try {
    const c = await Promise.race([Deno.connect({ hostname: t.slice(0, i), port: Number(t.slice(i + 1)) }), late(2000)]);
    if (typeof c === "string") return c;
    c.close();
    return "open";
  } catch (e) {
    return "refused:" + ((e && e.name) || "error");
  }
}
async function get(u) {
  try {
    const r = await fetch(u, { signal: AbortSignal.timeout(3000) });
    await r.body?.cancel();
    return "http:" + r.status;
  } catch (e) {
    return "refused:" + ((e && e.name) || "error");
  }
}
export default async function (input) {
  const out = {};
  await Promise.all(input.body.targets.map(async (t) => { out[t] = await probe(t); }));
  await Promise.all(input.body.urls.map(async (u) => { out[u] = await get(u); }));
  return { status: 200, body: out };
}
EOF
ok "live network ${LIVE_NET}, kong at ${KONG_IP}; image ${IMG} running this tree's src/"
step "leg base — today's attachment (non-vacuity + negative)"
leg_base
relay_up "${T}/prod.json"
step "leg kernel — overlay networks, allowlist forced OFF"
leg_kernel
step "leg allowlist — base network, overlay allowlist, warm pool"
leg_allowlist
step "leg overlay — as shipped: jail + allowlist, in through functions-relay"
leg_overlay
step "verdicts (refused:<error> = no connection; a target refused in base too is not evidence of the jail)"
report
printf '\033[0;32m[M197] PASS — tenant functions: internals refused by the network jail alone and by the Worker allowlist alone; Kong proxy callback and secrets resolve still work through functions-relay\033[0m\n'
