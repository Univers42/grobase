#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m3-coherence.sh                                    :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/31 15:45:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/31 15:45:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
COMPOSE_FILE="${BAAS_DIR}/docker-compose.yml"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
fail()  { red   "[M3] FAIL: $*"; exit 1; }
step()  { cyan  "[M3] ${*}"; }
pass()  { green "[M3] PASS: ${*}"; }

LIVE=0
for arg in "$@"; do
  [[ "${arg}" == "--live" ]] && LIVE=1
done

step "checking outbox + unified RLS migrations"
MIG15="${BAAS_DIR}/scripts/migrations/postgresql/015_outbox_events.sql"
MIG16="${BAAS_DIR}/scripts/migrations/postgresql/016_unify_rls.sql"
[[ -f "${MIG15}" ]] || fail "missing ${MIG15}"
[[ -f "${MIG16}" ]] || fail "missing ${MIG16}"
grep -q "CREATE TABLE IF NOT EXISTS public.outbox_events" "${MIG15}" \
  || fail "015_outbox_events does not create public.outbox_events"
grep -q "outbox_pending_idx" "${MIG15}" || fail "015_outbox_events missing pending index"
grep -q "status IN ('pending', 'published', 'failed', 'dead')" "${MIG15}" \
  || fail "015_outbox_events missing status state machine"
grep -q "FUNCTION auth.current_user_id() RETURNS UUID" "${MIG16}" \
  || fail "016_unify_rls missing auth.current_user_id()"
grep -q "request.jwt.claims" "${MIG16}" || fail "016_unify_rls does not read JWT claims"
grep -q "auth.current_user_id()::text" "${MIG16}" \
  || fail "016_unify_rls does not rewrite policies to auth.current_user_id()"
pass "migrations 015 + 016 are present and well-formed"

step "checking outbox-relay service"
for file in \
  "${BAAS_DIR}/src/apps/outbox-relay/src/main.ts" \
  "${BAAS_DIR}/src/apps/outbox-relay/src/app.module.ts" \
  "${BAAS_DIR}/src/apps/outbox-relay/src/outbox-relay.service.ts" \
  "${BAAS_DIR}/src/apps/outbox-relay/tsconfig.app.json"; do
  [[ -f "${file}" ]] || fail "missing ${file}"
done
grep -q '"outbox-relay"' "${BAAS_DIR}/src/nest-cli.json" \
  || fail "outbox-relay missing from nest-cli.json"
grep -q "APP: outbox-relay" "${COMPOSE_FILE}" || fail "compose missing outbox-relay build"
grep -q "xadd" "${BAAS_DIR}/src/apps/outbox-relay/src/outbox-relay.service.ts" \
  || fail "outbox-relay does not publish to Redis Streams"
grep -q "orders_view" "${BAAS_DIR}/src/apps/outbox-relay/src/outbox-relay.service.ts" \
  || fail "outbox-relay missing Mongo orders_view projection"
grep -q "status = 'published'" "${BAAS_DIR}/src/apps/outbox-relay/src/outbox-relay.service.ts" \
  || fail "outbox-relay does not mark events published"
pass "outbox-relay polls PG, publishes Redis Streams, and projects to Mongo"

step "checking Idempotency-Key middleware"
IDEM="${BAAS_DIR}/src/libs/common/src/middleware/idempotency.middleware.ts"
[[ -f "${IDEM}" ]] || fail "missing ${IDEM}"
grep -q "IdempotencyMiddleware" "${IDEM}" || fail "middleware class missing"
grep -q "IDEMPOTENCY_REDIS_URL" "${IDEM}" || fail "middleware not backed by Redis config"
grep -q "X-Idempotency-Replayed" "${IDEM}" || fail "middleware does not mark replayed responses"
for service in query-router mongo-api storage-router; do
  grep -q "IdempotencyMiddleware" "${BAAS_DIR}/src/apps/${service}/src/app.module.ts" \
    || fail "${service} does not apply IdempotencyMiddleware"
done
pass "idempotency middleware is globally wired into mutating entrypoints"

step "checking query-router outbox helper"
[[ -f "${BAAS_DIR}/src/apps/query-router/src/query/outbox.service.ts" ]] \
  || fail "query-router outbox.service.ts missing"
grep -q "emitWithClient" "${BAAS_DIR}/src/apps/query-router/src/query/outbox.service.ts" \
  || fail "query-router outbox helper lacks transaction-client API"
grep -q "emitForQuery" "${BAAS_DIR}/src/apps/query-router/src/query/query.service.ts" \
  || fail "query.service.ts does not emit outbox rows for writes"
pass "query-router emits outbox rows for successful writes"

if [[ ${LIVE} -eq 1 ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    red "jq is required for --live mode"; exit 2
  fi

  M3_USER_ID="${M3_USER_ID:-00000000-0000-4000-8000-000000000003}"
  M3_PROBE_NAME="m3-idem-$(date +%s%N)"
  MONGO_DB_NAME="${MONGO_DB_NAME:-mini_baas}"

  # Install signed-envelope helper into the NestJS containers so the inline
  # Node test blocks can sign requests (raw X-User-Id is rejected in strict
  # mode by libs/common/src/identity).
  SIGN_HELPER="${BAAS_DIR}/scripts/verify/_signed-fetch.mjs"
  [[ -f "${SIGN_HELPER}" ]] || fail "signed-fetch helper not found at ${SIGN_HELPER}"
  # adapter-registry-go is distroless; no shell to host the helper. Copy only
  # into query-router which runs the signed Node test blocks.
  for svc in query-router; do
    docker compose -f "${COMPOSE_FILE}" cp "${SIGN_HELPER}" "${svc}:/tmp/_signed-fetch.mjs" >/dev/null \
      || fail "could not copy signed-fetch helper into ${svc}"
  done

  step "live: migrations 015 + 016 applied"
  docker compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -tAc \
    "SELECT COUNT(*) FROM public.schema_migrations WHERE version IN (15,16)" \
    | grep -q '^2$' || fail "migrations 015 and 016 are not both applied"
  pass "outbox + unified RLS migrations are applied"

  step "live: RLS policies no longer reference app.current_user_id directly"
  docker compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -tAc \
    "SELECT COUNT(*) FROM pg_policies WHERE COALESCE(qual, '') LIKE '%app.current_user_id%' OR COALESCE(with_check, '') LIKE '%app.current_user_id%'" \
    | grep -q '^0$' || fail "at least one RLS policy still references app.current_user_id directly"
  pass "runtime RLS policies use auth.current_user_id()"

  step "live: outbox-relay health"
  docker compose -f "${COMPOSE_FILE}" exec -T outbox-relay \
    wget -qO- http://127.0.0.1:3130/health/live \
    | jq -e '.status == "ok"' >/dev/null || fail "outbox-relay health probe failed"
  pass "outbox-relay is healthy"

  step "live: prepare M3 demo table"
  docker compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS public.m3_idempotency_orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id TEXT NOT NULL,
  name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.m3_idempotency_orders ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS m3_idempotency_orders_owner ON public.m3_idempotency_orders;
CREATE POLICY m3_idempotency_orders_owner ON public.m3_idempotency_orders
  FOR ALL USING (owner_id = auth.current_user_id()::text)
  WITH CHECK (owner_id = auth.current_user_id()::text);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.m3_idempotency_orders TO authenticated;
SQL
  pass "M3 idempotency demo table is ready"

  step "live: register Postgres adapter for M3 probe"
  pg_db_id=$(docker compose -f "${COMPOSE_FILE}" exec -T -e M3_USER_ID="${M3_USER_ID}" query-router node --input-type=module - <<'NODE'
const { signedFetch } = await import('file:///tmp/_signed-fetch.mjs');
const userId = process.env.M3_USER_ID;
const connectionString = process.env.DATABASE_URL;
if (!connectionString) {
  console.error('query-router DATABASE_URL is missing');
  process.exit(1);
}
const response = await signedFetch('http://adapter-registry-go:3021/databases', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    engine: 'postgresql',
    name: `m3-postgres-${Date.now()}`,
    connection_string: connectionString,
  }),
}, { userId, role: 'authenticated' });
if (!response.ok) {
  console.error(await response.text());
  process.exit(1);
}
const json = await response.json();
console.log(json.id);
NODE
  ) || fail "could not register Postgres tenant database"
  pass "Postgres adapter registered"

  step "live: Idempotency-Key deduplicates query-router writes"
  idem_result=$(docker compose -f "${COMPOSE_FILE}" exec -T \
    -e M3_USER_ID="${M3_USER_ID}" \
    -e M3_DB_ID="${pg_db_id}" \
    -e M3_PROBE_NAME="${M3_PROBE_NAME}" \
    query-router node --input-type=module - <<'NODE'
const { signedFetch } = await import('file:///tmp/_signed-fetch.mjs');
const userId = process.env.M3_USER_ID;
const dbId = process.env.M3_DB_ID;
const probeName = process.env.M3_PROBE_NAME;
const key = `m3-${Date.now()}`;
const identity = { userId, role: 'authenticated' };
const baseHeaders = {
  'Content-Type': 'application/json',
  'Idempotency-Key': key,
};
const body = JSON.stringify({ op: 'insert', data: { name: probeName } });
async function call() {
  const response = await signedFetch(`http://127.0.0.1:4001/query/${dbId}/tables/m3_idempotency_orders`, {
    method: 'POST',
    headers: baseHeaders,
    body,
  }, identity);
  const text = await response.text();
  if (!response.ok) {
    console.error(text);
    process.exit(1);
  }
  return { text, replayed: response.headers.get('x-idempotency-replayed') === 'true' };
}
const first = await call();
await new Promise((resolve) => setTimeout(resolve, 250));
const second = await call();
console.log(JSON.stringify({ same: first.text === second.text, replayed: second.replayed }));
NODE
  ) || fail "idempotency probe failed"
  echo "${idem_result}" | jq -e '.same == true and .replayed == true' >/dev/null \
    || fail "same Idempotency-Key did not replay the cached response"
  docker compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -tAc \
    "SELECT COUNT(*) FROM public.m3_idempotency_orders WHERE name = '${M3_PROBE_NAME}'" \
    | grep -q '^1$' || fail "duplicate Idempotency-Key produced more than one row"
  docker compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -tAc \
    "SELECT COUNT(*) FROM public.outbox_events WHERE aggregate = 'm3_idempotency_orders' AND event_type = 'm3_idempotency_orders.insert' AND actor_id = '${M3_USER_ID}'::uuid AND payload->'data'->>'name' = '${M3_PROBE_NAME}'" \
    | grep -q '^1$' || fail "query-router write did not create exactly one outbox event"
  pass "Idempotency-Key replayed and only one write/outbox event was created"

  step "live: PG outbox write produces Mongo projection"
  oid=$(docker compose -f "${COMPOSE_FILE}" exec -T query-router node -e "console.log(require('node:crypto').randomUUID())")
  projection_name="m3-out-$(date +%s%N)"
  docker compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -v ON_ERROR_STOP=1 <<SQL
CREATE TABLE IF NOT EXISTS public.orders (
  id UUID PRIMARY KEY,
  name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO public.orders (id, name)
VALUES ('${oid}', '${projection_name}')
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name;
INSERT INTO public.outbox_events (aggregate, aggregate_id, event_type, payload)
VALUES ('order', '${oid}', 'order.created', jsonb_build_object('name', '${projection_name}'));
SQL

  found=0
  for attempt in $(seq 1 25); do
    found=$(docker compose -f "${COMPOSE_FILE}" exec -T \
      -e MONGO_EVAL="db.getSiblingDB('${MONGO_DB_NAME}').orders_view.countDocuments({_id:'${oid}', name:'${projection_name}'})" \
      mongo sh -c 'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --quiet --eval "$MONGO_EVAL"')
    [[ "${found}" == "1" ]] && break
    sleep 0.2
  done
  [[ "${found}" == "1" ]] || fail "Mongo orders_view projection was not created"

  status=""
  for attempt in $(seq 1 25); do
    status=$(docker compose -f "${COMPOSE_FILE}" exec -T postgres \
      psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -tAc \
      "SELECT status FROM public.outbox_events WHERE aggregate = 'order' AND aggregate_id = '${oid}' ORDER BY id DESC LIMIT 1")
    [[ "${status}" == "published" ]] && break
    sleep 0.2
  done
  [[ "${status}" == "published" ]] || fail "outbox event was not marked published"
  docker compose -f "${COMPOSE_FILE}" exec -T redis redis-cli XRANGE outbox.order - + COUNT 50 \
    | grep -q "${oid}" || fail "Redis stream outbox.order does not contain the event"
  pass "PG outbox event reached Redis Streams, Mongo projection, and published status"
fi

green "[M3] OK — all milestone-3 deliverables verified"