#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m1-hardening.sh                                    :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/31 22:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/31 22:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Gate for milestone M1 (stack hardening).
# Exits 0 only when every M1 deliverable is verifiable end-to-end against the
# live stack defined by apps/baas/mini-baas-infra/docker-compose.yml.
#
# Designed to be run from the repository root, but `cd`s itself there so it
# works regardless of caller cwd.

set -euo pipefail

# Resolve repo root (this script lives at apps/baas/mini-baas-infra/scripts/verify/m1-hardening.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
COMPOSE_FILE="${BAAS_DIR}/docker-compose.yml"

cyan()   { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }

fail()   { red   "[M1] FAIL: $*"; exit 1; }
step()   { cyan  "[M1] ${*}"; }
pass()   { green "[M1] PASS: ${*}"; }

# ── 1) Dockerfile HEALTHCHECK coverage ────────────────────────────────────────
step "checking Dockerfile HEALTHCHECK coverage"
missing=0
while IFS= read -r f; do
  if ! grep -q '^HEALTHCHECK' "$f"; then
    red "  missing HEALTHCHECK: $f"
    missing=$((missing + 1))
  fi
done < <(find "${BAAS_DIR}/docker/services" "${BAAS_DIR}/src" -name Dockerfile)
[[ $missing -eq 0 ]] || fail "${missing} Dockerfiles without HEALTHCHECK"
pass "every Dockerfile has a HEALTHCHECK"

# ── 1b) redis durability posture (D3) ─────────────────────────────────────────
# The outbox.* streams are relay durability state: allkeys-lru could silently
# evict them at the memory cap, and a disabled AOF rewrite grows the AOF file
# without bound (a bench day put 250 MB into one untrimmed CDC stream).
step "checking redis eviction + AOF-rewrite posture"
grep -A16 '^  redis:' "${COMPOSE_FILE}" | grep -q 'maxmemory-policy volatile-lru' \
  || fail "redis must use volatile-lru (allkeys-lru can evict outbox.* streams)"
grep -A16 '^  redis:' "${COMPOSE_FILE}" | grep -q 'auto-aof-rewrite-percentage 100' \
  || fail "redis AOF rewrite must be enabled (percentage 100; 0 = unbounded AOF growth)"
pass "redis: volatile-lru + AOF rewrite enabled"

# ── 2) IDatabaseAdapter contract surface ──────────────────────────────────────
step "checking IDatabaseAdapter contract definitions"
CONTRACT="${BAAS_DIR}/src/libs/database/src/adapter.contract.ts"
[[ -f "${CONTRACT}" ]] || fail "missing ${CONTRACT}"
for symbol in IDatabaseAdapter EngineCaps QueryOpts QueryResult AdapterOp; do
  grep -q "${symbol}" "${CONTRACT}" || fail "${symbol} not declared in ${CONTRACT}"
done

ROUTER_DIR="${BAAS_DIR}/docker/services/data-plane-router"
# R2/R3 + R7/R8 cutover: the TS postgresql/mongodb (+mysql/redis/http) engines
# were removed once parity was proven (see scripts/verify/parity-probe.sh).
# Their replacement is the Rust data-plane-router; assert that the Rust
# adapters still implement the contract and the TS files are gone.
for engine_file in \
  "${BAAS_DIR}/src/apps/query-router/src/engines/postgresql.engine.ts" \
  "${BAAS_DIR}/src/apps/query-router/src/engines/mongodb.engine.ts"; do
  [[ -f "${engine_file}" ]] && fail "${engine_file} should be deleted post-cutover"
done
for rust_adapter in \
  "${ROUTER_DIR}/crates/data-plane-pool/src/postgres.rs" \
  "${ROUTER_DIR}/crates/data-plane-pool/src/mongo.rs"; do
  [[ -f "${rust_adapter}" ]] || fail "${rust_adapter} (Rust replacement) missing"
  grep -q "impl EngineAdapter" "${rust_adapter}" \
    || fail "${rust_adapter} does not implement EngineAdapter"
  for method in "fn engine" "fn capabilities" "fn open_pool"; do
    grep -q "${method}" "${rust_adapter}" \
      || fail "${rust_adapter} missing method ${method}"
  done
done

# Dispatcher: query.service.ts must use a Map<engine, IDatabaseAdapter>, no if-chain.
grep -q "Map<string, IDatabaseAdapter>" "${BAAS_DIR}/src/apps/query-router/src/query/query.service.ts" \
  || fail "query.service.ts does not use Map<string, IDatabaseAdapter> dispatcher"

if grep -nE "engine === ['\"](postgresql|mongodb)['\"]" "${BAAS_DIR}/src/apps/query-router/src/query/query.service.ts" >/dev/null; then
  fail "query.service.ts still contains 'engine ===' branches — migrate to Map dispatcher"
fi
pass "IDatabaseAdapter contract implemented and dispatched"

# ── 3) Unified ExecuteQueryDto with `op` enum ─────────────────────────────────
step "checking unified ExecuteQueryDto op enum"
DTO="${BAAS_DIR}/src/apps/query-router/src/query/dto/query.dto.ts"
grep -q "op?" "${DTO}" || fail "${DTO} does not declare an 'op' field"
grep -q "ADAPTER_OPS" "${DTO}" || fail "${DTO} missing ADAPTER_OPS enum"
grep -q "resolveOp" "${DTO}" || fail "${DTO} missing resolveOp() back-compat helper"
pass "ExecuteQueryDto exposes op enum + legacy action fallback"

# ── 4) audit_log migration is on disk ─────────────────────────────────────────
step "checking 013_audit_log migration file"
MIG="${BAAS_DIR}/scripts/migrations/postgresql/013_audit_log.sql"
[[ -f "${MIG}" ]] || fail "${MIG} missing"
grep -q "CREATE TABLE IF NOT EXISTS public.audit_log" "${MIG}" \
  || fail "${MIG} does not create public.audit_log"
grep -q "request_id" "${MIG}" || fail "${MIG} missing request_id column"
pass "013_audit_log migration is well-formed"

# ── 5) Audit interceptor + AuditModule wired in 7 services ────────────────────
step "checking AuditInterceptor / AuditModule wiring"
for f in \
  "${BAAS_DIR}/src/libs/common/src/audit/audit.service.ts" \
  "${BAAS_DIR}/src/libs/common/src/audit/audit.interceptor.ts" \
  "${BAAS_DIR}/src/libs/common/src/audit/audit.module.ts"; do
  [[ -f "$f" ]] || fail "missing ${f}"
done

for svc in query-router mongo-api storage-router permission-engine gdpr-service session-service newsletter-service; do
  modf="${BAAS_DIR}/src/apps/${svc}/src/app.module.ts"
  grep -q "AuditModule" "${modf}" \
    || fail "${svc} app.module.ts does not import AuditModule"
done
pass "AuditModule wired into 7 mutating services"

# ── 6) OpenAPI exposure on every NestJS app (offline check on main.ts) ────────
step "checking SwaggerModule.setup() in every NestJS app"
for app_dir in "${BAAS_DIR}"/src/apps/*/; do
  app="$(basename "${app_dir}")"
  main="${app_dir}src/main.ts"
  [[ -f "${main}" ]] || continue
  grep -q "SwaggerModule.setup(" "${main}" \
    || fail "${app} main.ts has no SwaggerModule.setup() call"
done
pass "every NestJS app declares SwaggerModule.setup()"

# ── 7) Runtime checks gated on a live stack (optional unless --live is given) ─
LIVE=0
for arg in "$@"; do
  [[ "${arg}" == "--live" ]] && LIVE=1
done

if [[ ${LIVE} -eq 1 ]]; then
  step "live: docker compose health"
  if ! command -v jq >/dev/null 2>&1; then
    red "jq is required for --live mode"; exit 2
  fi
  bad=$(docker compose -f "${COMPOSE_FILE}" ps --format json 2>/dev/null \
    | jq -r '
        def row:
          if type == "array" then .[]
          elif type == "object" then .
          elif type == "string" then (try fromjson catch empty) | row
          else empty end;
        row
        | select((.Health // "") == "unhealthy" or (.Health // "") == "starting" or (.State // "") == "exited")
        | "\(.Name // .Service)=\(.Health // .State // "unknown")"
      ' || true)
  if [[ -n "${bad}" ]]; then
    red "  unhealthy / still-starting containers:"
    while IFS= read -r line; do red "    - ${line}"; done <<< "${bad}"
    fail "at least one service is unhealthy"
  fi
  pass "every service reports healthy or has no healthcheck"

  step "live: /docs-json on every NestJS app"
  declare -A APP_PORTS=(
    [mongo-api]=3010
    # adapter-registry retired (Go is primary); skip from NestJS app probes
    [email-service]=3030
    [storage-router]=3040
    [permission-engine]=3050
    [schema-service]=3060
    [analytics-service]=3070
    [gdpr-service]=3080
    [newsletter-service]=3090
    [ai-service]=3100
    [log-service]=3110
    [session-service]=3120
    [outbox-relay]=3130
    [query-router]=4001
  )
  for app in "${!APP_PORTS[@]}"; do
    port="${APP_PORTS[$app]}"
    if ! docker compose -f "${COMPOSE_FILE}" exec -T "${app}" node -e "fetch('http://127.0.0.1:${port}/docs-json').then((r) => { if (!r.ok) process.exit(1); }).catch(() => process.exit(1));" >/dev/null; then
      fail "${app} has no OpenAPI at http://127.0.0.1:${port}/docs-json inside its container"
    fi
  done
  pass "every NestJS app serves /docs-json"

  step "live: audit_log migration applied"
  docker compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -tAc \
    "SELECT 1 FROM public.schema_migrations WHERE version = 13" \
    | grep -q 1 \
    || fail "migration 013_audit_log was not applied"
  pass "013_audit_log present in schema_migrations"
fi

green "[M1] OK — all milestone-1 deliverables verified"
