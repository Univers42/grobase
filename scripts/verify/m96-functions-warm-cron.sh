#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m96-functions-warm-cron.sh                         :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M96 — Track-A residual A2 FUNCTIONS: WARM POOL + per-invoke RESOURCE LIMIT +
# LIVE CRON, all flag-gated OFF (byte-parity with m56 today). Three net-new,
# independently-flagged behaviours on the edge-functions plane:
#
#   (1) WARM POOL  (FUNCTIONS_WARM_POOL)  — reuse a bounded ring of persistent
#       Deno workers keyed by (tenant, name) instead of spawning a worker per
#       invocation. The reuse signal is the `X-Function-Warm` response header
#       (`miss` = freshly-spawned, `hit` = served by a reused warm worker).
#   (2) RESOURCE LIMIT (FUNCTIONS_MEM_LIMIT_MB) — a runtime-controlled rss
#       watchdog (NOT user code) self-aborts an invocation that blows the cap →
#       HTTP 429 resource_limit, the runtime process is untouched. (Container
#       cgroup mem_limit/cpus is the coarse boundary; this is the fine per-invoke
#       cap.)
#   (3) LIVE CRON  (FUNCTIONS_CRON_ENABLED) — the function-scheduler's runner
#       polls due, ENABLED schedules and invokes the target function; OFF (the
#       default) starts no runner at all (CRUD still serves), so nothing fires
#       autonomously.
#
# Built ENTIRELY from CURRENT source via the REAL Dockerfiles:
#   functions-runtime → infra/docker/services/functions-runtime/Dockerfile
#   function-scheduler → src/control-plane/Dockerfile (APP=function-scheduler)
#
# ── THREE ARMS ────────────────────────────────────────────────────────────────
#   (A) POSITIVE
#       • warm pool ON: deploy echofn → invoke#1 = X-Function-Warm: miss (200),
#         invoke#2 = X-Function-Warm: hit (200) → 2nd invocation served by a
#         REUSED warm worker.
#       • live cron ON: deploy tickfn, register a `@every 2s` ENABLED schedule
#         via the scheduler CRUD → the runner FIRES it → the row's last_status
#         flips to `success` (an invocation actually happened).
#   (B) LOAD-BEARING REJECT (the limit is ENFORCED, not ignored)
#       • a hogfn that allocates past the FUNCTIONS_MEM_LIMIT_MB cap is KILLED by
#         the watchdog → HTTP 429 resource_limit (memory_limit_exceeded), and it
#         is killed FAST (well before the invoke timeout) — proving the cap, not
#         the timeout, did it.
#   (C) FLAG-OFF PARITY (byte-identical to m56 today)
#       • flags unset: the SAME echofn invoke carries NO X-Function-Warm header
#         (worker-per-invocation), the SAME hogfn is NOT killed by any watchdog
#         (no cap), and the SAME ENABLED `@every 2s` schedule NEVER fires
#         (runner not started) — last_status stays NULL.
#
# ISOLATED by design (mirrors m89/m87): scratch postgres (036 prelude) +
# functions-runtime + function-scheduler built FROM CURRENT source, ALL on a
# PRIVATE network, names suffixed with $$, an EXIT-trap removing EVERYTHING. It
# NEVER touches a mini-baas-* container/network/image/volume and NEVER edits the
# live docker-compose.yml. Fully locally runnable: throwaway containers only.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)" # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"      # apps/baas
FR_DIR="${INFRA_DIR}/infra/docker/services/functions-runtime"
GO_DIR="${INFRA_DIR}/src/control-plane"
MIGRATION_036="${INFRA_DIR}/scripts/migrations/postgresql/036_function_schedules.sql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
step() { cyan "[M96] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[M96] FAIL — $*"
  exit 1
}

PG_IMAGE="${M96_PG_IMAGE:-postgres:16-alpine}"
CURL_IMAGE="${M96_CURL_IMAGE:-curlimages/curl:8.10.1}"
FR_IMG="m96-fr-$$:scratch"
SCH_IMG="m96-sch-$$:scratch"
NET="m96net-$$"
PG="m96-pg-$$"
FR_ON="m96-fr-on-$$"     # warm pool + mem cap ENABLED
FR_OFF="m96-fr-off-$$"   # parity arm (both flags unset)
SCH_ON="m96-sch-on-$$"   # cron ENABLED
SCH_OFF="m96-sch-off-$$" # cron parity (flag unset)
PGPW="postgres"
TENANT="m96t-$$"
TOKEN="m96-strong-internal-svc-token-not-for-prod-0123456789ab"
MEM_CAP_MB="${M96_MEM_CAP_MB:-80}"
INVOKE_TIMEOUT_MS="${M96_INVOKE_TIMEOUT_MS:-8000}"
TICK_SECONDS="${M96_TICK_SECONDS:-1}"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"

cleanup() {
  docker rm -fv "${SCH_ON}" "${SCH_OFF}" "${FR_ON}" "${FR_OFF}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${FR_IMG}" "${SCH_IMG}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# curl run inside the private network; returns body+status as the caller asks.
ccurl() { docker run --rm --network "${NET}" "${CURL_IMAGE}" "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

wait_http() { # $1=container-host:port  $2=path  $3=tries
  local i
  for i in $(seq 1 "${3:-60}"); do
    ccurl -sf "http://$1$2" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}
wait_log() { # $1=container $2=needle $3=tries
  local i
  for i in $(seq 1 "${3:-60}"); do
    docker logs "$1" 2>&1 | grep -q "$2" && return 0
    docker inspect "$1" >/dev/null 2>&1 || return 1
    sleep 0.5
  done
  return 1
}

deploy_fn() { # $1=fr-container  $2=name  $3=code  → echoes HTTP code
  ccurl -s -o /dev/null -w '%{http_code}' \
    -X POST "http://$1:3060/v1/functions" \
    -H "X-Baas-Tenant-Id: ${TENANT}" -H 'Content-Type: application/json' \
    --data-binary "{\"name\":\"$2\",\"code\":$3}"
}

# Code bodies (JSON-string-encoded so the deploy body is valid JSON).
ECHO_CODE='"export default async (i)=>({status:200,body:{ok:true,echo:i.body}})"'
TICK_CODE='"export default async ()=>({status:200,body:{tick:Date.now()}})"'
# hogfn: allocate fast (8 MiB/tick) but YIELD each tick so the rss watchdog runs;
# it climbs past the cap in ~1s — far below the invoke timeout.
HOG_CODE='"export default async ()=>{const c=[];for(let t=0;t<400;t++){for(let j=0;j<8;j++)c.push(new Uint8Array(1048576));await new Promise(r=>setTimeout(r,2));}return{status:200,body:{n:c.length}};}"'

# ── 0) build BOTH images from CURRENT source via the real Dockerfiles ──────────
step "0/9 build functions-runtime + function-scheduler from CURRENT source"
DOCKER_BUILDKIT=1 docker build -q -t "${FR_IMG}" "${FR_DIR}" >/dev/null ||
  fail "functions-runtime image build failed — gate must exercise the m96 warm-pool/mem-cap code"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=function-scheduler --build-arg PORT=3027 \
  -t "${SCH_IMG}" "${GO_DIR}" >/dev/null ||
  fail "function-scheduler image build failed — gate must exercise the m96 cron-gating code"
ok "both images built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated network + postgres (036 prelude) ───────────────────────────────
step "1/9 boot isolated net (${NET}): postgres (+ 036 prelude)"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "scratch postgres never reached steady state"
  sleep 0.5
done
prelude() {
  docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
CREATE TABLE IF NOT EXISTS public.schema_migrations (version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS text
  LANGUAGE sql STABLE AS $fn$ SELECT current_setting('request.tenant_id', true) $fn$;
DO $r$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role')  THEN CREATE ROLE service_role;  END IF;
END $r$;
SQL
}
for i in $(seq 1 20); do
  prelude && break
  [[ $i -eq 20 ]] && fail "migration prelude never committed"
  sleep 0.5
done
sed '/^--/d' "${MIGRATION_036}" |
  docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null ||
  fail "real migration 036_function_schedules.sql failed to apply"
[[ "$(psql_val "SELECT to_regclass('public.function_schedules') IS NOT NULL")" == "t" ]] ||
  fail "function_schedules table missing after migration 036"
ok "postgres up, 036 applied — function_schedules exists"

# ════════════════════════════════════════════════════════════════════════════
#  (A) POSITIVE: warm pool ON + live cron ON
# ════════════════════════════════════════════════════════════════════════════

# ── 2) (A) boot functions-runtime with WARM POOL + MEM CAP ON ──────────────────
step "2/9 (A) boot functions-runtime (FUNCTIONS_WARM_POOL=1, FUNCTIONS_MEM_LIMIT_MB=${MEM_CAP_MB})"
docker run -d --name "${FR_ON}" --network "${NET}" -m 512m \
  -e FUNCTIONS_WARM_POOL=1 \
  -e FUNCTIONS_MEM_LIMIT_MB="${MEM_CAP_MB}" \
  -e FUNCTIONS_MEM_POLL_MS=10 \
  -e FUNCTIONS_INVOKE_TIMEOUT_MS="${INVOKE_TIMEOUT_MS}" \
  "${FR_IMG}" >/dev/null
wait_http "${FR_ON}:3060" "/health/live" 60 ||
  {
    docker logs "${FR_ON}" 2>&1 | tail -10
    fail "functions-runtime (warm/cap ON) never became healthy"
  }
ok "functions-runtime up with warm pool + ${MEM_CAP_MB}MB per-invoke cap"

# ── 3) (A) WARM POOL: invoke#1 = miss, invoke#2 = hit ──────────────────────────
step "3/9 (A) deploy echofn → invoke twice → 2nd served by a REUSED warm worker"
[[ "$(deploy_fn "${FR_ON}" echofn "${ECHO_CODE}")" == "201" ]] || fail "deploy echofn (ON) failed"
H1="$(ccurl -s -D - -o /dev/null -X POST "http://${FR_ON}:3060/v1/functions/echofn/invoke" \
  -H "X-Baas-Tenant-Id: ${TENANT}" -H 'Content-Type: application/json' -d '{"n":1}')"
echo "${H1}" | grep -iq 'HTTP/1.1 200' || {
  echo "${H1}"
  fail "invoke#1 not 200"
}
echo "${H1}" | grep -iq 'x-function-warm: miss' ||
  {
    echo "${H1}" | grep -i 'x-function-warm' || true
    fail "invoke#1 should be a warm MISS (freshly spawned)"
  }
H2="$(ccurl -s -D - -o /dev/null -X POST "http://${FR_ON}:3060/v1/functions/echofn/invoke" \
  -H "X-Baas-Tenant-Id: ${TENANT}" -H 'Content-Type: application/json' -d '{"n":2}')"
echo "${H2}" | grep -iq 'HTTP/1.1 200' || {
  echo "${H2}"
  fail "invoke#2 not 200"
}
echo "${H2}" | grep -iq 'x-function-warm: hit' ||
  {
    echo "${H2}" | grep -i 'x-function-warm' || true
    fail "invoke#2 should be a warm HIT (reused worker)"
  }
ok "(A) warm pool: invoke#1=miss(200), invoke#2=hit(200) — second invocation reused a warm worker"

# ── 4) (B) LOAD-BEARING REJECT: a fn over the mem cap is KILLED (429), FAST ─────
step "4/9 (B) deploy hogfn → invoke → killed by the ${MEM_CAP_MB}MB cap (429), before the timeout"
[[ "$(deploy_fn "${FR_ON}" hogfn "${HOG_CODE}")" == "201" ]] || fail "deploy hogfn (ON) failed"
T0="$(date +%s)"
HOG_OUT="$(ccurl -s -w '\n%{http_code}' -X POST "http://${FR_ON}:3060/v1/functions/hogfn/invoke" \
  -H "X-Baas-Tenant-Id: ${TENANT}" -H 'Content-Type: application/json' -d '{}')"
ELAPSED="$(($(date +%s) - T0))"
HOG_CODE_OUT="$(printf '%s' "${HOG_OUT}" | tail -1)"
HOG_BODY="$(printf '%s' "${HOG_OUT}" | sed '$d')"
[[ "${HOG_CODE_OUT}" == "429" ]] ||
  fail "hogfn should be 429 (resource_limit), got ${HOG_CODE_OUT} — cap NOT enforced: ${HOG_BODY}"
printf '%s' "${HOG_BODY}" | grep -q 'memory_limit_exceeded' ||
  fail "429 body must say memory_limit_exceeded (the watchdog killed it) — got: ${HOG_BODY}"
# Prove the CAP killed it, not the timeout: it must die well under the timeout.
[[ "${ELAPSED}" -lt "$((INVOKE_TIMEOUT_MS / 1000))" ]] ||
  fail "hogfn took ${ELAPSED}s ≈ the ${INVOKE_TIMEOUT_MS}ms timeout — the timeout, not the cap, killed it"
ok "(B) hogfn killed by the cap in ${ELAPSED}s (< $((INVOKE_TIMEOUT_MS / 1000))s timeout) → 429 memory_limit_exceeded — LIMIT ENFORCED"

# ── 5) (A) LIVE CRON: a registered @every 2s ENABLED schedule FIRES ────────────
step "5/9 (A) boot function-scheduler (FUNCTIONS_CRON_ENABLED=1, tick=${TICK_SECONDS}s) → register a schedule → it FIRES"
docker run -d --name "${SCH_ON}" --network "${NET}" \
  -e FUNCTION_SCHEDULER_HOST=0.0.0.0 -e FUNCTION_SCHEDULER_PORT=3027 \
  -e DATABASE_URL="${DB_INNET}" \
  -e FUNCTIONS_RUNTIME_URL="http://${FR_ON}:3060" \
  -e INTERNAL_SERVICE_TOKEN="${TOKEN}" \
  -e FUNCTIONS_CRON_ENABLED=1 \
  -e FUNCTION_SCHEDULER_TICK_SECONDS="${TICK_SECONDS}" \
  -e LOG_LEVEL=debug \
  "${SCH_IMG}" >/dev/null
wait_log "${SCH_ON}" "runner starting (FUNCTIONS_CRON_ENABLED=1)" 60 ||
  {
    docker logs "${SCH_ON}" 2>&1 | tail -15
    fail "cron runner never started with FUNCTIONS_CRON_ENABLED=1"
  }
[[ "$(deploy_fn "${FR_ON}" tickfn "${TICK_CODE}")" == "201" ]] || fail "deploy tickfn (ON) failed"
[[ "$(ccurl -s -o /dev/null -w '%{http_code}' -X POST "http://${SCH_ON}:3027/v1/function-schedules" \
  -H "X-Baas-Tenant-Id: ${TENANT}" -H 'Content-Type: application/json' \
  -d '{"name":"every2s","function_name":"tickfn","schedule_expr":"@every 2s","enabled":true}')" == "201" ]] ||
  fail "create cron schedule failed"
FIRED=
for i in $(seq 1 40); do
  [[ "$(psql_val "SELECT last_status FROM public.function_schedules WHERE tenant_id='${TENANT}' AND name='every2s'")" == "success" ]] &&
    {
      FIRED=1
      break
    }
  sleep 1
done
[[ -n "${FIRED}" ]] ||
  {
    docker logs "${SCH_ON}" 2>&1 | tail -15
    fail "cron schedule never fired (last_status never 'success')"
  }
LAST_RUN="$(psql_val "SELECT (last_run IS NOT NULL) FROM public.function_schedules WHERE tenant_id='${TENANT}' AND name='every2s'")"
[[ "${LAST_RUN}" == "t" ]] || fail "last_run never stamped — the runner did not actually invoke"
ok "(A) live cron: @every 2s ENABLED schedule FIRED → last_status=success, last_run stamped (an invocation happened)"

# ════════════════════════════════════════════════════════════════════════════
#  (C) FLAG-OFF PARITY: byte-identical to m56 today
# ════════════════════════════════════════════════════════════════════════════

# ── 6) (C) functions-runtime with BOTH flags UNSET ─────────────────────────────
step "6/9 (C) boot functions-runtime with FUNCTIONS_WARM_POOL + FUNCTIONS_MEM_LIMIT_MB UNSET (parity)"
docker run -d --name "${FR_OFF}" --network "${NET}" -m 512m \
  -e FUNCTIONS_INVOKE_TIMEOUT_MS="${INVOKE_TIMEOUT_MS}" \
  "${FR_IMG}" >/dev/null
wait_http "${FR_OFF}:3060" "/health/live" 60 ||
  {
    docker logs "${FR_OFF}" 2>&1 | tail -10
    fail "functions-runtime (parity) never became healthy"
  }
[[ "$(deploy_fn "${FR_OFF}" echofn "${ECHO_CODE}")" == "201" ]] || fail "deploy echofn (OFF) failed"
# No X-Function-Warm header on EITHER invoke (worker-per-invocation; byte-parity).
for n in 1 2; do
  HX="$(ccurl -s -D - -o /dev/null -X POST "http://${FR_OFF}:3060/v1/functions/echofn/invoke" \
    -H "X-Baas-Tenant-Id: ${TENANT}" -H 'Content-Type: application/json' -d "{\"n\":${n}}")"
  echo "${HX}" | grep -iq 'HTTP/1.1 200' || {
    echo "${HX}"
    fail "(C) parity invoke#${n} not 200"
  }
  echo "${HX}" | grep -iq 'x-function-warm' &&
    {
      echo "${HX}"
      fail "(C) PARITY VIOLATION: X-Function-Warm header leaked with the flag OFF"
    }
done
ok "(C) parity: no X-Function-Warm header on any invoke — worker-per-invocation, byte-identical to m56"

# ── 7) (C) the SAME hogfn is NOT killed by any watchdog (no cap) ───────────────
step "7/9 (C) the SAME hogfn under NO cap is NOT killed by a watchdog (no 429/memory_limit_exceeded)"
[[ "$(deploy_fn "${FR_OFF}" hogfn "${HOG_CODE}")" == "201" ]] || fail "deploy hogfn (OFF) failed"
HOG_OFF="$(ccurl -s -w '\n%{http_code}' -X POST "http://${FR_OFF}:3060/v1/functions/hogfn/invoke" \
  -H "X-Baas-Tenant-Id: ${TENANT}" -H 'Content-Type: application/json' -d '{}')"
HOG_OFF_CODE="$(printf '%s' "${HOG_OFF}" | tail -1)"
HOG_OFF_BODY="$(printf '%s' "${HOG_OFF}" | sed '$d')"
# With NO cap the watchdog NEVER runs: the result is NOT a 429 resource_limit and
# the body NEVER says memory_limit_exceeded. (It may 200, or 500/time out under
# its own weight — exactly today's uncapped behaviour — but our cap must be inert.)
[[ "${HOG_OFF_CODE}" != "429" ]] ||
  fail "(C) PARITY VIOLATION: hogfn got 429 with the cap flag OFF — the watchdog ran when it must not"
printf '%s' "${HOG_OFF_BODY}" | grep -q 'memory_limit_exceeded' &&
  fail "(C) PARITY VIOLATION: 'memory_limit_exceeded' with the cap flag OFF — the watchdog ran"
ok "(C) parity: uncapped hogfn produced no 429/memory_limit_exceeded (status=${HOG_OFF_CODE}) — watchdog inert, byte-parity"

# ── 8) (C) cron PARITY: FUNCTIONS_CRON_ENABLED unset → runner OFF, never fires ─
step "8/9 (C) boot function-scheduler with FUNCTIONS_CRON_ENABLED UNSET → runner DISABLED, schedule never fires"
# CRITICAL: the (A) ENABLED runner shares this postgres and scans EVERY tenant's
# due schedules (admin pool, no tenant scope) — it would fire this parity row too
# and mask the OFF arm. STOP it FIRST so only the OFF scheduler can act.
docker rm -f "${SCH_ON}" >/dev/null 2>&1 || true
# A new tenant-scoped row so the (A) row's success can't be confused with this arm.
PARITY_TENANT="m96p-$$"
docker run -d --name "${SCH_OFF}" --network "${NET}" \
  -e FUNCTION_SCHEDULER_HOST=0.0.0.0 -e FUNCTION_SCHEDULER_PORT=3027 \
  -e DATABASE_URL="${DB_INNET}" \
  -e FUNCTIONS_RUNTIME_URL="http://${FR_OFF}:3060" \
  -e INTERNAL_SERVICE_TOKEN="${TOKEN}" \
  -e FUNCTION_SCHEDULER_TICK_SECONDS="${TICK_SECONDS}" \
  -e LOG_LEVEL=debug \
  "${SCH_IMG}" >/dev/null
wait_log "${SCH_OFF}" "runner DISABLED (FUNCTIONS_CRON_ENABLED unset)" 60 ||
  {
    docker logs "${SCH_OFF}" 2>&1 | tail -15
    fail "(C) scheduler did not report runner DISABLED with the flag unset"
  }
[[ "$(deploy_fn "${FR_OFF}" tickfn "${TICK_CODE}")" == "201" ]] || fail "deploy tickfn (OFF) failed"
[[ "$(ccurl -s -o /dev/null -w '%{http_code}' -X POST "http://${SCH_OFF}:3027/v1/function-schedules" \
  -H "X-Baas-Tenant-Id: ${PARITY_TENANT}" -H 'Content-Type: application/json' \
  -d '{"name":"never","function_name":"tickfn","schedule_expr":"@every 2s","enabled":true}')" == "201" ]] ||
  fail "(C) create parity schedule failed"
# Give it generous wall-time (multiple ticks + intervals) to PROVE it never fires.
sleep "$((TICK_SECONDS * 4 + 6))"
PARITY_STATUS="$(psql_val "SELECT COALESCE(last_status,'<null>') FROM public.function_schedules WHERE tenant_id='${PARITY_TENANT}' AND name='never'")"
[[ "${PARITY_STATUS}" == "<null>" ]] ||
  {
    docker logs "${SCH_OFF}" 2>&1 | tail -10
    fail "(C) PARITY VIOLATION: an ENABLED schedule fired (last_status=${PARITY_STATUS}) with FUNCTIONS_CRON_ENABLED unset"
  }
PARITY_RUN="$(psql_val "SELECT (last_run IS NULL) FROM public.function_schedules WHERE tenant_id='${PARITY_TENANT}' AND name='never'")"
[[ "${PARITY_RUN}" == "t" ]] || fail "(C) PARITY VIOLATION: last_run was stamped with the cron flag OFF"
ok "(C) parity: runner DISABLED, the @every 2s ENABLED schedule NEVER fired — byte-identical to m56 (CRUD-only scheduler)"

# ── 9) summarize + emit the gate event via the kernel log helper (best-effort) ─
step "9/9 summarize + log GATE m96=PASS"
green "[M96] (A) POSITIVE: warm pool miss→hit (200/200) · live cron @every 2s FIRED (last_status=success)"
green "[M96] (B) REJECT:   over-cap fn KILLED in <timeout → 429 memory_limit_exceeded (limit ENFORCED)"
green "[M96] (C) PARITY:   flags unset → no warm header · watchdog inert · runner DISABLED (no fire) = byte-parity with m56"

emit_gate_log() {
  (
    set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-a2-functions-warm-cron}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m96=PASS" --outcome pass \
      --msg "A2 functions: warm pool (X-Function-Warm hit on reuse), per-invoke mem cap (over-cap fn -> 429 memory_limit_exceeded, killed before timeout), live cron (@every 2s enabled schedule fires last_status=success); all 3 flags OFF -> no warm header / watchdog inert / runner disabled = byte-parity with m56" \
      --ref "scripts/verify/m96-functions-warm-cron.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M96] ALL GATES GREEN — A2 functions warm-pool + per-invoke resource cap + live cron, flag-gated OFF = byte-parity"
exit 0
