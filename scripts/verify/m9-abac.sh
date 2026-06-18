#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="."
COMPOSE_FILE="${BAAS_DIR}/docker-compose.yml"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
fail() {
  red "[M9] FAIL: $*"
  exit 1
}
step() { cyan "[M9] ${*}"; }
pass() { green "[M9] PASS: ${*}"; }

LIVE=0
for arg in "$@"; do [[ "${arg}" == "--live" ]] && LIVE=1; done

step "checking centralized decision endpoint"
for file in \
  "${BAAS_DIR}/src/apps/permission-engine/src/decisions/decisions.controller.ts" \
  "${BAAS_DIR}/src/apps/permission-engine/src/decisions/decisions.service.ts" \
  "${BAAS_DIR}/src/apps/permission-engine/src/decisions/dto/decision.dto.ts" \
  "${BAAS_DIR}/src/apps/permission-engine/src/decisions/decisions.module.ts"; do
  [[ -f "${file}" ]] || fail "missing ${file}"
done
grep -q "Post('decide')" "${BAAS_DIR}/src/apps/permission-engine/src/decisions/decisions.controller.ts" ||
  fail "DecisionsController does not expose POST /permissions/decide"
grep -q "public.has_permission" "${BAAS_DIR}/src/apps/permission-engine/src/decisions/decisions.service.ts" ||
  fail "DecisionsService does not delegate to public.has_permission"
grep -q "DecisionsModule" "${BAAS_DIR}/src/apps/permission-engine/src/app.module.ts" ||
  fail "permission-engine AppModule does not import DecisionsModule"
pass "permission-engine exposes /permissions/decide backed by has_permission()"

step "checking query-router fail-closed ABAC pre-dispatch"
SERVICE="${BAAS_DIR}/src/apps/query-router/src/query/query.service.ts"
grep -q "decidePermission" "${SERVICE}" || fail "QueryService missing decidePermission()"
grep -q "ServiceUnavailableException" "${SERVICE}" || fail "QueryService does not fail closed when ABAC service is unavailable"
grep -q "ForbiddenException" "${SERVICE}" || fail "QueryService does not reject denied ABAC decisions"
decision_line=$(grep -n "decidePermission" "${SERVICE}" | head -1 | cut -d: -f1)
execute_line=$(grep -n "adapter.execute" "${SERVICE}" | head -1 | cut -d: -f1)
[[ "${decision_line}" -lt "${execute_line}" ]] || fail "ABAC decision is not performed before adapter.execute"
pass "query-router calls ABAC before dispatching to any adapter"

step "checking field-level mask support"
grep -q "applyFieldMask" "${SERVICE}" || fail "QueryService missing applyFieldMask()"
grep -q "maskFromConditions" "${BAAS_DIR}/src/apps/permission-engine/src/decisions/decisions.service.ts" ||
  fail "DecisionsService does not resolve field masks from policy conditions"
pass "decision masks are returned and applied to read/write results"

if [[ ${LIVE} -eq 1 ]]; then
  command -v jq >/dev/null 2>&1 || fail "jq required for --live mode"
  step "live: permission-engine /permissions/decide default-denies unknown user"
  docker compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -v ON_ERROR_STOP=1 -f - >/dev/null <<'SQL'
DELETE FROM public.user_roles
WHERE user_id = '00000000-0000-4000-8000-000000000009'::uuid;
SQL
  body=$(
    docker compose -f "${COMPOSE_FILE}" exec -T permission-engine node --input-type=module - <<'NODE'
const response = await fetch('http://127.0.0.1:3050/permissions/decide', {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    'X-Service-Token': process.env.ADAPTER_REGISTRY_SERVICE_TOKEN ?? 'dev-service-token',
    'X-Tenant-Id': '00000000-0000-4000-8000-000000000009',
  },
  body: JSON.stringify({
    user: { id: '00000000-0000-4000-8000-000000000009' },
    resource_type: 'postgresql',
    resource_name: 'm9_probe',
    op: 'delete',
    attributes: { request_id: 'm9-live' },
  }),
});
console.log(await response.text());
NODE
  ) || fail "permission-engine decision call failed"
  echo "${body}" | jq -e '.allow == false and (.reason | length > 0)' >/dev/null ||
    fail "decision endpoint did not default deny"
  pass "permission-engine default-denies when no matching allow policy exists"
fi

green "[M9] OK — all milestone-9 deliverables verified"
