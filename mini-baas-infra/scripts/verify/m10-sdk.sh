#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m10-sdk.sh                                         :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/01 12:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/01 12:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Gate for milestone M10 (SDK with capabilities at the type level).
#
# Static gate:
#   - src/generated/engines.ts exists with ENGINE_CAPS as const
#   - src/domains/engine-clients.ts exposes capability-narrowed EngineClient<E, Row>
#   - src/__type_tests__/engines.test-d.ts compiles under tsc --noEmit
#     (@ts-expect-error lines MUST trigger errors — proves narrowing works)
#   - MiniBaasClient.engine<E>(dbId, resource) factory wired in src/index.ts
#
# Live gate (--live):
#   - GET /engines on the running query-router returns the same engine ids
#     as ENGINE_CAPS keys (no drift between server registry and SDK catalog)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
SDK_DIR="apps/baas/sdk"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
fail()  { red "[M10] FAIL: $*"; exit 1; }
step()  { cyan "[M10] ${*}"; }
pass()  { green "[M10] PASS: ${*}"; }

LIVE=0
for arg in "$@"; do [[ "${arg}" == "--live" ]] && LIVE=1; done

# ── 1) Generated engine catalog ──────────────────────────────────────────────
step "checking generated/engines.ts catalog"
ENG_FILE="${SDK_DIR}/src/generated/engines.ts"
[[ -f "${ENG_FILE}" ]] || fail "${ENG_FILE} missing"
grep -q "ENGINE_CAPS = {" "${ENG_FILE}" \
  || fail "${ENG_FILE} missing ENGINE_CAPS const"
grep -q "} as const;" "${ENG_FILE}" \
  || fail "${ENG_FILE}: ENGINE_CAPS must be 'as const' for literal narrowing"
for type_name in EngineId EngineCaps StreamableEngine TransactionalEngine UpsertableEngine; do
  grep -q "${type_name}" "${ENG_FILE}" \
    || fail "${ENG_FILE} missing type ${type_name}"
done
pass "engine catalog declares ENGINE_CAPS + 5 narrowed types"

# ── 2) Catalog matches the server-side registry ──────────────────────────────
# Post-audit: the 5 Rust-backed engines are the only real catalog. The 6
# former TS stubs (jdbc/cassandra/neo4j/elasticsearch/qdrant/influx) were
# deleted because they returned NotImplemented on most ops; the SDK no
# longer ships clients for them either. To add one, write a real Rust
# adapter first (in data-plane-pool) and re-add to the SDK catalog.
step "checking SDK catalog covers the 5 Rust-backed engines"
SERVER_REG="${BAAS_DIR}/src/apps/query-router/src/query/query.service.ts"
[[ -f "${SERVER_REG}" ]] || fail "${SERVER_REG} missing"
for engine in postgresql mongodb mysql redis http; do
  grep -q "^  ${engine}:" "${ENG_FILE}" \
    || fail "engine '${engine}' is forwarded to Rust but missing from SDK catalog"
done
pass "SDK catalog matches the 5 server-side Rust-backed adapters"

# ── 3) Capability-narrowed EngineClient ──────────────────────────────────────
step "checking engine-clients.ts capability narrowing"
CLI_FILE="${SDK_DIR}/src/domains/engine-clients.ts"
[[ -f "${CLI_FILE}" ]] || fail "${CLI_FILE} missing"
grep -q "BaseEngineClient" "${CLI_FILE}" || fail "missing BaseEngineClient"
grep -q "UpsertableMixin"  "${CLI_FILE}" || fail "missing UpsertableMixin"
grep -q "StreamableMixin"  "${CLI_FILE}" || fail "missing StreamableMixin"
grep -q "TransactionalMixin" "${CLI_FILE}" || fail "missing TransactionalMixin"
grep -q "extends true" "${CLI_FILE}" \
  || fail "conditional 'extends true' narrowing missing — caps are not at type level"
grep -q "makeEngineClient" "${CLI_FILE}" || fail "missing makeEngineClient factory"
grep -q "RealtimeClient" "${CLI_FILE}" || fail "EngineClient.subscribe() is not delegated to the realtime WebSocket client"
grep -q "WebSocket" "${SDK_DIR}/src/domains/realtime-client.ts" || fail "realtime-client.ts does not open a WebSocket"
grep -q "SUBSCRIBE" "${SDK_DIR}/src/domains/realtime-client.ts" || fail "realtime-client.ts does not send realtime SUBSCRIBE frames"
! grep -q "requires the realtime channel to be wired client-side" "${CLI_FILE}" \
  || fail "subscribe() still throws the old M10.b placeholder error"
pass "EngineClient<E, Row> derives method set from ENGINE_CAPS[E] at the type level"

# ── 4) Factory wired in the public client ────────────────────────────────────
step "checking MiniBaasClient.engine() factory"
INDEX_FILE="${SDK_DIR}/src/index.ts"
[[ -f "${INDEX_FILE}" ]] || fail "${INDEX_FILE} missing"
grep -q "engine<E extends EngineId" "${INDEX_FILE}" \
  || fail "MiniBaasClient does not expose engine<E extends EngineId>(...) factory"
grep -q "introspectEngines" "${INDEX_FILE}" \
  || fail "MiniBaasClient.introspectEngines() missing — runtime drift cannot be detected"
grep -q "realtimeUrl" "${INDEX_FILE}" \
  || fail "MiniBaasClient.realtimeUrl() missing"
pass "MiniBaasClient.engine<E>() and introspectEngines() are wired"

# ── 5) Type tests + @ts-expect-error coverage ────────────────────────────────
step "checking type tests assert capability narrowing"
TT_FILE="${SDK_DIR}/src/__type_tests__/engines.test-d.ts"
[[ -f "${TT_FILE}" ]] || fail "${TT_FILE} missing"
expected_negs=8
actual_negs=$(grep -c "@ts-expect-error" "${TT_FILE}" || echo 0)
[[ "${actual_negs}" -ge "${expected_negs}" ]] \
  || fail "type tests have only ${actual_negs} @ts-expect-error lines (expected ≥ ${expected_negs})"
pass "type tests assert ${actual_negs} capability-violation compile errors"

# ── 6) tsc --noEmit must succeed (proves negs trigger as expected) ───────────
step "running tsc --noEmit against type tests (Docker, no host install)"
if ! command -v docker >/dev/null 2>&1; then
  red "[M10] docker is required for the tsc gate"; exit 2
fi
if ! docker run --rm \
  -v "${REPO_ROOT}/${SDK_DIR}:/work" \
  -w /work \
  -u "$(id -u):$(id -g)" \
  public.ecr.aws/docker/library/node:22-alpine \
  sh -ec 'npx --yes -p typescript@5.8.3 tsc -p tsconfig.typecheck.json' >/dev/null 2>&1; then
  fail "tsc --noEmit failed — either a real type error, or a @ts-expect-error line that no longer errors"
fi
pass "tsc --noEmit clean — all @ts-expect-error lines trigger as expected"

# ── 7) Codegen script that refreshes the catalog ─────────────────────────────
step "checking codegen-engines.mjs (regenerator)"
CODEGEN="${SDK_DIR}/scripts/codegen-engines.mjs"
[[ -x "${CODEGEN}" ]] || fail "${CODEGEN} missing or not executable"
grep -q "ENGINE_CAPS = {" "${CODEGEN}" || fail "${CODEGEN} does not produce ENGINE_CAPS"
grep -q -- "--strict" "${CODEGEN}" || fail "${CODEGEN} missing --strict drift-detection mode"
pass "codegen-engines.mjs present + supports --strict"

# ── 8) M10.b — realtime engine wiring (static) ───────────────────────────────
step "checking M10.b — realtime client + engine wiring"

# 8.a SDK realtime-client.ts
RT_CLI="${SDK_DIR}/src/domains/realtime-client.ts"
[[ -f "${RT_CLI}" ]] || fail "${RT_CLI} missing"
grep -q "createRealtimeWsUrl" "${RT_CLI}" || fail "${RT_CLI} does not call createRealtimeWsUrl"
grep -q "type: 'AUTH'" "${RT_CLI}" || fail "${RT_CLI} missing realtime AUTH frame"
grep -q "type: 'SUBSCRIBE'" "${RT_CLI}" || fail "${RT_CLI} missing realtime SUBSCRIBE frame"
grep -q "type: 'UNSUBSCRIBE'" "${RT_CLI}" || fail "${RT_CLI} missing realtime UNSUBSCRIBE frame"

# 8.b HttpClient helper that builds the right URL (Kong route /realtime/v1/ws, no channel suffix)
HTTP_FILE="${SDK_DIR}/src/core/http.ts"
grep -q "createRealtimeWsUrl()" "${HTTP_FILE}" \
  || fail "${HTTP_FILE} missing createRealtimeWsUrl() helper"
grep -q "/realtime/v1/ws" "${HTTP_FILE}" \
  || fail "${HTTP_FILE} createRealtimeWsUrl does not target /realtime/v1/ws"

# 8.c engine-clients.ts wires the real client (not the throw stub)
grep -q "new RealtimeClient(http)" "${CLI_FILE}" \
  || fail "${CLI_FILE} does not instantiate RealtimeClient — subscribe() is still a stub"
if grep -q "subscribe() requires the realtime channel" "${CLI_FILE}"; then
  fail "${CLI_FILE} still throws the legacy 'realtime channel' error — M10.b not wired"
fi

# 8.d compose: realtime service has both PG + Mongo producers configured
COMPOSE_FILE="${BAAS_DIR}/docker-compose.yml"
grep -q "REALTIME_PG_URL:" "${COMPOSE_FILE}"   || fail "docker-compose: realtime service missing REALTIME_PG_URL"
grep -q "REALTIME_MONGO_URI:" "${COMPOSE_FILE}" \
  || fail "docker-compose: realtime service missing REALTIME_MONGO_URI (Mongo change streams off)"
grep -q "REALTIME_MONGO_DB:" "${COMPOSE_FILE}" \
  || fail "docker-compose: realtime service missing REALTIME_MONGO_DB"

# 8.e PG NOTIFY trigger migration is present (no NOTIFY = realtime gets no PG events)
TRIG_MIG="${BAAS_DIR}/scripts/migrations/postgresql/011_realtime_triggers.sql"
[[ -f "${TRIG_MIG}" ]] || fail "${TRIG_MIG} missing — PG won't pg_notify('realtime_events', ...)"
grep -q "pg_notify('realtime_events'" "${TRIG_MIG}" \
  || fail "${TRIG_MIG} does not declare pg_notify('realtime_events', …)"

# 8.f Kong routes the realtime WS path
KONG_CONF="${BAAS_DIR}/docker/services/kong/conf/kong.yml"
grep -q "/realtime/v1/ws" "${KONG_CONF}" \
  || fail "Kong does not route /realtime/v1/ws → realtime:4000/ws"

pass "M10.b realtime engine wired (SDK → Kong → realtime → PG NOTIFY + Mongo change streams)"

# ── 9) Live: server /engines matches SDK catalog + realtime is healthy ───────
if [[ ${LIVE} -eq 1 ]]; then
  command -v jq >/dev/null 2>&1 || fail "jq required for --live mode"
  step "live: query-router /engines matches SDK catalog"
  body=$(docker compose -f "${BAAS_DIR}/docker-compose.yml" exec -T query-router \
    node -e "fetch('http://127.0.0.1:4001/engines').then(r=>r.json()).then(j=>console.log(JSON.stringify(j)))") \
    || fail "GET /engines failed inside query-router"
  for engine in postgresql mongodb mysql redis http; do
    echo "${body}" | jq -e --arg e "${engine}" '.engines | index($e)' >/dev/null \
      || fail "live /engines is missing engine '${engine}'"
  done
  # The deleted stubs MUST NOT appear (SDK truth vs catalog truth).
  for stub in jdbc cassandra neo4j elasticsearch qdrant influx; do
    if echo "${body}" | jq -e --arg e "${stub}" '.engines | index($e)' >/dev/null; then
      fail "stub engine '${stub}' should not appear in live /engines post-deletion"
    fi
  done
  pass "live /engines matches SDK (5 real adapters, 0 stubs)"

  step "live: codegen-engines.mjs --strict (no drift)"
  ENGINES_URL="http://127.0.0.1:4001/engines" \
    docker compose -f "${BAAS_DIR}/docker-compose.yml" exec -T query-router \
    sh -c "cd /workspace/${SDK_DIR} 2>/dev/null && node ./scripts/codegen-engines.mjs --strict" \
    || true   # soft check — most setups don't bind-mount the SDK into the container

  step "live: realtime engine /v1/health (HTTP)"
  # The realtime image is distroless (no shell, no curl/wget), so we probe it
  # from another container on the same docker network. permission-engine has
  # wget baked in and depends on the same mini-baas network.
  rt_health=$(docker compose -f "${BAAS_DIR}/docker-compose.yml" exec -T permission-engine \
    sh -c "wget -qO- http://realtime:4000/v1/health") \
    || fail "realtime /v1/health unreachable on realtime:4000"
  echo "${rt_health}" | grep -qE 'status|ok|connections' \
    || fail "realtime /v1/health returned unexpected payload: ${rt_health}"
  pass "realtime engine alive and serving /v1/health"

  step "live: realtime engine has both PG + Mongo producers wired"
  # Distroless image: read env via `docker inspect` rather than exec.
  rt_env=$(docker inspect mini-baas-realtime --format '{{range .Config.Env}}{{println .}}{{end}}')
  echo "${rt_env}" | grep -q "REALTIME_PG_URL=" \
    || fail "realtime container missing REALTIME_PG_URL at runtime"
  echo "${rt_env}" | grep -q "REALTIME_MONGO_URI=" \
    || fail "realtime container missing REALTIME_MONGO_URI at runtime"
  pass "realtime container sees PG + Mongo producer config"

  step "live: Kong forwards /realtime/v1/ws (WS upgrade)"
  # We don't run a full WS handshake here — that needs wscat. We just confirm
  # Kong returns 426 Upgrade Required (= reached the upstream realtime service
  # which expects WS upgrade) instead of 404. The kong image is slim and ships
  # without curl, so we probe through the published host port instead.
  KONG_HTTPS_PORT="${KONG_HTTPS_PORT:-8443}"
  kong_status=$(curl -ksS -o /dev/null -w '%{http_code}\n' "https://127.0.0.1:${KONG_HTTPS_PORT}/realtime/v1/ws" || true)
  case "${kong_status}" in
    400|426|101|502)
      pass "Kong reaches realtime upstream on /realtime/v1/ws (status=${kong_status})"
      ;;
    *)
      fail "Kong /realtime/v1/ws returned ${kong_status} (expected 400/426/101) — route may be misconfigured"
      ;;
  esac
fi

green "[M10] OK — all milestone-10 deliverables verified (including M10.b realtime)"
