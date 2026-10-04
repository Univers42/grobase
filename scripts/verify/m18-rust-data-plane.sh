#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="."
ROUTER_DIR="${BAAS_DIR}/src/data-plane-router"
COMPOSE_FILE="${BAAS_DIR}/orchestrators/compose/base"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
fail() {
  red "[M18] FAIL: $*"
  exit 1
}
step() { cyan "[M18] ${*}"; }
pass() { green "[M18] PASS: ${*}"; }

# mounted reports whether the server's routes call .route("$1", …): matched on
# the whitespace-stripped sources so a call split over lines still counts and a
# comment naming the path does not.
mounted() {
  find "${ROUTER_DIR}/crates/data-plane-server/src/routes" -name '*.rs' -exec cat {} + |
    tr -d ' \t\n' | grep -qF ".route(\"$1\""
}

LIVE=0
for arg in "$@"; do
  [[ "${arg}" == "--live" ]] && LIVE=1
done

step "checking Rust data-plane-router source layout"
for path in \
  "${ROUTER_DIR}/Cargo.toml" \
  "${ROUTER_DIR}/Dockerfile" \
  "${ROUTER_DIR}/crates/data-plane-core/src/capability.rs" \
  "${ROUTER_DIR}/crates/data-plane-core/src/mount.rs" \
  "${ROUTER_DIR}/crates/data-plane-core/src/identity.rs" \
  "${ROUTER_DIR}/crates/data-plane-core/src/ports.rs" \
  "${ROUTER_DIR}/crates/data-plane-core/src/transaction.rs" \
  "${ROUTER_DIR}/crates/data-plane-server/src/routes/mod.rs"; do
  [[ -f "${path}" ]] || fail "missing ${path}"
done
pass "Rust workspace, core contracts and server routes exist"

step "checking language-boundary documentation"
DOC="wiki/architecture/00-overview.md"
[[ -f "${DOC}" ]] || fail "missing ${DOC}"
grep -q "Application / business plane\*\* | TypeScript" "${DOC}" || fail "${DOC} missing TypeScript boundary"
grep -q "Control plane\*\* | Go" "${DOC}" || fail "${DOC} missing Go boundary"
grep -q "Data plane\*\* | Rust" "${DOC}" || fail "${DOC} missing Rust boundary"
grep -q "Shadow → parity → cutover → delete" CLAUDE.md || fail "CLAUDE.md missing the migration guardrail"
pass "runtime split is documented"

step "checking compose still declares both query-router and the Rust router"
grep -rq "^  query-router:" "${COMPOSE_FILE}" || fail "Nest query-router service disappeared"
grep -rq "^  data-plane-router-rust:" "${COMPOSE_FILE}" || fail "Rust data-plane-router service missing"
# Post-cutover: PRODUCT_MODE is `enabled` by default; `shadow` is still
# accepted as an opt-out for one-off testing of TS-only flows. Both values
# mean "the Rust router is reachable"; only the proxy gate (FORWARD=1) decides
# whether traffic flows through it.
grep -rqE "DATA_PLANE_ROUTER_PRODUCT_MODE:.*(enabled|shadow)" "${COMPOSE_FILE}" ||
  fail "Rust data-plane-router must declare a PRODUCT_MODE (enabled|shadow)"
grep -rqE "RUST_DATA_PLANE_FORWARD:.*1" "${COMPOSE_FILE}" ||
  fail "compose default must enable Rust forwarding (RUST_DATA_PLANE_FORWARD=1)"
# All engines with a live Rust pool must be forwarded (mariadb rides the mysql
# adapter — Phase 3). Assert each is present rather than pinning the exact list.
for _eng in postgresql mongodb mysql mariadb redis http; do
  grep -rqE "RUST_DATA_PLANE_FORWARD_ENGINES:.*${_eng}" "${COMPOSE_FILE}" ||
    fail "compose default must forward the ${_eng} engine to the Rust router"
done
pass "compose forwards every Rust-served engine (pg/mongo/mysql/mariadb/redis/http) by default"

step "checking Rust router contracts statically"
grep -rq "pub trait EngineAdapter" "${ROUTER_DIR}/crates/data-plane-core/src/ports.rs" ||
  fail "EngineAdapter port missing"
grep -rq "pub trait PoolRegistry" "${ROUTER_DIR}/crates/data-plane-core/src/ports.rs" ||
  fail "PoolRegistry port missing"
grep -rq "EngineCapabilities::postgresql" "${ROUTER_DIR}/crates/data-plane-server/src/routes" ||
  fail "Postgres capability descriptor missing"
grep -rq "EngineCapabilities::mongodb" "${ROUTER_DIR}/crates/data-plane-server/src/routes" ||
  fail "Mongo capability descriptor missing"
grep -rq "EngineCapabilities::mysql" "${ROUTER_DIR}/crates/data-plane-server/src/routes" ||
  fail "MySQL capability descriptor missing (R7)"
grep -rq "EngineCapabilities::redis" "${ROUTER_DIR}/crates/data-plane-server/src/routes" ||
  fail "Redis capability descriptor missing (R8)"
grep -rq "EngineCapabilities::http" "${ROUTER_DIR}/crates/data-plane-server/src/routes" ||
  fail "HTTP capability descriptor missing (R8)"
grep -rq "identity tenant does not match mount tenant" "${ROUTER_DIR}/crates/data-plane-server/src/routes" ||
  fail "tenant/mount guard missing"
mounted "/v1/transactions" ||
  fail "transaction session contract routes missing"
# Post-audit additions: real PG transactions, admin raw + migrate, in-Rust
# ABAC evaluator. Assert each route is mounted; engine-level overrides for
# raw + migrate must also delegate through SharedPool.
mounted "/v1/transactions/:tx_id/execute" ||
  fail "POST /v1/transactions/:tx_id/execute route missing"
mounted "/v1/admin/raw" ||
  fail "/v1/admin/raw route missing"
mounted "/v1/admin/migrate" ||
  fail "/v1/admin/migrate route missing"
mounted "/v1/admin/rotate" ||
  fail "/v1/admin/rotate route missing (G8 credential rotation)"
mounted "/v1/permissions/decide" ||
  fail "/v1/permissions/decide route missing"
grep -rq "self.0.execute_raw" "${ROUTER_DIR}/crates/data-plane-pool/src/registry.rs" ||
  fail "SharedPool must delegate execute_raw to the underlying engine"
grep -rq "self.0.apply_migration" "${ROUTER_DIR}/crates/data-plane-pool/src/registry.rs" ||
  fail "SharedPool must delegate apply_migration to the underlying engine"
pass "contracts expose capability, tenant guard, tx API, admin + abac routes"

# ── R2 + R3 + R7 + R8: routes.rs reaches into PoolRegistry; 5 engines wired ──
step "checking R2 + R3 + R7 + R8 — /v1/query dispatches through PoolRegistry"
ROUTES="${ROUTER_DIR}/crates/data-plane-server/src/routes"
SERVER="${ROUTER_DIR}/crates/data-plane-server/src/server.rs"
grep -rq "registry.get_or_create" "${ROUTES}" ||
  fail "/v1/query does not call PoolRegistry::get_or_create — still a 501 stub"
grep -rq "pool.execute" "${ROUTES}" ||
  fail "/v1/query does not call EnginePool::execute — still a 501 stub"
grep -rq "map_data_plane_error" "${ROUTES}" ||
  fail "DataPlaneError → HTTP status mapping missing"
# G6: /v1/query routes through the capability-aware planner, not a bare
# validate_operation call; an unavailable capability maps to 422.
grep -rq "data_plane_core::plan" "${ROUTES}" ||
  fail "/v1/query does not call data_plane_core::plan (G6 capability-aware routing)"
grep -rq "UNPROCESSABLE_ENTITY" "${ROUTES}" ||
  fail "UnsupportedCapability must map to 422 UNPROCESSABLE_ENTITY (G6)"
grep -rq "PostgresEngineAdapter" "${ROUTES}" ||
  fail "AppState::new does not build PostgresEngineAdapter"
grep -rq "MongoEngineAdapter" "${ROUTES}" ||
  fail "AppState::new does not build MongoEngineAdapter (R3 not wired)"
grep -rq "MysqlEngineAdapter" "${ROUTES}" ||
  fail "AppState::new does not build MysqlEngineAdapter (R7 not wired)"
grep -rq "RedisEngineAdapter" "${ROUTES}" ||
  fail "AppState::new does not build RedisEngineAdapter (R8 not wired)"
grep -rq "HttpEngineAdapter" "${ROUTES}" ||
  fail "AppState::new does not build HttpEngineAdapter (R8 not wired)"
grep -rqE "DefaultPoolRegistry::(new|with_max_pools|with_config)" "${ROUTES}" ||
  fail "AppState::new does not build DefaultPoolRegistry"
# executable_engines must include every Rust-served engine (mariadb rides the
# mysql adapter — Phase 3). Check each token rather than pinning the order.
for _eng in postgresql mongodb mysql mariadb redis http; do
  grep -rqE "\"${_eng}\"" "${ROUTES}" ||
    fail "executable_engines list does not include the ${_eng} engine"
done
pass "PoolRegistry dispatches every Rust-served engine (pg/mongo/mysql/mariadb/redis/http)"

# ── R3 specific: Mongo adapter implementation surface ────────────────────────
step "checking Rust Mongo adapter (R3)"
MONGO_RS="${ROUTER_DIR}/crates/data-plane-pool/src/mongo"
[[ -e "${MONGO_RS}" ]] || fail "${MONGO_RS} missing"
for symbol in \
  "pub struct MongoEngineAdapter" \
  "pub struct MongoPool" \
  "impl EngineAdapter for MongoEngineAdapter" \
  "impl EnginePool for MongoPool" \
  "build_tenant_filter" \
  "build_owned_doc" \
  "RESERVED_FIELDS" \
  "TryStreamExt"; do
  grep -rq "${symbol}" "${MONGO_RS}" ||
    fail "${MONGO_RS} missing required symbol: ${symbol}"
done
grep -rq 'pub use mongo::MongoEngineAdapter' \
  "${ROUTER_DIR}/crates/data-plane-pool/src/lib.rs" ||
  fail "data-plane-pool lib.rs does not re-export MongoEngineAdapter"
# The driver moved 2.8 → 3.x: either the (filter, options) signature or the
# 3.x builder with .with_options(find_opts) proves filter AND sort/options are
# both applied (the failure mode this guards = silently dropping one of them).
find "${MONGO_RS}" -name '*.rs' -exec cat {} + | tr -d ' \t\n' |
  grep -qE 'col\.find\(filter,find_opts\)|col\.find\(filter\)\.with_options\(find_opts\)' ||
  fail "MongoPool::run_list must apply both filter and find options (tenant scope + sort)"
pass "Rust Mongo adapter (R3) compiles, exports, and enforces server-side tenant scope"

# ── R7 specific: MySQL adapter implementation surface ────────────────────────
step "checking Rust MySQL adapter (R7)"
MYSQL_RS="${ROUTER_DIR}/crates/data-plane-pool/src/mysql"
[[ -e "${MYSQL_RS}" ]] || fail "${MYSQL_RS} missing"
for symbol in \
  "pub struct MysqlEngineAdapter" \
  "pub struct MysqlPool" \
  "impl EngineAdapter for MysqlEngineAdapter" \
  "impl EnginePool for MysqlPool" \
  "build_owner_filter" \
  "build_owned_columns" \
  "RESERVED_COLUMNS" \
  "quote_mysql_ident"; do
  grep -rq "${symbol}" "${MYSQL_RS}" ||
    fail "${MYSQL_RS} missing required symbol: ${symbol}"
done
grep -rq 'pub use mysql::MysqlEngineAdapter' \
  "${ROUTER_DIR}/crates/data-plane-pool/src/lib.rs" ||
  fail "data-plane-pool lib.rs does not re-export MysqlEngineAdapter"
# Parity contract with the TS engine: backtick-quoted idents + owner_id-only
# tenant scope (TS engine intentionally does not write tenant_id either).
grep -rq 'quote_mysql_ident' "${MYSQL_RS}" ||
  fail "MysqlPool must use quote_mysql_ident (backtick-safe identifier quoting)"
grep -rq 'identity tenant does not match pool tenant' "${MYSQL_RS}" ||
  fail "MysqlPool missing identity/pool tenant cross-check"
pass "Rust MySQL adapter (R7) compiles, exports, and enforces server-side owner scope"

# ── R8 specific: Redis adapter implementation surface ────────────────────────
step "checking Rust Redis adapter (R8)"
REDIS_RS="${ROUTER_DIR}/crates/data-plane-pool/src/redis"
[[ -e "${REDIS_RS}" ]] || fail "${REDIS_RS} missing"
for symbol in \
  "pub struct RedisEngineAdapter" \
  "pub struct RedisPool" \
  "impl EngineAdapter for RedisEngineAdapter" \
  "impl EnginePool for RedisPool" \
  "key_prefix" \
  "validate_resource" \
  "ConnectionManager"; do
  grep -rq "${symbol}" "${REDIS_RS}" ||
    fail "${REDIS_RS} missing required symbol: ${symbol}"
done
grep -rq 'pub use redis::RedisEngineAdapter' \
  "${ROUTER_DIR}/crates/data-plane-pool/src/lib.rs" ||
  fail "data-plane-pool lib.rs does not re-export RedisEngineAdapter"
grep -rq 'identity tenant does not match pool tenant' "${REDIS_RS}" ||
  fail "RedisPool missing identity/pool tenant cross-check"
pass "Rust Redis adapter (R8) compiles, exports, and key-namespaces by owner"

# ── R8 specific: HTTP passthrough adapter implementation surface ─────────────
step "checking Rust HTTP adapter (R8)"
HTTP_RS="${ROUTER_DIR}/crates/data-plane-pool/src/http"
[[ -e "${HTTP_RS}" ]] || fail "${HTTP_RS} missing"
for symbol in \
  "pub struct HttpEngineAdapter" \
  "pub struct HttpPool" \
  "impl EngineAdapter for HttpEngineAdapter" \
  "impl EnginePool for HttpPool" \
  "parse_connection" \
  "validate_resource" \
  "x-owner-id"; do
  grep -rq "${symbol}" "${HTTP_RS}" ||
    fail "${HTTP_RS} missing required symbol: ${symbol}"
done
# Accept both the bare and the braced re-export form
# (pub use http::{guard_and_resolve, HttpEngineAdapter}).
grep -rqE 'pub use http::(\{[^}]*)?HttpEngineAdapter' \
  "${ROUTER_DIR}/crates/data-plane-pool/src/lib.rs" ||
  fail "data-plane-pool lib.rs does not re-export HttpEngineAdapter"
grep -rq 'identity tenant does not match pool tenant' "${HTTP_RS}" ||
  fail "HttpPool missing identity/pool tenant cross-check"
pass "Rust HTTP adapter (R8) compiles, exports, and forwards X-Owner-Id"

# ── Post-cutover: the legacy TS engines have been deleted. The proxy is now
# the only path for R2/R3/R7/R8 engines; assert both the proxy is intact AND
# that the TS engine files are absent.
step "checking TS RustDataPlaneProxy is wired and legacy TS engines are gone"
PROXY_TS="${BAAS_DIR}/src/apps/query-router/src/proxy/rust-data-plane.proxy.ts"
[[ -f "${PROXY_TS}" ]] || fail "${PROXY_TS} missing — TS cannot reach Rust"
grep -rq "shouldForward" "${PROXY_TS}" || fail "${PROXY_TS} missing shouldForward() gate"
grep -rq "RUST_DATA_PLANE_FORWARD" "${PROXY_TS}" ||
  fail "${PROXY_TS} does not honour RUST_DATA_PLANE_FORWARD env switch"
grep -rq "/v1/query" "${PROXY_TS}" ||
  fail "${PROXY_TS} does not forward to Rust /v1/query"
QUERY_SVC="${BAAS_DIR}/src/apps/query-router/src/query/query.service.ts"
grep -rq "rustProxy.shouldForward" "${QUERY_SVC}" ||
  fail "QueryService does not consult RustDataPlaneProxy.shouldForward"
grep -rq "rustProxy.execute" "${QUERY_SVC}" ||
  fail "QueryService never calls RustDataPlaneProxy.execute"
QUERY_MOD="${BAAS_DIR}/src/apps/query-router/src/query/query.module.ts"
grep -rq "RustDataPlaneProxy" "${QUERY_MOD}" ||
  fail "QueryModule does not register RustDataPlaneProxy as a provider"
# Post-cutover absence checks: the 5 TS engines must be deleted.
for engine in postgresql mongodb mysql redis http; do
  f="${BAAS_DIR}/src/apps/query-router/src/engines/${engine}.engine.ts"
  [[ -f "${f}" ]] && fail "${f} should be deleted post-cutover (parity proven)"
done
pass "RustDataPlaneProxy bridges Nest → Rust; legacy TS engines deleted"

step "running cargo check"
if command -v cargo >/dev/null 2>&1; then
  (cd "${ROUTER_DIR}" && cargo check --workspace)
else
  command -v docker >/dev/null 2>&1 || fail "cargo or docker is required for Rust verification"
  docker run --rm \
    -v "${REPO_ROOT}/${ROUTER_DIR}:/work" \
    -w /work \
    -u "$(id -u):$(id -g)" \
    mirror.gcr.io/library/rust:1.96-slim-bookworm@sha256:e18a79fc84dfcfc3ab5ba72290398a644c135c97eaa881447fddc354ee4701a3 \
    cargo check --workspace
fi
pass "cargo check passed"

# ── Capability-honesty gate (04/S1): descriptors must not advertise an op the
# adapter doesn't dispatch. Runs the no-lying unit tests so a regression (e.g.
# re-adding mongo transactions, or advertising batch with no Batch arm) fails
# the milestone, not just `cargo test` run by hand.
step "running capability-honesty + planner + plan (G6) + credential (G8) tests (no-lying gate)"
if command -v cargo >/dev/null 2>&1; then
  (cd "${ROUTER_DIR}" && cargo test -p data-plane-pool capability_honesty:: &&
    cargo test -p data-plane-core planner:: &&
    cargo test -p data-plane-core plan:: &&
    cargo test -p data-plane-pool credential::)
else
  docker run --rm \
    -v "${REPO_ROOT}/${ROUTER_DIR}:/work" \
    -w /work \
    -u "$(id -u):$(id -g)" \
    mirror.gcr.io/library/rust:1.96-slim-bookworm@sha256:e18a79fc84dfcfc3ab5ba72290398a644c135c97eaa881447fddc354ee4701a3 \
    sh -c "cargo test -p data-plane-pool capability_honesty:: && cargo test -p data-plane-core planner:: && cargo test -p data-plane-core plan:: && cargo test -p data-plane-pool credential::"
fi
pass "capability descriptors match dispatch reality + G6 routing + G8 credential providers verified"

if [[ ${LIVE} -eq 1 ]]; then
  command -v docker >/dev/null 2>&1 || fail "docker required for --live mode"
  command -v curl >/dev/null 2>&1 || fail "curl required for --live mode"
  step "live: starting Rust data-plane-router (post-cutover, primary path)"
  docker compose -f "${COMPOSE_FILE}" --profile rust-data-plane up -d --wait data-plane-router-rust
  body=$(curl -fsS "http://127.0.0.1:${DATA_PLANE_RUST_PORT:-4011}/v1/capabilities") ||
    fail "live capabilities endpoint failed"
  echo "${body}" | grep -q '"language":"rust"' || fail "capabilities missing Rust router language"
  echo "${body}" | grep -q '"postgresql"' || fail "capabilities missing postgresql"
  echo "${body}" | grep -q '"mongodb"' || fail "capabilities missing mongodb"
  echo "${body}" | grep -q '"mysql"' || fail "capabilities missing mysql (R7)"
  echo "${body}" | grep -q '"redis"' || fail "capabilities missing redis (R8)"
  echo "${body}" | grep -q '"http"' || fail "capabilities missing http (R8)"
  docker compose -f "${COMPOSE_FILE}" --profile rust-data-plane stop data-plane-router-rust >/dev/null
  docker compose -f "${COMPOSE_FILE}" --profile rust-data-plane rm -f data-plane-router-rust >/dev/null
  pass "live Rust data-plane-router capabilities endpoint works"
fi

green "[M18] OK - Rust data-plane migration scaffold verified"
