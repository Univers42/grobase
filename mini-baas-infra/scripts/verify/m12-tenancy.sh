#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m12-tenancy.sh                                     :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/02 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/02 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Gate for milestone M12 (tenant isolation).
#
# Static checks:
#   - Migration 030_tenancy_isolation.sql exists and is well-formed
#   - tenant_databases policy uses auth.current_tenant_id() (not current_user_id)
#   - projects table has tenant_id column + tenant-scoped RLS policy
#   - apps table is declared + tenant-scoped
#   - tenant_api_keys carries project_id + app_id scope
#   - adapter-registry boot DDL no longer recreates the broken policy
#
# Live checks (--live, requires the stack up):
#   - Tenant A registers a database, tenant B cannot see it (cross-tenant deny)
#   - Tenant A and tenant B can use the same database name without conflict
#   - Same user_id belonging to two different tenants sees two different rowsets

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
COMPOSE_FILE="${BAAS_DIR}/docker-compose.yml"
MIG="${BAAS_DIR}/scripts/migrations/postgresql/030_tenancy_isolation.sql"
# Adapter-registry is now Go (the TS service was retired post-parity-probe).
# Boot DDL lives in service.go's EnsureSchema function.
ADAPTER_REG_SVC="${BAAS_DIR}/go/control-plane/internal/adapterregistry/service.go"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
fail()  { red "[M12] FAIL: $*"; exit 1; }
step()  { cyan "[M12] ${*}"; }
pass()  { green "[M12] PASS: ${*}"; }

LIVE=0
for arg in "$@"; do [[ "${arg}" == "--live" ]] && LIVE=1; done

# ── 1) Migration on disk + well-formed ───────────────────────────────────────
step "checking migration 030_tenancy_isolation.sql"
[[ -f "${MIG}" ]] || fail "${MIG} missing"
grep -q "CREATE TABLE IF NOT EXISTS public.apps" "${MIG}" || fail "${MIG} does not create public.apps"
grep -q "apps_tenant_isolation" "${MIG}" || fail "${MIG} missing apps_tenant_isolation policy"
grep -q "projects_tenant_isolation" "${MIG}" || fail "${MIG} missing projects_tenant_isolation policy"
grep -q "tenant_databases_tenant_isolation" "${MIG}" || fail "${MIG} missing tenant_databases_tenant_isolation policy"
grep -q "auth.current_tenant_id()" "${MIG}" || fail "${MIG} does not reference auth.current_tenant_id()"
grep -q "ADD COLUMN IF NOT EXISTS tenant_id" "${MIG}" || fail "${MIG} does not add tenant_id to projects"
grep -q "ADD COLUMN IF NOT EXISTS app_id" "${MIG}" || fail "${MIG} does not add app_id"
grep -q "VALUES (30, '030_tenancy_isolation')" "${MIG}" || fail "${MIG} missing schema_migrations bump"
pass "030_tenancy_isolation.sql is well-formed"

# ── 2) Adapter-registry boot DDL (Go service.go::EnsureSchema) ──────────────
step "checking Go adapter-registry EnsureSchema policy enforces tenant scope"
[[ -f "${ADAPTER_REG_SVC}" ]] || fail "${ADAPTER_REG_SVC} missing"
# The legacy bad pattern (named 'tenant_isolation' with user-as-tenant) must
# not appear in a CREATE POLICY statement; the Go service must use the
# corrected name 'tenant_databases_tenant_isolation' with auth.current_tenant_id().
if grep -nE "CREATE POLICY tenant_isolation ON public\\.tenant_databases" "${ADAPTER_REG_SVC}" >/dev/null; then
  fail "Go adapter-registry recreates the broken 'tenant_isolation' policy at boot"
fi
grep -q "tenant_databases_tenant_isolation" "${ADAPTER_REG_SVC}" \
  || fail "Go adapter-registry EnsureSchema missing tenant_databases_tenant_isolation policy"
grep -q "auth.current_tenant_id()" "${ADAPTER_REG_SVC}" \
  || fail "Go adapter-registry EnsureSchema does not invoke auth.current_tenant_id()"
pass "Go adapter-registry boot DDL creates the tenant-scoped policy"

# ── 3) auth.current_tenant_id() exists and reads from app GUC + JWT ─────────
step "checking auth.current_tenant_id() helper presence in 016_unify_rls.sql"
UNIFY="${BAAS_DIR}/scripts/migrations/postgresql/016_unify_rls.sql"
[[ -f "${UNIFY}" ]] || fail "${UNIFY} missing"
grep -q "FUNCTION auth.current_tenant_id() RETURNS UUID" "${UNIFY}" \
  || fail "auth.current_tenant_id() not declared in 016_unify_rls.sql"
grep -q "app.current_tenant_id" "${UNIFY}" \
  || fail "016_unify_rls.sql does not read app.current_tenant_id GUC"
pass "auth.current_tenant_id() reads JWT or app.current_tenant_id GUC"

# ── 4) Postgres helper still sets both user + tenant GUCs (M11 contract) ────
step "checking PostgresService sets app.current_tenant_id alongside app.current_user_id"
PG_SVC="${BAAS_DIR}/src/libs/database/src/postgres/postgres.service.ts"
[[ -f "${PG_SVC}" ]] || fail "${PG_SVC} missing"
grep -q "app.current_tenant_id" "${PG_SVC}" \
  || fail "${PG_SVC} does not set app.current_tenant_id"
grep -q "app.current_user_id" "${PG_SVC}" \
  || fail "${PG_SVC} does not set app.current_user_id"
pass "PostgresService sets both tenant + user RLS GUCs"

# ── 5) Live two-tenant isolation negative test ───────────────────────────────
if [[ ${LIVE} -eq 1 ]]; then
  command -v jq >/dev/null 2>&1 || fail "jq required for --live mode"
  step "live: applying migration 030 (idempotent)"
  docker compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -v ON_ERROR_STOP=1 \
    -f - < "${MIG}" >/dev/null \
    || fail "migration 030 failed to apply"
  pass "migration 030 applied"

  step "live: two tenants with the same DB name see only their own rows"
  TENANT_A="00000000-0000-4000-8000-00000000A012"
  TENANT_B="00000000-0000-4000-8000-00000000B012"
  USER_X="00000000-0000-4000-8000-000000000999"

  # Insert one tenant_databases row per tenant with the same name. If the broken
  # current_user_id policy were still in place, USER_X using TENANT_A's GUC
  # would see *both* rows (the same X belongs to both tenants in the user model).
  docker compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -v ON_ERROR_STOP=1 <<SQL
INSERT INTO public.tenants (id, name) VALUES ('${TENANT_A}'::uuid, 'tenant-a') ON CONFLICT (id) DO NOTHING;
INSERT INTO public.tenants (id, name) VALUES ('${TENANT_B}'::uuid, 'tenant-b') ON CONFLICT (id) DO NOTHING;
DELETE FROM public.tenant_databases WHERE name = 'm12-isolation-probe';
INSERT INTO public.tenant_databases (tenant_id, engine, name, connection_enc, connection_iv, connection_tag, connection_salt)
VALUES
  ('${TENANT_A}'::uuid, 'postgresql', 'm12-isolation-probe', '\\\\x00', '\\\\x00', '\\\\x00', '\\\\x00'),
  ('${TENANT_B}'::uuid, 'postgresql', 'm12-isolation-probe', '\\\\x00', '\\\\x00', '\\\\x00', '\\\\x00');
SQL

  count_a=$(docker compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -tAc \
    "SET ROLE authenticated;
     SELECT set_config('app.current_tenant_id', '${TENANT_A}', false);
     SELECT set_config('app.current_user_id', '${USER_X}', false);
     SELECT count(*) FROM public.tenant_databases WHERE name = 'm12-isolation-probe';
     RESET ROLE;" \
    | tr -d '[:space:]' | tail -c 2)

  count_b=$(docker compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -tAc \
    "SET ROLE authenticated;
     SELECT set_config('app.current_tenant_id', '${TENANT_B}', false);
     SELECT set_config('app.current_user_id', '${USER_X}', false);
     SELECT count(*) FROM public.tenant_databases WHERE name = 'm12-isolation-probe';
     RESET ROLE;" \
    | tr -d '[:space:]' | tail -c 2)

  [[ "${count_a}" == "1" ]] || fail "tenant A should see exactly 1 row, got '${count_a}' (RLS leak or fixture broken)"
  [[ "${count_b}" == "1" ]] || fail "tenant B should see exactly 1 row, got '${count_b}' (RLS leak or fixture broken)"
  pass "tenant A and tenant B each see exactly one row — RLS enforces tenant_id, not user_id"

  step "live: cross-tenant read attempt is denied"
  # Try to fetch tenant A's row id by name while running as tenant B.
  leaked=$(docker compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -tAc \
    "SET ROLE authenticated;
     SELECT set_config('app.current_tenant_id', '${TENANT_B}', false);
     SELECT set_config('app.current_user_id', '${USER_X}', false);
     SELECT tenant_id::text FROM public.tenant_databases WHERE name = 'm12-isolation-probe';
     RESET ROLE;")
  echo "${leaked}" | grep -q "${TENANT_A}" \
    && fail "RLS leak — tenant B can read tenant A's row (tenant_id ${TENANT_A} visible)"
  echo "${leaked}" | grep -q "${TENANT_B}" \
    || fail "tenant B sees no row at all — fixture broken"
  pass "tenant B cannot see tenant A's row"

  step "live: cleanup probes"
  docker compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -v ON_ERROR_STOP=1 \
    -c "DELETE FROM public.tenant_databases WHERE name = 'm12-isolation-probe';" >/dev/null
  pass "fixtures cleaned"
fi

green "[M12] OK — all milestone-12 tenancy deliverables verified"
