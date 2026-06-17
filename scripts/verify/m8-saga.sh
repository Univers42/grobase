#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="."
COMPOSE_FILE="${BAAS_DIR}/docker-compose.yml"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
fail()  { red "[M8] FAIL: $*"; exit 1; }
step()  { cyan "[M8] ${*}"; }
pass()  { green "[M8] PASS: ${*}"; }

LIVE=0
for arg in "$@"; do [[ "${arg}" == "--live" ]] && LIVE=1; done

step "checking Debezium service and logical WAL"
grep -qE '^  debezium:' "${COMPOSE_FILE}" || fail "compose missing debezium service"
grep -q 'quay.io/debezium/server' "${COMPOSE_FILE}" || fail "debezium image not declared"
grep -q 'wal_level=logical' "${COMPOSE_FILE}" || fail "postgres wal_level=logical not configured"
[[ -f "${BAAS_DIR}/infra/docker/services/debezium/application.properties" ]] || fail "debezium application.properties missing"
grep -q 'debezium.sink.type=redis' "${BAAS_DIR}/infra/docker/services/debezium/application.properties" || fail "Debezium Redis sink not configured"
pass "Debezium reads public.outbox_events and publishes to Redis"

step "checking 022_outbox_saga_fields migration"
MIG="${BAAS_DIR}/scripts/migrations/postgresql/022_outbox_saga_fields.sql"
[[ -f "${MIG}" ]] || fail "missing ${MIG}"
for token in target_engine target_resource compensation_payload idempotency_key saga_state outbox_saga_target_idx; do
  grep -q "${token}" "${MIG}" || fail "022 migration missing ${token}"
done
pass "outbox_events has target, compensation, idempotency and saga state fields"

step "checking SagaCoordinator integration"
SAGA="${BAAS_DIR}/src/apps/outbox-relay/src/saga-coordinator.service.ts"
RELAY="${BAAS_DIR}/src/apps/outbox-relay/src/outbox-relay.service.ts"
[[ -f "${SAGA}" ]] || fail "missing ${SAGA}"
grep -q "class SagaCoordinatorService" "${SAGA}" || fail "SagaCoordinatorService class missing"
grep -q "dispatch(event" "${SAGA}" || fail "SagaCoordinatorService missing dispatch()"
grep -q "compensate(event" "${SAGA}" || fail "SagaCoordinatorService missing compensate()"
grep -q "saga.dispatch" "${RELAY}" || fail "outbox-relay does not dispatch saga targets"
grep -q "idempotency_key" "${RELAY}" || fail "outbox-relay does not propagate idempotency_key"
pass "outbox-relay dispatches target engines and schedules compensations"

if [[ ${LIVE} -eq 1 ]]; then
  step "live: migration 022 applied"
  sed '/^#/d' "${MIG}" | docker compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -v ON_ERROR_STOP=1 -f - >/dev/null \
    || fail "migration 022 failed"
  docker compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -tAc \
    "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='outbox_events' AND column_name IN ('target_engine','target_resource','compensation_payload','idempotency_key','saga_state')" \
    | grep -q '^5$' || fail "outbox saga columns are not present"
  pass "migration 022 columns exist"
fi

green "[M8] OK — all milestone-8 deliverables verified"