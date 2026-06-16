#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m22-live-database.sh                               :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/09 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/09 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Gate for milestone M22 (live-database mode), steps 1+2: engine-agnostic
# schema introspection AND schema DDL.
#
# Static checks (step 1 — introspection):
#   - data-plane-core declares SchemaDescriptor + NormalizedType (the FIXED
#     wire contract) and the EnginePool::describe_schema port
#   - EngineCapabilities carries the `introspect` route capability (true for
#     postgresql/mysql/mongodb, false for redis/http)
#   - POST /v1/schema route mounted, gated by validate_identity_mount +
#     require_capability("introspect") — NOT admin-gated
#   - postgres/mysql/mongo pools implement describe_schema with pure,
#     unit-tested type normalizers; SharedPool delegates it
#   - query-router: SchemaController (GET /:dbId/schema), SchemaService
#     (TTL cache), RustDataPlaneProxy.describeSchema, module registration
#
# Static checks (step 2 — DDL):
#   - data-plane-core declares SchemaDdlRequest/Result + the
#     EnginePool::apply_schema_ddl port; EngineCapabilities carries the NEW
#     `schema_ddl` route capability (distinct from `ddl` — mongo's migrate
#     gate stays false)
#   - POST /v1/schema/ddl mounted, gated on schema_ddl — NOT admin-gated
#   - postgres (pg_sql_type + build_pg_ddl) / mysql (mysql_sql_type +
#     build_mysql_ddl) / mongo (validator transforms) implement
#     apply_schema_ddl; SharedPool delegates it
#   - query-router: POST /:dbId/schema/ddl (confirm gate for destructive ops,
#     alter target composition, cache bust), proxy applySchemaDdl, DTO
#
# Live checks (BAAS_VERIFY_LIVE=1 or --live, requires docker):
#   - POST /v1/schema on a postgresql mount returns engine+tables[].columns[]
#   - POST /v1/schema on a redis mount is a clean 422 unsupported_capability
#   - DDL on a scratch PG table: create_table → add_column → describe shows it
#     → alter_column_type over incompatible data is a 409 → drop_column →
#     drop_table; redis DDL is a clean 422
#
# Live gateway tier (Phase 6 — runs with the live tier, full Kong path):
#   - provisions a scratch tenant + API key + postgresql mount through the
#     REAL control plane (lib-live-tenant.sh: tenant-control admin API +
#     Kong POST /admin/v1/databases) — or reuses BAAS_SCHEMA_DB_ID +
#     BAAS_API_KEY (a tenant mbk_… key) when provided
#   - GET /query/v1/<dbId>/schema through Kong with the minted key → 200
#     with tables[] + capabilities; unconfirmed destructive DDL → 400
#   - realtime echo: a WS subscriber (in-band AUTH with an HS256 JWT signed
#     with the stack's JWT_SECRET, SUBSCRIBE table:<dbId>:<table>) receives
#     the query-router's best-effort `row_changed` event within 5s of a
#     gateway `op:insert` on a gateway-DDL-created scratch table

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
ROUTER_DIR="${BAAS_DIR}/docker/services/data-plane-router"
QR_DIR="${BAAS_DIR}/src/apps/query-router/src"
COMPOSE_FILE="${BAAS_DIR}/docker-compose.yml"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
fail()  { red "[M22] FAIL: $*"; exit 1; }
step()  { cyan "[M22] ${*}"; }
pass()  { green "[M22] PASS: ${*}"; }

LIVE="${BAAS_VERIFY_LIVE:-0}"
for arg in "$@"; do
  [[ "${arg}" == "--live" ]] && LIVE=1
done

# ── 1) Core contract: SchemaDescriptor + describe_schema port ────────────────
step "checking data-plane-core schema contract"
SCHEMA_RS="${ROUTER_DIR}/crates/data-plane-core/src/schema.rs"
[[ -f "${SCHEMA_RS}" ]] || fail "missing ${SCHEMA_RS}"
for symbol in \
  "pub struct SchemaDescriptor" \
  "pub struct TableSchema" \
  "pub struct ColumnSchema" \
  "pub struct ForeignKeyRef" \
  "pub enum NormalizedType" \
  'rename_all = "snake_case"'; do
  grep -q "${symbol}" "${SCHEMA_RS}" || fail "${SCHEMA_RS} missing: ${symbol}"
done
grep -q "pub use schema::" "${ROUTER_DIR}/crates/data-plane-core/src/lib.rs" \
  || fail "data-plane-core lib.rs does not re-export the schema contract"
grep -q "async fn describe_schema" "${ROUTER_DIR}/crates/data-plane-core/src/ports.rs" \
  || fail "EnginePool::describe_schema port missing (NotImplemented default)"
pass "SchemaDescriptor contract + describe_schema port exist"

# ── 2) Capability flag: introspect is a route capability ─────────────────────
step "checking the introspect capability flag"
CAP_RS="${ROUTER_DIR}/crates/data-plane-core/src/capability.rs"
grep -q "pub introspect: bool" "${CAP_RS}" \
  || fail "EngineCapabilities.introspect missing"
grep -B2 "pub introspect: bool" "${CAP_RS}" | grep -q "serde(default)" \
  || fail "introspect must be #[serde(default)] for wire back-compat"
pass "EngineCapabilities.introspect declared with wire back-compat default"

# ── 3) Route: POST /v1/schema, identity/mount + capability gated ─────────────
step "checking the Rust /v1/schema route"
ROUTES="${ROUTER_DIR}/crates/data-plane-server/src/routes.rs"
grep -q '"/v1/schema"' "${ROUTES}" || fail "POST /v1/schema route missing"
grep -q "struct DescribeSchemaRequest" "${ROUTES}" \
  || fail "DescribeSchemaRequest envelope missing"
grep -q "async fn describe_schema" "${ROUTES}" || fail "describe_schema handler missing"
# The gating moved into run_describe_schema, the core shared by the /v1/schema
# envelope handler and the /data/v1/schema api-key bypass — assert it there
# (falling back to the handler itself for older layouts).
SCHEMA_CORE="async fn run_describe_schema"
grep -q "${SCHEMA_CORE}" "${ROUTES}" || SCHEMA_CORE="async fn describe_schema"
grep -A8 "${SCHEMA_CORE}" "${ROUTES}" | grep -q "validate_identity_mount" \
  || fail "describe_schema must validate identity/mount (begin_transaction-style gating)"
grep -A14 "${SCHEMA_CORE}" "${ROUTES}" | grep -q '"introspect"' \
  || fail "describe_schema must gate on the introspect capability"
grep -A14 "${SCHEMA_CORE}" "${ROUTES}" | grep -q "is_admin" \
  && fail "/v1/schema must NOT be admin-gated (any authenticated identity reads its own mount)"
pass "/v1/schema mounted: validate_identity_mount + introspect capability gate, no admin gate"

# ── 4) Engine implementations + pure normalizers + SharedPool delegation ─────
step "checking engine describe_schema implementations"
grep -q "async fn describe_schema" "${ROUTER_DIR}/crates/data-plane-pool/src/postgres.rs" \
  || fail "postgres describe_schema missing"
grep -q "fn normalize_pg_type" "${ROUTER_DIR}/crates/data-plane-pool/src/postgres.rs" \
  || fail "postgres normalize_pg_type (pure) missing"
grep -q "async fn describe_schema" "${ROUTER_DIR}/crates/data-plane-pool/src/mysql.rs" \
  || fail "mysql describe_schema missing"
grep -q "fn normalize_mysql_type" "${ROUTER_DIR}/crates/data-plane-pool/src/mysql.rs" \
  || fail "mysql normalize_mysql_type (pure) missing"
grep -q "async fn describe_schema" "${ROUTER_DIR}/crates/data-plane-pool/src/mongo.rs" \
  || fail "mongo describe_schema missing"
grep -q "fn jsonschema_to_columns" "${ROUTER_DIR}/crates/data-plane-pool/src/mongo.rs" \
  || fail "mongo jsonschema_to_columns (pure) missing"
grep -q "fn infer_columns_from_samples" "${ROUTER_DIR}/crates/data-plane-pool/src/mongo.rs" \
  || fail "mongo infer_columns_from_samples (pure) missing"
grep -q '_baas_migrations' "${ROUTER_DIR}/crates/data-plane-pool/src/postgres.rs" \
  || fail "postgres introspection must exclude _baas_migrations"
grep -q "self.0.describe_schema" "${ROUTER_DIR}/crates/data-plane-pool/src/registry.rs" \
  || fail "SharedPool must delegate describe_schema to the underlying engine"
pass "postgres + mysql + mongo implement describe_schema; SharedPool delegates"

# ── 5) query-router surface: GET /:dbId/schema ────────────────────────────────
step "checking query-router schema surface"
PROXY_TS="${QR_DIR}/proxy/rust-data-plane.proxy.ts"
grep -q "describeSchema" "${PROXY_TS}" \
  || fail "${PROXY_TS} missing describeSchema method"
grep -q "'/v1/schema'" "${PROXY_TS}" \
  || fail "${PROXY_TS} does not POST to /v1/schema"
SCHEMA_SVC="${QR_DIR}/query/schema.service.ts"
[[ -f "${SCHEMA_SVC}" ]] || fail "missing ${SCHEMA_SVC}"
grep -q "resolveConnection" "${SCHEMA_SVC}" \
  || fail "SchemaService must resolve the mount via QueryService.resolveConnection"
grep -q "describeSchema" "${SCHEMA_SVC}" \
  || fail "SchemaService never calls rustProxy.describeSchema"
grep -q "QUERY_ROUTER_SCHEMA_CACHE_TTL_MS" "${SCHEMA_SVC}" \
  || fail "SchemaService missing the TTL cache"
SCHEMA_CTRL="${QR_DIR}/query/schema.controller.ts"
[[ -f "${SCHEMA_CTRL}" ]] || fail "missing ${SCHEMA_CTRL}"
grep -q "':dbId/schema'" "${SCHEMA_CTRL}" \
  || fail "SchemaController does not serve GET /:dbId/schema"
grep -q "AuthGuard" "${SCHEMA_CTRL}" \
  || fail "SchemaController is not guarded (AuthGuard missing)"
QUERY_MOD="${QR_DIR}/query/query.module.ts"
grep -q "SchemaController" "${QUERY_MOD}" \
  || fail "QueryModule does not register SchemaController"
grep -q "SchemaService" "${QUERY_MOD}" \
  || fail "QueryModule does not register SchemaService"
grep -q "resolveConnection" "${QR_DIR}/query/query.service.ts" \
  || fail "QueryService.resolveConnection (public wrapper) missing"
pass "GET /query/v1/:dbId/schema wired: proxy + service (TTL cache) + guarded controller"

# ── 6) DDL contract: SchemaDdlRequest + apply_schema_ddl port + capability ───
step "checking the data-plane-core schema DDL contract"
DDL_RS="${ROUTER_DIR}/crates/data-plane-core/src/schema_ddl.rs"
[[ -f "${DDL_RS}" ]] || fail "missing ${DDL_RS}"
for symbol in \
  "pub struct SchemaDdlRequest" \
  "pub struct SchemaDdlResult" \
  "pub struct DdlColumnDef" \
  "pub enum SchemaDdlOp" \
  "pub fn validate_default_expr"; do
  grep -q "${symbol}" "${DDL_RS}" || fail "${DDL_RS} missing: ${symbol}"
done
grep -q "pub use schema_ddl::" "${ROUTER_DIR}/crates/data-plane-core/src/lib.rs" \
  || fail "data-plane-core lib.rs does not re-export the schema DDL contract"
grep -q "async fn apply_schema_ddl" "${ROUTER_DIR}/crates/data-plane-core/src/ports.rs" \
  || fail "EnginePool::apply_schema_ddl port missing (NotImplemented default)"
grep -q "pub schema_ddl: bool" "${CAP_RS}" \
  || fail "EngineCapabilities.schema_ddl missing"
grep -B2 "pub schema_ddl: bool" "${CAP_RS}" | grep -q "serde(default)" \
  || fail "schema_ddl must be #[serde(default)] for wire back-compat"
pass "SchemaDdlRequest contract + apply_schema_ddl port + schema_ddl capability exist"

# ── 7) Route: POST /v1/schema/ddl, identity/mount + schema_ddl gated ─────────
step "checking the Rust /v1/schema/ddl route"
grep -q '"/v1/schema/ddl"' "${ROUTES}" || fail "POST /v1/schema/ddl route missing"
grep -q "struct SchemaDdlEnvelope" "${ROUTES}" || fail "SchemaDdlEnvelope missing"
# Gating lives in run_apply_schema_ddl, the core shared by the envelope handler
# and the /data/v1 api-key bypass (fall back to the handler for older layouts).
DDL_CORE="async fn run_apply_schema_ddl"
grep -q "${DDL_CORE}" "${ROUTES}" || DDL_CORE="async fn apply_schema_ddl"
grep -A8 "${DDL_CORE}" "${ROUTES}" | grep -q "validate_identity_mount" \
  || fail "apply_schema_ddl must validate identity/mount"
grep -A16 "${DDL_CORE}" "${ROUTES}" | grep -q '"schema_ddl"' \
  || fail "apply_schema_ddl must gate on the schema_ddl capability"
grep -A16 "${DDL_CORE}" "${ROUTES}" | grep -q "is_admin" \
  && fail "/v1/schema/ddl must NOT be admin-gated (same trust model as /v1/query writes)"
pass "/v1/schema/ddl mounted: validate_identity_mount + schema_ddl capability gate, no admin gate"

# ── 8) Engine apply_schema_ddl implementations + SharedPool delegation ───────
step "checking engine apply_schema_ddl implementations"
grep -q "async fn apply_schema_ddl" "${ROUTER_DIR}/crates/data-plane-pool/src/postgres.rs" \
  || fail "postgres apply_schema_ddl missing"
grep -q "fn pg_sql_type" "${ROUTER_DIR}/crates/data-plane-pool/src/postgres.rs" \
  || fail "postgres pg_sql_type (pure reverse mapper) missing"
grep -q "fn build_pg_ddl" "${ROUTER_DIR}/crates/data-plane-pool/src/postgres.rs" \
  || fail "postgres build_pg_ddl (pure statement builder) missing"
grep -q "async fn apply_schema_ddl" "${ROUTER_DIR}/crates/data-plane-pool/src/mysql.rs" \
  || fail "mysql apply_schema_ddl missing"
grep -q "fn mysql_sql_type" "${ROUTER_DIR}/crates/data-plane-pool/src/mysql.rs" \
  || fail "mysql mysql_sql_type (pure reverse mapper) missing"
grep -q "fn build_mysql_ddl" "${ROUTER_DIR}/crates/data-plane-pool/src/mysql.rs" \
  || fail "mysql build_mysql_ddl (pure statement builder) missing"
grep -q "async fn apply_schema_ddl" "${ROUTER_DIR}/crates/data-plane-pool/src/mongo.rs" \
  || fail "mongo apply_schema_ddl missing"
grep -q "fn columns_to_jsonschema" "${ROUTER_DIR}/crates/data-plane-pool/src/mongo.rs" \
  || fail "mongo columns_to_jsonschema (pure) missing"
grep -q "fn jsonschema_with_column_set" "${ROUTER_DIR}/crates/data-plane-pool/src/mongo.rs" \
  || fail "mongo jsonschema_with_column_set (pure transform) missing"
grep -q "self.0.apply_schema_ddl" "${ROUTER_DIR}/crates/data-plane-pool/src/registry.rs" \
  || fail "SharedPool must delegate apply_schema_ddl to the underlying engine"
pass "postgres + mysql + mongo implement apply_schema_ddl; SharedPool delegates"

# ── 9) query-router surface: POST /:dbId/schema/ddl ──────────────────────────
step "checking query-router schema DDL surface"
grep -q "applySchemaDdl" "${PROXY_TS}" \
  || fail "${PROXY_TS} missing applySchemaDdl method"
grep -q "'/v1/schema/ddl'" "${PROXY_TS}" \
  || fail "${PROXY_TS} does not POST to /v1/schema/ddl"
[[ -f "${QR_DIR}/query/dto/schema-ddl.dto.ts" ]] || fail "missing schema-ddl.dto.ts"
grep -q "applyDdl" "${SCHEMA_SVC}" || fail "SchemaService.applyDdl missing"
grep -q "confirm" "${SCHEMA_SVC}" \
  || fail "SchemaService.applyDdl missing the destructive-op confirm gate"
grep -q "cache.delete" "${SCHEMA_SVC}" \
  || fail "SchemaService.applyDdl must bust the schema cache after DDL"
grep -q "':dbId/schema/ddl'" "${SCHEMA_CTRL}" \
  || fail "SchemaController does not serve POST /:dbId/schema/ddl"
pass "POST /query/v1/:dbId/schema/ddl wired: proxy + confirm gate + cache bust + DTO"

# ── 10) Live: pg mount yields tables+columns; redis mount yields 422 ─────────
if [[ "${LIVE}" == "1" ]]; then
  command -v docker >/dev/null 2>&1 || fail "docker required for live mode"
  command -v curl >/dev/null 2>&1 || fail "curl required for live mode"

  step "live: starting postgres + the Rust data-plane-router"
  # resolve-ports first: without it compose falls back to the DEFAULT host
  # ports, sees drift on a running stack, and RECREATES postgres — straight
  # into a port clash when the root track-binocle stack holds 5432.
  eval "$(bash "${BAAS_DIR}/scripts/resolve-ports.sh" 2>/dev/null || true)"
  docker compose -f "${COMPOSE_FILE}" up -d --wait postgres >/dev/null
  docker compose -f "${COMPOSE_FILE}" --profile rust-data-plane up -d --wait data-plane-router-rust >/dev/null

  RUST_URL="http://127.0.0.1:${DATA_PLANE_RUST_PORT:-4011}"
  # Read the credentials from the RUNNING container, not the caller's shell —
  # a wrong/default DSN here poisons the cached pool for the probe mount key.
  pg_env() { docker compose -f "${COMPOSE_FILE}" exec -T postgres sh -lc "printf '%s' \"\$$1\""; }
  PG_USER="$(pg_env POSTGRES_USER)"; PG_USER="${PG_USER:-postgres}"
  PG_PASS="$(pg_env POSTGRES_PASSWORD)"; PG_PASS="${PG_PASS:-postgres}"
  PG_DB="$(pg_env POSTGRES_DB)"; PG_DB="${PG_DB:-postgres}"
  PG_DSN="postgres://${PG_USER}:${PG_PASS}@postgres:5432/${PG_DB}"
  TENANT="00000000-0000-4000-8000-00000000m22a"
  # Unique per run: the registry keys pools on mount id + credential version,
  # so reusing an id would hand back a pool built from an earlier (possibly
  # bad) DSN instead of dialing with this run's credentials.
  PROBE_RUN="$(date +%s)"

  envelope() { # $1 engine, $2 inline_dsn
    cat <<JSON
{
  "identity": { "tenant_id": "${TENANT}", "project_id": null, "app_id": null,
                "user_id": "${TENANT}", "source": "signed_envelope" },
  "mount": { "id": "m22-probe-$1-${PROBE_RUN}", "tenant_id": "${TENANT}", "project_id": null,
             "engine": "$1", "name": "schema",
             "credential_ref": { "provider": "adapter-registry", "reference": "m22", "version": "live" },
             "pool_policy": { "min": 0, "max": 2, "idle_ttl_ms": 30000, "max_lifetime_ms": 1800000 },
             "capability_overrides": null, "inline_dsn": "$2", "isolation": null }
}
JSON
  }

  step "live: POST /v1/schema on a postgresql mount returns tables + columns"
  body=$(curl -fsS -X POST "${RUST_URL}/v1/schema" \
    -H 'Content-Type: application/json' \
    -d "$(envelope postgresql "${PG_DSN}")") \
    || fail "POST /v1/schema (postgresql) failed"
  echo "${body}" | grep -q '"engine":"postgresql"' || fail "schema response missing engine"
  echo "${body}" | grep -q '"tables":'             || fail "schema response missing tables[]"
  echo "${body}" | grep -q '"columns":'            || fail "schema response missing columns[]"
  echo "${body}" | grep -q '"normalized_type":'    || fail "columns missing normalized_type"
  echo "${body}" | grep -q '"primary_key":'        || fail "tables missing primary_key"
  echo "${body}" | grep -q '_baas_migrations' \
    && fail "_baas_migrations must be excluded from introspection"
  pass "postgresql schema descriptor has the contract shape"

  step "live: POST /v1/schema on a redis mount is a clean 422 unsupported_capability"
  code=$(curl -s -o /tmp/m22-redis-schema.json -w '%{http_code}' -X POST "${RUST_URL}/v1/schema" \
    -H 'Content-Type: application/json' \
    -d "$(envelope redis "redis://redis:6379")")
  [[ "${code}" == "422" ]] || fail "redis schema must be 422, got ${code}"
  grep -q "unsupported_capability" /tmp/m22-redis-schema.json \
    || fail "redis schema 422 must carry error=unsupported_capability"
  pass "redis mount rejected with 422 unsupported_capability"

  # ── Live DDL tier: full lifecycle on a scratch PG table ────────────────────
  SCRATCH="m22_ddl_${PROBE_RUN}"
  cleanup_scratch() {
    docker compose -f "${COMPOSE_FILE}" exec -T postgres \
      psql -U "${PG_USER}" -d "${PG_DB}" \
      -c "DROP TABLE IF EXISTS public.${SCRATCH}" >/dev/null 2>&1 || true
  }
  trap cleanup_scratch EXIT

  ddl_envelope() { # $1 engine, $2 inline_dsn, $3 ddl-json
    cat <<JSON
{
  "identity": { "tenant_id": "${TENANT}", "project_id": null, "app_id": null,
                "user_id": "${TENANT}", "source": "signed_envelope" },
  "mount": { "id": "m22-probe-$1-${PROBE_RUN}", "tenant_id": "${TENANT}", "project_id": null,
             "engine": "$1", "name": "schema",
             "credential_ref": { "provider": "adapter-registry", "reference": "m22", "version": "live" },
             "pool_policy": { "min": 0, "max": 2, "idle_ttl_ms": 30000, "max_lifetime_ms": 1800000 },
             "capability_overrides": null, "inline_dsn": "$2", "isolation": null },
  "ddl": $3
}
JSON
  }

  step "live: DDL create_table on scratch table ${SCRATCH}"
  body=$(curl -fsS -X POST "${RUST_URL}/v1/schema/ddl" \
    -H 'Content-Type: application/json' \
    -d "$(ddl_envelope postgresql "${PG_DSN}" "{
      \"op\": \"create_table\", \"table\": \"${SCRATCH}\",
      \"columns\": [
        { \"name\": \"id\", \"normalized_type\": \"integer\", \"nullable\": false, \"default\": null, \"enum_values\": null },
        { \"name\": \"note\", \"normalized_type\": \"text\", \"nullable\": true, \"default\": null, \"enum_values\": null }
      ],
      \"primary_key\": [\"id\"]
    }")") || fail "DDL create_table failed"
  echo "${body}" | grep -q '"status":"applied"' || fail "create_table did not apply: ${body}"
  pass "create_table applied"

  step "live: DDL add_column extra (text) on ${SCRATCH}"
  body=$(curl -fsS -X POST "${RUST_URL}/v1/schema/ddl" \
    -H 'Content-Type: application/json' \
    -d "$(ddl_envelope postgresql "${PG_DSN}" "{
      \"op\": \"add_column\", \"table\": \"${SCRATCH}\",
      \"column\": { \"name\": \"extra\", \"normalized_type\": \"text\", \"nullable\": true, \"default\": null, \"enum_values\": null }
    }")") || fail "DDL add_column failed"
  echo "${body}" | grep -q '"status":"applied"' || fail "add_column did not apply: ${body}"
  pass "add_column applied"

  step "live: describe shows the new table, the added column, and auto owner_id"
  body=$(curl -fsS -X POST "${RUST_URL}/v1/schema" \
    -H 'Content-Type: application/json' \
    -d "$(envelope postgresql "${PG_DSN}")") || fail "post-DDL describe failed"
  echo "${body}" | grep -q "\"name\":\"${SCRATCH}\"" || fail "describe missing table ${SCRATCH}"
  echo "${body}" | grep -q '"name":"extra"'         || fail "describe missing added column 'extra'"
  echo "${body}" | grep -q '"name":"owner_id"'      || fail "describe missing auto-appended owner_id"
  pass "describe reflects create_table + add_column (+ owner_id auto-append)"

  step "live: alter_column_type over incompatible data is a 409 conflict"
  docker compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${PG_USER}" -d "${PG_DB}" \
    -c "INSERT INTO public.${SCRATCH} (id, note) VALUES (1, 'abc')" >/dev/null \
    || fail "seeding the incompatible row failed"
  code=$(curl -s -o /tmp/m22-ddl-409.json -w '%{http_code}' -X POST "${RUST_URL}/v1/schema/ddl" \
    -H 'Content-Type: application/json' \
    -d "$(ddl_envelope postgresql "${PG_DSN}" "{
      \"op\": \"alter_column_type\", \"table\": \"${SCRATCH}\",
      \"column\": { \"name\": \"note\", \"normalized_type\": \"integer\", \"nullable\": true, \"default\": null, \"enum_values\": null }
    }")")
  [[ "${code}" == "409" ]] || fail "text→integer over 'abc' must be 409, got ${code}: $(cat /tmp/m22-ddl-409.json)"
  grep -q '"error":"conflict"' /tmp/m22-ddl-409.json \
    || fail "DDL 409 must carry error=conflict"
  pass "incompatible alter_column_type rejected with 409 conflict (data preserved)"

  step "live: DDL drop_column extra on ${SCRATCH}"
  body=$(curl -fsS -X POST "${RUST_URL}/v1/schema/ddl" \
    -H 'Content-Type: application/json' \
    -d "$(ddl_envelope postgresql "${PG_DSN}" "{ \"op\": \"drop_column\", \"table\": \"${SCRATCH}\", \"column_name\": \"extra\" }")") \
    || fail "DDL drop_column failed"
  echo "${body}" | grep -q '"status":"applied"' || fail "drop_column did not apply: ${body}"
  pass "drop_column applied"

  step "live: DDL drop_table ${SCRATCH}"
  body=$(curl -fsS -X POST "${RUST_URL}/v1/schema/ddl" \
    -H 'Content-Type: application/json' \
    -d "$(ddl_envelope postgresql "${PG_DSN}" "{ \"op\": \"drop_table\", \"table\": \"${SCRATCH}\" }")") \
    || fail "DDL drop_table failed"
  echo "${body}" | grep -q '"status":"applied"' || fail "drop_table did not apply: ${body}"
  pass "drop_table applied"

  step "live: DDL on a redis mount is a clean 422 unsupported_capability"
  code=$(curl -s -o /tmp/m22-redis-ddl.json -w '%{http_code}' -X POST "${RUST_URL}/v1/schema/ddl" \
    -H 'Content-Type: application/json' \
    -d "$(ddl_envelope redis "redis://redis:6379" "{ \"op\": \"drop_table\", \"table\": \"t\" }")")
  [[ "${code}" == "422" ]] || fail "redis DDL must be 422, got ${code}"
  grep -q "unsupported_capability" /tmp/m22-redis-ddl.json \
    || fail "redis DDL 422 must carry error=unsupported_capability"
  pass "redis DDL rejected with 422 unsupported_capability"

  cleanup_scratch

  # ── Gateway-path probe (Phase 6 — always runs in live mode) ────────────────
  # BAAS_SCHEMA_DB_ID + BAAS_API_KEY (a tenant mbk_… key) override with a
  # pre-registered mount; otherwise a scratch tenant + key + mount is
  # provisioned through the REAL control plane (lib-live-tenant.sh).
  # Wire note: Kong's key-auth consumes `apikey` (the anon/service consumer
  # key) while the TENANT key travels as X-Baas-Api-Key, which the
  # query-router's ApiKeyMiddleware exchanges via tenant-control
  # /v1/keys/verify — that pair is the only combination that traverses both
  # auth layers.
  # shellcheck source=scripts/verify/lib-live-tenant.sh
  source "${SCRIPT_DIR}/lib-live-tenant.sh"

  RT_TABLE="m22_rt_${PROBE_RUN}"
  WS_NAME="m22-ws-${PROBE_RUN}"
  cleanup_gateway() {
    docker rm -f "${WS_NAME}" >/dev/null 2>&1 || true
    docker compose -f "${COMPOSE_FILE}" exec -T postgres \
      psql -U "${PG_USER}" -d "${PG_DB}" \
      -c "DROP TABLE IF EXISTS public.${RT_TABLE}" >/dev/null 2>&1 || true
  }
  cleanup_live_all() {
    cleanup_scratch
    cleanup_gateway
    # Only deprovision what THIS run minted (no-op in override mode).
    live_tenant_cleanup
  }
  trap cleanup_live_all EXIT

  if [[ -n "${BAAS_SCHEMA_DB_ID:-}" && -n "${BAAS_API_KEY:-}" ]]; then
    GW_DB_ID="${BAAS_SCHEMA_DB_ID}"
    GW_TENANT_KEY="${BAAS_API_KEY}"
    GW_KONG_URL="http://127.0.0.1:$(docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://')"
    GW_ANON_KEY="$(docker inspect mini-baas-kong \
      --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
      | grep '^KONG_PUBLIC_API_KEY=' | cut -d= -f2-)"
    [[ -n "${GW_ANON_KEY}" ]] || fail "KONG_PUBLIC_API_KEY not found on mini-baas-kong"
  else
    step "live: provisioning scratch tenant + API key + mount through the gateway"
    live_tenant_provision "m22live${PROBE_RUN}" || fail "live tenant provisioning failed"
    GW_DB_ID="${LIVE_TENANT_DB_ID}"
    GW_TENANT_KEY="${LIVE_TENANT_API_KEY}"
    GW_KONG_URL="${LIVE_KONG_URL}"
    GW_ANON_KEY="${LIVE_ANON_APIKEY}"
    pass "tenant '${LIVE_TENANT_SLUG}' + key + mount ${GW_DB_ID} provisioned (Kong /admin/v1/databases)"
  fi

  step "live: GET /query/v1/${GW_DB_ID}/schema through the gateway with the minted key"
  gw=$(curl -fsS "${GW_KONG_URL}/query/v1/${GW_DB_ID}/schema" \
    -H "apikey: ${GW_ANON_KEY}" -H "X-Baas-Api-Key: ${GW_TENANT_KEY}") \
    || fail "gateway schema fetch failed"
  echo "${gw}" | grep -q '"tables":' || fail "gateway schema response missing tables[]"
  echo "${gw}" | grep -q '"capabilities":' || fail "gateway schema response missing capabilities"
  pass "gateway GET /query/v1/:dbId/schema serves tables + capabilities"

  step "live: gateway DDL confirm gate — destructive op without confirm is a 400"
  code=$(curl -s -o /tmp/m22-gw-confirm.json -w '%{http_code}' -X POST \
    "${GW_KONG_URL}/query/v1/${GW_DB_ID}/schema/ddl" \
    -H "apikey: ${GW_ANON_KEY}" -H "X-Baas-Api-Key: ${GW_TENANT_KEY}" \
    -H 'Content-Type: application/json' \
    -d '{ "op": "drop_table", "table": "m22_confirm_probe_nonexistent" }')
  [[ "${code}" == "400" ]] || fail "unconfirmed drop_table must be 400, got ${code}"
  grep -qi "confirm" /tmp/m22-gw-confirm.json \
    || fail "unconfirmed-DDL 400 must mention the confirm requirement"
  pass "gateway POST /query/v1/:dbId/schema/ddl enforces the confirm gate"

  # ── Realtime echo: gateway write → row_changed on table:<dbId>:<table> ─────
  step "live: gateway DDL create_table ${RT_TABLE} (scratch realtime table)"
  # owner_id is declared EXPLICITLY as text: the platform's write path stamps
  # the caller principal (api-key:<key uuid> here) into owner_id, matching the
  # owner_id TEXT shape of the seeded platform tables (mock_orders, projects).
  code=$(curl -s -o /tmp/m22-rt-ddl.json -w '%{http_code}' -X POST \
    "${GW_KONG_URL}/query/v1/${GW_DB_ID}/schema/ddl" \
    -H "apikey: ${GW_ANON_KEY}" -H "X-Baas-Api-Key: ${GW_TENANT_KEY}" \
    -H 'Content-Type: application/json' \
    -d "{
      \"op\": \"create_table\", \"table\": \"${RT_TABLE}\",
      \"columns\": [
        { \"name\": \"id\", \"normalized_type\": \"integer\", \"nullable\": false },
        { \"name\": \"note\", \"normalized_type\": \"text\", \"nullable\": true },
        { \"name\": \"owner_id\", \"normalized_type\": \"text\", \"nullable\": true }
      ],
      \"primary_key\": [\"id\"]
    }")
  [[ "${code}" == "200" || "${code}" == "201" ]] \
    || fail "gateway create_table failed (${code}): $(cat /tmp/m22-rt-ddl.json)"
  grep -q '"status":"applied"' /tmp/m22-rt-ddl.json \
    || fail "gateway create_table did not apply: $(cat /tmp/m22-rt-ddl.json)"
  pass "gateway DDL created ${RT_TABLE}"

  step "live: starting WS subscriber on table:${GW_DB_ID}:${RT_TABLE}"
  STACK_NET="$(docker inspect mini-baas-kong \
    --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null | head -1)"
  [[ -n "${STACK_NET}" ]] || fail "could not resolve the stack docker network from mini-baas-kong"
  RT_JWT_SECRET="$(docker inspect mini-baas-realtime \
    --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep '^REALTIME_JWT_SECRET=' | cut -d= -f2-)"
  [[ -n "${RT_JWT_SECRET}" ]] || fail "REALTIME_JWT_SECRET not found on mini-baas-realtime"
  WS_PROBE="$(mktemp /tmp/m22-ws-probe.XXXXXX.mjs)"
  # Node's built-in WebSocket client (stable on 22, flag-gated on 20) — no npm
  # install needed, the probe runs offline. JWT minted with node:crypto HS256.
  cat > "${WS_PROBE}" <<'WSJS'
import { createHmac } from 'node:crypto';
const b64u = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const head = b64u({ alg: 'HS256', typ: 'JWT' });
const body = b64u({ sub: 'm22-verify', exp: Math.floor(Date.now() / 1000) + 300 });
const sig = createHmac('sha256', process.env.RT_JWT_SECRET)
  .update(`${head}.${body}`).digest('base64url');
const ws = new WebSocket(process.env.RT_WS_URL);
const die = (msg) => { console.log(msg); process.exit(1); };
setTimeout(() => die('TIMEOUT waiting for row_changed'), Number(process.env.RT_WAIT_MS ?? 30000));
ws.onopen = () => ws.send(JSON.stringify({ type: 'AUTH', token: `${head}.${body}.${sig}` }));
ws.onerror = (e) => die(`WS_ERROR ${e.message ?? 'connect failed'}`);
ws.onmessage = (m) => {
  const f = JSON.parse(m.data);
  if (f.type === 'AUTH_OK') {
    ws.send(JSON.stringify({ type: 'SUBSCRIBE', sub_id: 's1', topic: process.env.RT_TOPIC }));
  } else if (f.type === 'SUBSCRIBED') {
    console.log('SUBSCRIBED');
  } else if (f.type === 'EVENT' && f.event.event_type === 'row_changed') {
    console.log(`ROW_CHANGED ${f.event.topic} ${JSON.stringify(f.event.payload)}`);
    process.exit(0);
  } else if (f.type === 'ERROR') {
    die(`PROTO_ERROR ${f.code} ${f.message}`);
  }
};
WSJS
  WS_NODE_IMAGE="${BAAS_WS_NODE_IMAGE:-node:22-alpine}"
  docker rm -f "${WS_NAME}" >/dev/null 2>&1 || true
  docker run -d --name "${WS_NAME}" --network "${STACK_NET}" \
    -v "${WS_PROBE}:/probe.mjs:ro" \
    -e RT_WS_URL="ws://kong:8000/realtime/v1/ws" \
    -e RT_JWT_SECRET="${RT_JWT_SECRET}" \
    -e RT_TOPIC="table:${GW_DB_ID}:${RT_TABLE}" \
    -e RT_WAIT_MS=30000 \
    "${WS_NODE_IMAGE}" node --experimental-websocket /probe.mjs >/dev/null \
    || fail "could not start the WS subscriber container (${WS_NODE_IMAGE})"
  for _ in $(seq 1 60); do
    docker logs "${WS_NAME}" 2>&1 | grep -q 'SUBSCRIBED' && break
    sleep 0.5
  done
  docker logs "${WS_NAME}" 2>&1 | grep -q 'SUBSCRIBED' \
    || fail "WS subscriber never reached SUBSCRIBED: $(docker logs "${WS_NAME}" 2>&1 | tail -3)"
  pass "WS subscriber authenticated (in-band JWT) and subscribed via /realtime/v1/ws"

  step "live: gateway op=insert on ${RT_TABLE} → row_changed echo within 5s"
  code=$(curl -s -o /tmp/m22-rt-insert.json -w '%{http_code}' -X POST \
    "${GW_KONG_URL}/query/v1/${GW_DB_ID}/tables/${RT_TABLE}" \
    -H "apikey: ${GW_ANON_KEY}" -H "X-Baas-Api-Key: ${GW_TENANT_KEY}" \
    -H 'Content-Type: application/json' \
    -d '{ "op": "insert", "data": { "id": 1, "note": "m22 realtime echo" } }')
  [[ "${code}" == "200" || "${code}" == "201" ]] \
    || fail "gateway insert failed (${code}): $(cat /tmp/m22-rt-insert.json)"
  grep -q '"rowCount":1' /tmp/m22-rt-insert.json \
    || fail "gateway insert did not report rowCount 1: $(cat /tmp/m22-rt-insert.json)"
  ECHO_OK=0
  for _ in $(seq 1 10); do
    if docker logs "${WS_NAME}" 2>&1 | grep -q 'ROW_CHANGED'; then ECHO_OK=1; break; fi
    sleep 0.5
  done
  [[ "${ECHO_OK}" == "1" ]] \
    || fail "no row_changed frame within 5s: $(docker logs "${WS_NAME}" 2>&1 | tail -3)"
  docker logs "${WS_NAME}" 2>&1 | grep 'ROW_CHANGED' \
    | grep -q "table:${GW_DB_ID}:${RT_TABLE}" \
    || fail "row_changed arrived on the wrong topic: $(docker logs "${WS_NAME}" 2>&1 | tail -3)"
  pass "realtime echo: gateway insert delivered as row_changed on table:${GW_DB_ID}:${RT_TABLE}"
  rm -f "${WS_PROBE}"
fi

green "[M22] OK — engine-agnostic schema introspection + DDL verified"
