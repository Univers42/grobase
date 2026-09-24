#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m195-prod-overlay-hardening.sh — the production overlay's security values   #
#  must land on the services that read them, and nowhere by default            #
#                                                                              #
#  STATIC  base and base+prod rendered with every profile (`--profile '*'`,    #
#          realtime and tenant-control are profile-gated) as JSON:             #
#    gotrue  GOTRUE_MAILER_AUTOCONFIRM=false, GOTRUE_PASSWORD_MIN_LENGTH=12    #
#    kong    KONG_STATUS_LISTEN=0.0.0.0:8001, KONG_ADMIN_LISTEN=off,           #
#            KONG_ADMIN_GUI_LISTEN=off; the base env map merged, not replaced; #
#            no 8001/8002/8444 publish; healthcheck still asks :8000 (m187);   #
#            prometheus.yml still scrapes kong:8001                            #
#    guards  storage-router STORAGE_ACTIVE_CONTENT_GUARD_ENABLED=1 (L-9),      #
#            query-router AUTOMATION_WEBHOOK_IP_PIN_ENABLED=1 (L-12); base     #
#            env maps merged; neither key changes on any other service         #
#    held    IDENTITY_HEADER_MODE, TENANT_HEADER_IDENTITY_HMAC, SECURITY_MODE, #
#            REALTIME_NAMESPACE_FALLBACK, TENANT_CONTROL_VERIFY_CACHE_TTL_MS   #
#            identical on every service with and without the overlay (a        #
#            service only the overlay adds carries none of them)               #
#    jail    functions-runtime on functions-jail alone (not external, not      #
#            mini-baas; only functions-relay joins it), alias                  #
#            functions-sandbox, FUNCTIONS_NET_ALLOWLIST_ENABLED=1,             #
#            FUNCTIONS_NET_ALLOW led by functions-relay:8000, secrets via the  #
#            relay, base env map merged; functions-relay on exactly            #
#            functions-jail + mini-baas, sole holder of the mini-baas alias    #
#            functions-runtime, relays exactly 3060=functions-sandbox:3060,    #
#            8000=kong:8000 and the one secrets path, env = its two specs      #
#            only, runs relay.ts, same profiles as the runtime (m197 = live)   #
#    parity  base alone keeps today's values (autoconfirm from .env, else      #
#            false; min length 8; admin 0.0.0.0:8001; guard flags and          #
#            FUNCTIONS_NET_ALLOWLIST_ENABLED as .env has them, else unset;     #
#            functions-runtime on mini-baas, no relay, no jail) = OFF          #
#  CLOUD   base + docker-compose.cloud.yml (make cloud-up) with its            #
#          flags.env.cloud env_file pointed at a one-key sentinel stub (the    #
#          real file is gitignored): both guards =1 on their router only,      #
#          router env maps merged, and the stub reaches exactly orchestrator,  #
#          tenant-control and data-plane-router-rust (no STRIPE_* widening);   #
#          the same functions jail, rendered identical to prod's               #
#  DYNAMIC two throwaway Kong containers (--network none, same kong.yml with   #
#          dummy keys), listener env taken from each render:                   #
#    base    :8001/key-auths answers 200 (the exposure this closes)            #
#    prod    :8001/metrics serves the SAME metric names as base admin          #
#            /metrics; /key-auths and /jwts 404; :8002/:8444 refused; the      #
#            proxy :8000 still answers (the Kong healthcheck's question)       #
#                                                                              #
#  Needs .env (env_file: [.env] is mandatory, so compose cannot render         #
#  without it: `make env`, or in CI `FORCE=1 bash scripts/env/generate-env.sh  #
#  .env`), jq, and the kong image present locally. A missing one FAILS: a gate #
#  that cannot look has not passed. The rendered JSON carries .env secrets: it #
#  stays in a mode-700 temp dir and only named, non-secret paths are printed.  #
#                                                                              #
#  Mutant hook: M195_OVERLAY=<path> checks another overlay; one that drops a   #
#  value, leaves the admin API on, sets an identity flag, puts a guard flag    #
#  on the wrong service, leaves functions-runtime on mini-baas, drops the      #
#  Worker allowlist, or relays one port more must go red.                      #
#  M195_CLOUD_OVERLAY=<path> does the same for the cloud overlay: one that     #
#  drops a guard, hands flags.env.cloud to another service, or lets its        #
#  functions jail drift from prod's must go red.                               #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${ROOT}" || exit 1
OVERLAY="${M195_OVERLAY:-orchestrators/compose/docker-compose.prod.yml}"
CLOUD="${M195_CLOUD_OVERLAY:-orchestrators/compose/docker-compose.cloud.yml}"
P="m190gate$$"
T="$(mktemp -d)" || exit 1
chmod 700 "${T}"
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M195] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M195] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

# cleanup removes the throwaway Kong containers and the temp dir.
cleanup() {
  docker rm -f "${P}-base" "${P}-prod" >/dev/null 2>&1 || true
  rm -rf "${T}"
}
trap cleanup EXIT

# expect_val fails unless jq path $2 in rendered file $1 equals $3.
expect_val() {
  local got
  got="$(jq -r "($2) // \"<unset>\"" "$1")"
  [ "${got}" = "$3" ] || fail "${1##*/}: $2 = '${got}', want '$3'"
}

# dotenv_get prints the last plain KEY=value for $1 in .env, quotes stripped
# (the shape `make env` writes; empty when absent).
dotenv_get() {
  awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) }
    END { gsub(/^["\047]|["\047]$/, "", v); print v }' .env
}

# render writes `docker compose <files> --profile '*' config` as JSON to $1.
render() {
  local out="$1"
  shift
  docker compose "$@" --profile '*' config --format json >"${out}" 2>"${T}/render.err" ||
    fail "compose render failed ($*): $(head -c 400 "${T}/render.err")"
}

# static_overlay asserts every intended value on its service, with the base
# env map merged rather than replaced.
static_overlay() {
  local j="${T}/prod.json" b="${T}/base.json"
  expect_val "${j}" '.services.gotrue.environment.GOTRUE_MAILER_AUTOCONFIRM' false
  expect_val "${j}" '.services.gotrue.environment.GOTRUE_PASSWORD_MIN_LENGTH' 12
  expect_val "${j}" '.services.kong.environment.KONG_STATUS_LISTEN' 0.0.0.0:8001
  expect_val "${j}" '.services.kong.environment.KONG_ADMIN_LISTEN' off
  expect_val "${j}" '.services.kong.environment.KONG_ADMIN_GUI_LISTEN' off
  expect_val "${j}" '.services.kong.environment.KONG_DECLARATIVE_CONFIG' /tmp/kong.yml
  jq -e -n --slurpfile b "${b}" --slurpfile p "${j}" '[("gotrue", "kong", "storage-router", "query-router") as $s
    | ($b[0].services[$s].environment | keys) - ($p[0].services[$s].environment | keys)]
    | flatten | length == 0' >/dev/null ||
    fail "overlay replaced a base env map (gotrue/kong/storage-router/query-router keys lost)"
  ok "gotrue autoconfirm=false min_length=12; kong status 0.0.0.0:8001, admin off, gui off; base env maps merged"
}

# guards_on asserts in rendered file $1 that each TS guard flag is "1" on the
# one service whose code reads it, and as the base has it on every other one.
guards_on() {
  local pair svc key
  for pair in storage-router:STORAGE_ACTIVE_CONTENT_GUARD_ENABLED query-router:AUTOMATION_WEBHOOK_IP_PIN_ENABLED; do
    svc="${pair%%:*}"
    key="${pair#*:}"
    expect_val "$1" ".services[\"${svc}\"].environment.${key}" 1
    jq -e -n --slurpfile b "${T}/base.json" --slurpfile p "$1" --arg s "${svc}" --arg k "${key}" '[$p[0].services
      | keys[] | select(. != $s) as $x
      | select($b[0].services[$x].environment[$k] != $p[0].services[$x].environment[$k])]
      | length == 0' >/dev/null || fail "${1##*/}: overlay changes ${key} on a service other than ${svc}"
  done
}

# static_guards asserts both TS guards under the prod overlay.
static_guards() {
  guards_on "${T}/prod.json"
  ok "storage-router STORAGE_ACTIVE_CONTENT_GUARD_ENABLED=1, query-router AUTOMATION_WEBHOOK_IP_PIN_ENABLED=1, nowhere else"
}

# render_cloud renders base + the cloud overlay to $1 with its flags.env.cloud
# env_file pointed at a stub holding one sentinel key: the real file is
# gitignored, carries STRIPE_*, and must not be needed to prove where it goes.
render_cloud() {
  printf 'M195_CLOUD_SENTINEL=1\n' >"${T}/flags.env.cloud"
  sed "s#infra/config/cloud/flags\.env\.cloud#${T}/flags.env.cloud#g" "${CLOUD}" >"${T}/cloud.yml"
  render "$1" -f docker-compose.yml -f "${T}/cloud.yml"
}

# static_cloud asserts `make cloud-up` turns both TS guards on for their
# readers, merges the router env maps, and hands flags.env.cloud to exactly
# the three cloud services (the guards must not widen STRIPE_* to the routers).
static_cloud() {
  local c="${T}/cloud.json" got
  guards_on "${c}"
  jq -e -n --slurpfile b "${T}/base.json" --slurpfile p "${c}" '[("storage-router", "query-router") as $s
    | ($b[0].services[$s].environment | keys) - ($p[0].services[$s].environment | keys)]
    | flatten | length == 0' >/dev/null ||
    fail "cloud overlay replaced a router's base env map (storage-router/query-router keys lost)"
  got="$(jq -r '[.services | to_entries[] | select(.value.environment.M195_CLOUD_SENTINEL != null) | .key]
    | sort | join(" ")' "${c}")"
  [ "${got}" = "data-plane-router-rust orchestrator tenant-control" ] ||
    fail "flags.env.cloud reaches '${got}', want only 'data-plane-router-rust orchestrator tenant-control' (STRIPE_* widening)"
  ok "cloud: guards =1 on storage-router/query-router only, router env maps merged, flags.env.cloud on the 3 cloud services only"
}

# static_cloud_jail asserts the cloud overlay jails the functions plane and
# renders it byte-identical to the prod overlay (the block is a copy).
static_cloud_jail() {
  static_jail "${T}/cloud.json"
  jq -e -n --slurpfile p "${T}/prod.json" --slurpfile c "${T}/cloud.json" '[("functions-runtime", "functions-relay")
    as $s | $p[0].services[$s] == $c[0].services[$s]] + [$p[0].networks["functions-jail"] == $c[0].networks["functions-jail"]]
    | all' >/dev/null || fail "cloud and prod render the functions jail differently (the two copies drifted)"
  ok "cloud: functions-runtime, functions-relay and functions-jail render identical to prod"
}

# static_kong asserts no admin port is published, the healthcheck still asks
# the proxy, and the Prometheus target still matches the status listener.
static_kong() {
  local j="${T}/prod.json"
  jq -e '[.services.kong.ports[]? | [(.target | tostring), (.published // "" | tostring)][]
    | select(. == "8001" or . == "8002" or . == "8444")] | length == 0' "${j}" >/dev/null ||
    fail "kong publishes 8001/8002/8444 under the prod overlay"
  jq -e '.services.kong.healthcheck.test | join(" ") | test("/dev/tcp/127\\.0\\.0\\.1/8000")' "${j}" >/dev/null ||
    fail "kong healthcheck no longer probes the proxy :8000 (m187 contract)"
  grep -Eq '^[[:space:]]*- targets: \["kong:8001"\]' infra/config/prometheus/prometheus.yml ||
    fail "prometheus.yml no longer scrapes kong:8001"
  expect_val "${j}" '.services.gotrue.ports // [] | length | tostring' 0
  ok "no 8001/8002/8444 publish; healthcheck probes :8000; prometheus.yml scrapes kong:8001 = status listener"
}

# static_held asserts the deferred and blocked vars are identical on every
# service with and without the overlay (a service only the overlay adds must
# carry none of them), and the overlay never names the two identity flags
# outside a comment.
static_held() {
  jq -e -n --slurpfile b "${T}/base.json" --slurpfile p "${T}/prod.json" 'def held: (.environment // {})
    | {IDENTITY_HEADER_MODE, TENANT_HEADER_IDENTITY_HMAC, SECURITY_MODE,
       REALTIME_NAMESPACE_FALLBACK, TENANT_CONTROL_VERIFY_CACHE_TTL_MS};
    [$p[0].services | to_entries[] | select((.value | held) != (($b[0].services[.key] // {}) | held))]
    | length == 0' >/dev/null ||
    fail "the overlay changed a deferred/blocked var (identity, SECURITY_MODE, realtime fallback, verify TTL)"
  jq -e '.services.realtime and .services["tenant-control"]' "${T}/prod.json" >/dev/null ||
    fail "realtime/tenant-control not rendered — the held-var check would be vacuous"
  ! grep -v '^[[:space:]]*#' "${OVERLAY}" | grep -Eq 'IDENTITY_HEADER_MODE|TENANT_HEADER_IDENTITY_HMAC' ||
    fail "${OVERLAY} sets IDENTITY_HEADER_MODE or TENANT_HEADER_IDENTITY_HMAC (no signer exists: BLOCKED)"
  ok "identity flags, SECURITY_MODE, realtime fallback, verify-cache TTL untouched on every service"
}

# static_jail_runtime asserts in rendered file $1 that functions-runtime sits
# on functions-jail alone (a real network of its own, shared only with
# functions-relay), with the Worker allowlist ON starting at the relay's Kong
# port, secrets resolved through the relay, and its base env map merged.
static_jail_runtime() {
  local f="$1" n="${1##*/}"
  jq -e '.services["functions-runtime"].networks | keys == ["functions-jail"]' "${f}" >/dev/null ||
    fail "${n}: functions-runtime is not on functions-jail alone (tenant code reaches mini-baas)"
  jq -e '(.networks["functions-jail"].external // false) == false
    and .networks["functions-jail"].name != .networks["mini-baas"].name' "${f}" >/dev/null ||
    fail "${n}: functions-jail is external or is the mini-baas network itself"
  jq -e '[.services | to_entries[] | select(.value.networks["functions-jail"] != null) | .key]
    | sort == ["functions-relay", "functions-runtime"]' "${f}" >/dev/null ||
    fail "${n}: a service other than functions-relay/functions-runtime joins functions-jail"
  jq -e '.services["functions-runtime"].networks["functions-jail"].aliases | index("functions-sandbox")' "${f}" >/dev/null ||
    fail "${n}: functions-runtime lost its functions-sandbox alias (the relay's ingress target)"
  expect_val "${f}" '.services["functions-runtime"].environment.FUNCTIONS_NET_ALLOWLIST_ENABLED' 1
  expect_val "${f}" '.services["functions-runtime"].environment.FUNCTIONS_NET_ALLOW | split(",")[0]' functions-relay:8000
  expect_val "${f}" '.services["functions-runtime"].environment.FUNCTION_SECRETS_URL' \
    http://functions-relay:3025/internal/v1/function-secrets/resolve
  jq -e -n --slurpfile b "${T}/base.json" --slurpfile p "${f}" '($b[0].services["functions-runtime"].environment | keys)
    - ($p[0].services["functions-runtime"].environment | keys) | length == 0' >/dev/null ||
    fail "${n}: overlay replaced functions-runtime's base env map"
}

# static_jail_relay asserts in rendered file $1 that functions-relay bridges
# mini-baas and functions-jail, answers as functions-runtime on mini-baas
# (alone), relays exactly the runtime, Kong's proxy and the secrets path, and
# carries no env beyond its two specs (no .env secrets).
static_jail_relay() {
  local f="$1" n="${1##*/}"
  jq -e '.services["functions-relay"].networks | keys == ["functions-jail", "mini-baas"]' "${f}" >/dev/null ||
    fail "${n}: functions-relay is not on exactly functions-jail + mini-baas"
  jq -e '[.services | to_entries[] | .key as $k | .value.networks["mini-baas"].aliases // [] | .[]
    | select(. == "functions-runtime") | $k] == ["functions-relay"]' "${f}" >/dev/null ||
    fail "${n}: the mini-baas alias functions-runtime is not held by functions-relay alone"
  expect_val "${f}" '.services["functions-relay"].environment.FUNCTIONS_RELAY_TCP | split(",") | sort | join(",")' \
    "3060=functions-sandbox:3060,8000=kong:8000"
  expect_val "${f}" '.services["functions-relay"].environment.FUNCTIONS_RELAY_HTTP' \
    "3025=http://webhook-dispatcher:3025/internal/v1/function-secrets/resolve"
  jq -e '.services["functions-relay"].environment | keys == ["FUNCTIONS_RELAY_HTTP", "FUNCTIONS_RELAY_TCP"]' "${f}" >/dev/null ||
    fail "${n}: functions-relay carries env beyond its relay specs (an env_file widens .env secrets)"
  jq -e '(.services["functions-relay"].entrypoint | index("/app/relay.ts")) and
    .services["functions-relay"].profiles == .services["functions-runtime"].profiles' "${f}" >/dev/null ||
    fail "${n}: functions-relay does not run relay.ts, or its profiles differ from functions-runtime's"
}

# static_jail asserts the functions network jail in rendered file $1.
static_jail() {
  static_jail_runtime "$1"
  static_jail_relay "$1"
  ok "${1##*/}: functions-runtime on functions-jail alone, allowlist ON (functions-relay:8000 first), relay = 3060/8000 TCP + secrets path, alias functions-runtime on the relay only"
}

# static_parity asserts the base alone keeps today's values (OFF by default).
static_parity() {
  local b="${T}/base.json" ac st gui sg ip fa
  ac="$(dotenv_get GOTRUE_MAILER_AUTOCONFIRM)"
  st="$(dotenv_get KONG_STATUS_LISTEN)"
  gui="$(dotenv_get KONG_ADMIN_GUI_LISTEN)"
  sg="$(dotenv_get STORAGE_ACTIVE_CONTENT_GUARD_ENABLED)"
  ip="$(dotenv_get AUTOMATION_WEBHOOK_IP_PIN_ENABLED)"
  fa="$(dotenv_get FUNCTIONS_NET_ALLOWLIST_ENABLED)"
  jq -e '(.services["functions-runtime"].networks | keys == ["mini-baas"]) and .services["functions-relay"] == null
    and .networks["functions-jail"] == null' "${b}" >/dev/null ||
    fail "base alone already jails functions-runtime or adds functions-relay/functions-jail (not OFF by default)"
  expect_val "${b}" '.services["functions-runtime"].environment.FUNCTIONS_NET_ALLOWLIST_ENABLED' "${fa:-<unset>}"
  expect_val "${b}" '.services.gotrue.environment.GOTRUE_MAILER_AUTOCONFIRM' "${ac:-false}"
  expect_val "${b}" '.services.gotrue.environment.GOTRUE_PASSWORD_MIN_LENGTH' 8
  expect_val "${b}" '.services.kong.environment.KONG_ADMIN_LISTEN' 0.0.0.0:8001
  expect_val "${b}" '.services.kong.environment.KONG_STATUS_LISTEN' "${st:-<unset>}"
  expect_val "${b}" '.services.kong.environment.KONG_ADMIN_GUI_LISTEN' "${gui:-<unset>}"
  expect_val "${b}" '.services["storage-router"].environment.STORAGE_ACTIVE_CONTENT_GUARD_ENABLED' "${sg:-<unset>}"
  expect_val "${b}" '.services["query-router"].environment.AUTOMATION_WEBHOOK_IP_PIN_ENABLED' "${ip:-<unset>}"
  ok "base alone: autoconfirm=${ac:-false} (from .env), min_length=8, admin 0.0.0.0:8001, no status/gui override, guards ${sg:-unset}/${ip:-unset}, functions-runtime on mini-baas (no relay, no jail), allowlist ${fa:-unset}"
}

# listener_args prints `-e KEY=VALUE` lines for Kong's listener vars in the
# rendered file $1 (the only env the throwaway containers take from it).
listener_args() {
  jq -r '.services.kong.environment | to_entries[]
    | select(.key | test("^KONG_(ADMIN|ADMIN_GUI|STATUS)_LISTEN$")) | "-e", "\(.key)=\(.value)"' "$1"
}

# start_kong runs throwaway Kong $1 on no network with the repo kong.yml
# rendered from dummy keys plus the listener args in file $2.
start_kong() {
  local -a listen
  mapfile -t listen <"$2"
  docker run -d --name "$1" --network none --memory 1g \
    -v "${ROOT}/infra/docker/services/kong/conf/kong.yml:/etc/kong/kong.yml.tmpl:ro" \
    -e KONG_DATABASE=off -e KONG_DECLARATIVE_CONFIG=/tmp/kong.yml -e KONG_HEADERS=off \
    -e KONG_NGINX_WORKER_PROCESSES=1 -e KONG_MEM_CACHE_SIZE=64m \
    -e KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES=cjson.safe "${listen[@]}" \
    --entrypoint sh "${KONG_IMG}" -ec 'sed -e "s|__KONG_PUBLIC_API_KEY__|m195-anon|g" -e "s|__KONG_SERVICE_API_KEY__|m195-service|g" \
      -e "s|__KONG_CORS_ORIGIN_[A-Z_]*__|http://localhost|g" -e "s|__JWT_SECRET__|m195-dummy-jwt-secret-m195-dummy-jwt|g" \
      -e "s|__GOTRUE_JWT_ISS__|http://localhost:8000/auth/v1|g" \
      -e "s|__KONG_ANON_UUID__|cd4f782c-ac87-5081-b322-b54834d15651|g" \
      /etc/kong/kong.yml.tmpl >/tmp/kong.yml; exec /docker-entrypoint.sh kong docker-start' \
    >/dev/null || fail "could not start throwaway kong $1"
}

# kget prints Kong $1's raw HTTP answer to GET $3 on port $2, REFUSED if no
# listener (bash /dev/tcp: the image ships no curl).
kget() {
  docker exec "$1" bash -c "exec 3<>/dev/tcp/127.0.0.1/$2 && printf 'GET $3 HTTP/1.0\r\nHost: localhost\r\n\r\n' >&3 && cat <&3" \
    2>/dev/null || printf 'REFUSED\n'
}

# kcode prints just the HTTP status of kget $1 $2 $3 (or REFUSED).
kcode() { kget "$1" "$2" "$3" | head -n1 | tr -d '\r' | awk '{ print ($1 == "REFUSED") ? "REFUSED" : $2 }'; }

# wait_proxy waits up to 60 s for Kong $1's proxy, then sends it the same
# small request mix so per-request metric series exist on both.
wait_proxy() {
  local i p
  for i in $(seq 1 60); do
    [ "$(kcode "$1" 8000 /)" = "REFUSED" ] || break
    sleep 1
  done
  [ "$(kcode "$1" 8000 /)" != "REFUSED" ] || fail "throwaway kong $1 never served :8000 ($(docker logs "$1" 2>&1 | tail -n3))"
  for p in / /rest/v1/ /auth/v1/health /query/v1/x /storage/v1/x; do kget "$1" 8000 "${p}" >/dev/null; done
}

# metric_names prints the sorted kong_* sample names Kong $1 serves on :8001.
metric_names() { kget "$1" 8001 /metrics | grep -E '^kong_' | sed -E 's/[{ ].*//' | sort -u; }

# dynamic_kong proves the prod listeners serve the same metrics as the base
# admin API while every admin surface is gone and the proxy still answers.
dynamic_kong() {
  listener_args "${T}/base.json" >"${T}/base.listen"
  listener_args "${T}/prod.json" >"${T}/prod.listen"
  start_kong "${P}-base" "${T}/base.listen"
  start_kong "${P}-prod" "${T}/prod.listen"
  wait_proxy "${P}-base"
  wait_proxy "${P}-prod"
  [ "$(kcode "${P}-base" 8001 /key-auths)" = 200 ] || fail "base admin /key-auths not 200 — the exposure check would be vacuous"
  metric_names "${P}-base" >"${T}/base.names"
  metric_names "${P}-prod" >"${T}/prod.names"
  [ -s "${T}/prod.names" ] || fail "prod :8001/metrics served no kong_* series"
  diff -q "${T}/base.names" "${T}/prod.names" >/dev/null ||
    fail "status /metrics names differ from admin /metrics: $(diff "${T}/base.names" "${T}/prod.names" | tr '\n' ' ')"
  [ "$(kcode "${P}-prod" 8001 /key-auths)" = 404 ] || fail "prod :8001/key-auths is not 404"
  [ "$(kcode "${P}-prod" 8001 /jwts)" = 404 ] || fail "prod :8001/jwts is not 404"
  [ "$(kcode "${P}-prod" 8002 /)" = REFUSED ] || fail "prod Kong Manager :8002 still listens"
  [ "$(kcode "${P}-prod" 8444 /)" = REFUSED ] || fail "prod admin TLS :8444 still listens"
  kget "${P}-prod" 8000 / | head -n1 | grep -q '^HTTP/1\.' || fail "prod proxy :8000 does not answer"
  ok "base admin /key-auths=200; prod :8001/metrics = same $(wc -l <"${T}/prod.names") kong_* names, /key-auths+/jwts 404, :8002/:8444 refused, proxy answers"
}

[ -f .env ] || fail ".env missing: compose cannot render (env_file: [.env]). Mint it: make env (CI: FORCE=1 bash scripts/env/generate-env.sh .env)"
command -v jq >/dev/null || fail "jq is required"
unset GOTRUE_MAILER_AUTOCONFIRM GOTRUE_PASSWORD_MIN_LENGTH KONG_STATUS_LISTEN KONG_ADMIN_LISTEN \
  KONG_ADMIN_GUI_LISTEN REALTIME_NAMESPACE_FALLBACK TENANT_CONTROL_VERIFY_CACHE_TTL_MS \
  IDENTITY_HEADER_MODE TENANT_HEADER_IDENTITY_HMAC SECURITY_MODE
step "render base, base+prod and base+cloud (every profile) to JSON"
render "${T}/base.json" -f docker-compose.yml
render "${T}/prod.json" -f docker-compose.yml -f "${OVERLAY}"
render_cloud "${T}/cloud.json"
ok "all three render"
step "overlay values land on the services that read them"
static_overlay
static_kong
static_guards
static_held
step "functions network jail (m197 proves it live)"
static_jail "${T}/prod.json"
step "cloud overlay (make cloud-up): guards on, flags.env.cloud not widened, functions jailed"
static_cloud
static_cloud_jail
step "parity: base alone is unchanged (OFF by default)"
static_parity
step "throwaway Kong: status listener vs admin API"
KONG_IMG="$(jq -r '.services.kong.image' "${T}/prod.json")"
docker image inspect "${KONG_IMG}" >/dev/null 2>&1 || fail "kong image ${KONG_IMG} not present locally (make build-svc-kong, or docker pull)"
dynamic_kong
printf '\033[0;32m[M195] PASS — prod overlay: signup policy on gotrue, Kong admin off with metrics intact, storage/webhook guards on their routers (prod and cloud), functions jailed behind one relay with the Worker allowlist on (prod and cloud), base unchanged\033[0m\n'
