#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
COMMON_DIR="${BAAS_DIR}/src/libs/common/src"
DB_DIR="${BAAS_DIR}/src/libs/database/src"
QUERY_DIR="${BAAS_DIR}/src/apps/query-router/src"
COMPOSE_FILE="${BAAS_DIR}/docker-compose.yml"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
fail()  { red "[M11] FAIL: $*"; exit 1; }
step()  { cyan "[M11] ${*}"; }
pass()  { green "[M11] PASS: ${*}"; }

LIVE=0
for arg in "$@"; do [[ "${arg}" == "--live" ]] && LIVE=1; done

step "checking verified identity primitives"
IDENTITY="${COMMON_DIR}/identity/request-identity.ts"
TYPES="${COMMON_DIR}/interfaces/user-context.interface.ts"
[[ -f "${IDENTITY}" ]] || fail "missing ${IDENTITY}"
grep -q "VerifiedRequestIdentity" "${TYPES}" || fail "VerifiedRequestIdentity type missing"
grep -q "createHmac('sha256'" "${IDENTITY}" || fail "identity verifier must use HMAC-SHA256"
grep -q "timingSafeEqual" "${IDENTITY}" || fail "identity verifier must compare signatures safely"
grep -q "IDENTITY_HEADER_MODE" "${IDENTITY}" || fail "strict identity mode switch missing"
grep -q "Raw identity headers are not trusted in strict mode" "${IDENTITY}" || fail "strict raw-header rejection missing"
pass "common library verifies signed envelopes and rejects raw identity in strict mode"

step "checking canonical tenant/project/app identity context"
for token in \
  "X-Baas-Tenant-Id" \
  "x-baas-project-id" \
  "x-baas-app-id" \
  "x-baas-issued-at" \
  "x-baas-nonce" \
  "x-baas-signature" \
  "method=" \
  "body_sha256="; do
  grep -qi "${token}" "${IDENTITY}" || fail "identity canonicalization missing ${token}"
done
grep -q "CurrentIdentity" "${COMMON_DIR}/decorators/current-user.decorator.ts" \
  || fail "CurrentIdentity decorator missing"
pass "request identity exposes tenant/project/app and canonical HMAC fields"

step "checking guards populate req.identity before legacy req.user"
for guard in auth.guard optional-auth.guard service-token.guard; do
  grep -q "req.identity" "${COMMON_DIR}/guards/${guard}.ts" || fail "${guard}.ts does not populate req.identity"
done
grep -q "serviceIdentityFromHeaders" "${COMMON_DIR}/guards/service-token.guard.ts" \
  || fail "service token guard does not create scoped service identity"
grep -q "req.identity?.roleNames" "${COMMON_DIR}/guards/roles.guard.ts" \
  || fail "roles guard is not identity-aware"
pass "AuthGuard, OptionalAuthGuard, ServiceTokenGuard and RolesGuard use verified identity"

step "checking tenant-aware RLS settings"
POSTGRES="${DB_DIR}/postgres/postgres.service.ts"
# R2+R7+R8 cutover: the TS postgresql.engine.ts was deleted once parity was
# proven. The tenant-GUC contract now lives in the Rust pool adapter.
PG_ENGINE_RS="${BAAS_DIR}/docker/services/data-plane-router/crates/data-plane-pool/src/postgres.rs"
RLS_MIGRATION="${BAAS_DIR}/scripts/migrations/postgresql/016_unify_rls.sql"
grep -q "app.current_tenant_id" "${POSTGRES}" || fail "PostgresService tenantQuery must set app.current_tenant_id"
grep -q "app.current_tenant_id" "${PG_ENGINE_RS}" \
  || fail "Rust PostgresPool adapter must set app.current_tenant_id"
grep -q "tenant_id" "${POSTGRES}" || fail "PostgresService claims must include tenant_id"
grep -q "tenant_id" "${PG_ENGINE_RS}" \
  || fail "Rust PostgresPool adapter must include tenant_id in claims"
grep -q "auth.current_tenant_id" "${RLS_MIGRATION}" || fail "RLS migration must define auth.current_tenant_id"
pass "Postgres helpers set both tenant and user RLS settings (Rust adapter parity)"

step "checking query-router propagates verified tenant context"
QUERY_CONTROLLER="${QUERY_DIR}/query/query.controller.ts"
QUERY_SERVICE="${QUERY_DIR}/query/query.service.ts"
grep -q "CurrentIdentity" "${QUERY_CONTROLLER}" || fail "QueryController must consume CurrentIdentity"
grep -q "tenant_id" "${QUERY_SERVICE}" || fail "QueryService permission payload must include tenant_id"
grep -q "project_id" "${QUERY_SERVICE}" || fail "QueryService permission payload must include project_id"
grep -q "tenantId" "${QUERY_SERVICE}" || fail "QueryService must route registry calls by verified tenantId"
pass "query-router carries verified tenant/project/app context into registry, ABAC and adapters"

step "checking runtime wiring remains opt-in compatible"
grep -q "JWT_SECRET" "${COMPOSE_FILE}" || fail "compose must still propagate JWT_SECRET for legacy JWT validation chain"
grep -q "pre-function" "${BAAS_DIR}/docker/services/kong/conf/kong.yml" || fail "Kong identity pre-function missing"
pass "gateway path remains present while strict upstream verification can be enabled"

step "checking signed envelope positive and forged-header negative paths"
(cd "${BAAS_DIR}/src" && npx ts-node -r tsconfig-paths/register --transpile-only <<'TS'
import { createHmac } from 'node:crypto';
import { canonicalIdentityString, resolveRequestIdentity, type VerifiedRequestIdentity } from '@mini-baas/common';

process.env['IDENTITY_HEADER_MODE'] = 'strict';
process.env['INTERNAL_IDENTITY_HMAC_KEYS'] = 'm11-secret:super-secret';
process.env['INTERNAL_IDENTITY_MAX_SKEW_MS'] = '60000';

const issuedAt = String(Date.now());
const identity: VerifiedRequestIdentity = {
  tenantId: '00000000-0000-4000-8000-000000000111',
  projectId: '00000000-0000-4000-8000-000000000222',
  appId: 'm11-app',
  userId: '00000000-0000-4000-8000-000000000333',
  role: 'authenticated',
  roleNames: ['authenticated'],
  scopes: ['database:read'],
  authMethod: 'kong-hmac',
};
const req = {
  method: 'POST',
  url: '/query/00000000-0000-4000-8000-000000000444/tables/orders',
  originalUrl: '/query/00000000-0000-4000-8000-000000000444/tables/orders',
  headers: {
    'x-baas-tenant-id': identity.tenantId,
    'x-baas-project-id': identity.projectId,
    'x-baas-app-id': identity.appId,
    'x-baas-user-id': identity.userId,
    'x-baas-role': identity.role,
    'x-baas-scopes': identity.scopes.join(','),
    'x-baas-issued-at': issuedAt,
    'x-baas-nonce': 'm11-nonce',
    'x-baas-key-id': 'm11-secret',
  },
};
const canonical = canonicalIdentityString(req, identity, issuedAt, 'm11-nonce');
req.headers['x-baas-signature'] = `v1=${createHmac('sha256', 'super-secret').update(canonical).digest('hex')}`;
const resolved = resolveRequestIdentity(req, true);
if (resolved?.tenantId !== identity.tenantId || resolved.projectId !== identity.projectId) {
  throw new Error('signed identity did not resolve to expected tenant/project');
}

try {
  resolveRequestIdentity({ method: 'GET', url: '/query/x/tables', originalUrl: '/query/x/tables', headers: { 'x-user-id': 'victim' } }, true);
  throw new Error('forged raw X-User-Id was accepted in strict mode');
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  if (!message.includes('Raw identity headers are not trusted')) throw error;
}
TS
)
pass "signed envelopes are accepted and forged raw identity is rejected in strict mode"

step "checking TypeScript compiles"
(cd "${BAAS_DIR}/src" && npx tsc --noEmit -p tsconfig.json)
pass "TypeScript typecheck passed"

if [[ ${LIVE} -eq 1 ]]; then
  command -v docker >/dev/null 2>&1 || fail "docker required for --live mode"
  command -v curl >/dev/null 2>&1 || fail "curl required for --live mode"
  step "live: strict-mode negative test requires the running query-router to use IDENTITY_HEADER_MODE=strict"
  status=$(curl -sS -o /dev/null -w '%{http_code}' \
    -H 'X-User-Id: 00000000-0000-4000-8000-000000000011' \
    "http://127.0.0.1:${QUERY_ROUTER_PORT:-4001}/query/00000000-0000-4000-8000-000000000444/tables" || true)
  [[ "${status}" == "401" || "${status}" == "403" ]] \
    || fail "expected strict query-router to reject forged header with 401/403, got ${status:-empty}; start it with IDENTITY_HEADER_MODE=strict"
  pass "strict live query-router rejects raw X-User-Id"
fi

green "[M11] OK - trust boundary scaffold verified"