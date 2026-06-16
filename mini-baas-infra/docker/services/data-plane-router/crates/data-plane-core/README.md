# data-plane-core

The pure domain vocabulary of the mini-baas / Grobase Rust **data plane**: capability descriptors, the filter AST, the query planner/validator, isolation strategies, mounts, operations, schema/DDL contracts, and the `ports` traits — with **zero network or database I/O**.

## Role in the workspace

`data-plane-router` is a four-crate cargo workspace, and this crate sits at the **bottom** of it:

- **`data-plane-core`** (this crate) — defines every abstraction and the trait seam (`EngineAdapter` / `EnginePool` / `PoolRegistry`). It depends on nothing but `serde`, `serde_json`, `thiserror`, `chrono`, `uuid`, and `async-trait`. No DB drivers, no sockets, no axum.
- **`data-plane-pool`** — implements core's traits with concrete engine adapters (Postgres, Mongo, MySQL, Redis, HTTP, SQLite, MSSQL, DynamoDB).
- **`data-plane-server`** — the axum HTTP server that parses requests, calls `validate_operation` / `plan`, resolves credentials, and dispatches through `EnginePool`.
- **`engine-conformance`** — the test battery that pins capability honesty.

Because this crate is I/O-free, it is cheap to unit-test exhaustively (op × engine), and almost every type here is `serde`-(de)serializable so it can double as the wire contract that the TypeScript query-router forwards verbatim.

## Mental model

**Capability honesty is the central discipline.** Each engine advertises an `EngineCapabilities` descriptor (`capability.rs`) — `read`/`write`/`upsert`/`batch`/`aggregate`/`transactions`/`stream`/`ddl`/`schema_ddl`/`introspect`, isolation levels, and a `CostCapabilities` triple. The descriptor is the **single source of truth**: `EngineCapabilities::supports_op` derives, from the flags, exactly which `DataOperationKind`s an engine serves, and each adapter's `dispatch_op` must implement precisely that set (pinned by the capability-honesty test in `data-plane-pool`). An engine never silently degrades an unsupported op — it errors out with a precise contract error. Route-only capabilities (`introspect`, `schema_ddl`, `ddl`) are deliberately kept *out* of `supports_op` so flipping them can't change which data operations an engine claims.

**Plan → validate is a two-phase flow.** Phase 1 (`planner::validate_operation`) rejects an impossible `(engine, op)` pair using `supports_op` plus the `max_batch_size` ceiling — a clean `UnsupportedCapability` raised *before* a pool is opened. Phase 2 (`plan::plan`) reads the *shape* of the op (`OpShape`: pattern-search? join? grouped aggregate? stream/transaction requested?) and routes by the engine's advertised *cost* capabilities via a `const` rule table — never by engine name. The verdict is `Native`, `Federate` (dormant — lowered to `NotImplemented` until the analytics plane is wired), or `Reject`. A separate **tier gate** (`planner::tier_gate`) narrows the descriptor by a tenant's package mask and raises `CapabilityGated` (403) when the engine *can* but the package tier *won't*.

**Isolation is parsed once into a typed strategy.** A mount carries a wire `isolation` string; `isolation.rs` parses it exactly once into the `Isolation` enum (`SharedRls` / `SchemaPerTenant` / `DbPerTenant` / `TenantOwned`), then produces an engine-neutral `ScopeDirective` (`None` / `SetSearchPath` / `UseNamespace`) that each adapter consumes on its own terms. The default and the parity path is `SharedRls` → `ScopeDirective::None` for every engine, so existing mounts are byte-identical. `safe_schema` derives a collision-free, injection-safe `tenant_<fragment>_<hash8>` identifier shared by Postgres `search_path` lowering and provisioning DDL.

**The `ports` traits are the seam.** `EngineAdapter`, `EnginePool`, `PoolRegistry`, `TxHandle` (`ports.rs`) are the contract between this crate and `data-plane-pool`. Core defines them with sensible `NotImplemented` defaults (so engines opt *in* to raw statements, introspection, DDL, and migrations); the pool crate implements them; the server holds `Box<dyn EnginePool>` and never knows the concrete engine type. A `DatabaseMount` (`mount.rs`) is what flows through all of these — it names the engine, tenant, credential reference, pool policy, and isolation, and computes its own `pool_key` / `effective_pool_key`.

## File-by-file

### `src/lib.rs`
**Purpose:** Module declarations and the public re-export surface of the crate.
**Key items:** `pub mod` for all 13 modules, then a flat `pub use` of the important types (`EngineCapabilities`, `DataPlaneError`, `Filter`, `plan`, `validate_operation`, `Isolation`, `DatabaseMount`, `DataOperation`, the `ports` traits, `SchemaDescriptor`, `SchemaDdlRequest`, `TxSession`, …).
**How it connects:** Everything downstream imports from `data_plane_core::*` rather than reaching into submodules.

### `src/capability.rs`
**Purpose:** The capability-descriptor vocabulary — the single source of truth the planner/validator gate on.
**Key types / functions:**
- `EngineCapabilities` — the per-engine descriptor: op flags (`read`, `write`, `upsert`, `batch`, `aggregate`, `stream`), route flags (`introspect`, `schema_ddl`, `ddl`), transaction facets (`transactions`, `savepoints`, `isolation_levels: Vec<IsolationLevel>`, `two_phase_commit`, `native_idempotency`), `max_batch_size`, and a `CostCapabilities`. Newer flags carry `#[serde(default)]` for wire back-compat.
- `EngineCapabilities::supports_op(&DataOperationKind) -> bool` — derives op support from the flags; the gate the planner uses. Route flags (`introspect`/`schema_ddl`) deliberately never appear here.
- Per-engine constructors: `postgresql()`, `cockroachdb()`, `mongodb()`, `mysql()`, `mariadb()`, `sqlite()`, `mssql()`, `redis()`, `dynamodb()`, `http()` — each with extensive honesty call-outs (e.g. mongo advertises `schema_ddl: true` but `ddl: false`; dynamodb is the only adapter that can honestly set `native_idempotency: true` via `ClientRequestToken`).
- `CostCapabilities { latency_class, pattern_search, joins }` over the enums `LatencyClass`, `PatternSearchCapability`, `JoinCapability`, plus `IsolationLevel` (`ReadCommitted`/`RepeatableRead`/`Serializable`/`Snapshot`).
**How it connects:** Read by `planner::validate_operation`, `planner::apply_capability_overrides`, `plan::plan` (the cost rules are predicates over this type), and returned by every `EngineAdapter::capabilities()`.

### `src/error.rs`
**Purpose:** The error type whose variants map to HTTP status codes in the server.
**Key types:** `DataPlaneError` (a `thiserror` enum) and `DataPlaneResult<T>`. Variants encode the status contract: `UnsupportedCapability` (engine genuinely can't — 422/400), `CapabilityGated` (tier-masked — 403), `Conflict` (integrity violation — 409), `InvalidRequest` / `InvalidIdentifier` (4xx), `Backend` (engine/transport — 5xx), `NotImplemented`, plus mount/transaction/credential lookup variants (`MountNotFound`, `TransactionNotFound`, `CredentialUnavailable`, `CredentialProviderFailed` — which never carries the DSN).
**Key fn:** `DataPlaneError::prefix_message(prefix, err)` re-wraps a free-text error's message (e.g. `batch item 3: …`) while preserving the variant, so the mapped HTTP status survives.
**How it connects:** Returned everywhere; the planner builds `UnsupportedCapability` / `NotImplemented`, the validator builds `UnsupportedCapability` / `CapabilityGated`, the DDL contracts build `InvalidRequest`.

### `src/filter.rs`
**Purpose:** The engine-neutral filter AST — "one tree, many backends." A MongoDB-style `$`-operator JSON is parsed and validated **once**, then each adapter lowers the tree to its own dialect.
**Key types / functions:**
- `Filter` — the validated predicate tree: `And` / `Or` / `Not` / `Cmp{field,op,value}` / `In` / `Like{ci}` / `Between` / `IsNull{negate}`. Values stay `serde_json::Value` for the adapter to bind.
- `CmpOp` — `Eq/Ne/Lt/Lte/Gt/Gte`.
- `Filter::parse(&Value)` — parses+validates the wire grammar (sorted keys → deterministic lowering); rejects `$`-prefixed field names (no `$where` injection), unknown operators, and `$in` lists over `MAX_IN_LEN` (1000).
- `Filter::fold() -> Folded` — constant-folds to `AlwaysTrue` / `AlwaysFalse` / `Constrained`. Mutation guards use this to refuse a full-table update/delete (an `AlwaysTrue` filter), exactly as they refuse an empty one.
**How it connects:** Adapters in `data-plane-pool` call `Filter::parse` and lower; `plan::filter_has_pattern_search` walks the *raw* filter JSON (no second parse) to set `OpShape::requires_pattern_search`.

### `src/identity.rs`
**Purpose:** The verified caller identity threaded through every operation.
**Key types:** `RequestIdentity { tenant_id, project_id, app_id, user_id, roles, scopes, source }` and `IdentitySource` (`SignedEnvelope`/`Jwt`/`ServiceToken`/`Test`).
**Key fn:** `RequestIdentity::is_tenant_scoped()` — whether `tenant_id` is non-empty.
**How it connects:** Passed into `EnginePool::execute`, `describe_schema`, `apply_schema_ddl`, `apply_migration`, `TxHandle::execute`, and `Isolation::scope`. Adapters re-apply tenant scoping (e.g. `app.current_tenant_id`) per checkout from this identity, which is what makes shared pools safe.

### `src/isolation.rs`
**Purpose:** Tenant isolation strategy (gap G5) — parse the mount's `isolation` string once, produce an engine-neutral scoping instruction.
**Key types / functions:**
- `Isolation` (`Copy`) — `SharedRls` (default; RLS + `owner_id`), `SchemaPerTenant` (pin `search_path`/namespace to `tenant_<id>`), `DbPerTenant` (separation lives in the DSN), `TenantOwned` (an external client DB; **no** owner-scoping on writes/DDL).
- `Isolation::from_mount(Option<&str>)` — never errors; absent/empty/unknown degrades to `SharedRls` (parity).
- `Isolation::owner_scoped()` — `true` for everything except `TenantOwned`; pools gate every owner-touching site on this.
- `Isolation::scope(&DatabaseMount, &RequestIdentity) -> ScopeDirective` — branchless match: `SharedRls`/`DbPerTenant`/`TenantOwned` → `None`; `SchemaPerTenant` → `SetSearchPath` (Postgres) or `UseNamespace` (mysql/mongo/redis/dynamodb) or `None` (http/unknown).
- `ScopeDirective` — `None` / `SetSearchPath{schema}` / `UseNamespace{namespace}`.
- `safe_schema(tenant_id) -> Option<String>` — derives the collision-free `tenant_<fragment>_<hash8>` identifier (FNV-1a `tenant_hash8` suffix over the **raw** id), sanitized to `[a-z0-9_]`, fragment capped at 40 chars to fit Postgres's 63-byte cap; `None` when the id sanitizes to empty.
**How it connects:** `DatabaseMount::isolation()` / `tenant_schema()` delegate here; adapters consume the `ScopeDirective`; provisioning DDL shares `safe_schema`.

### `src/mount.rs`
**Purpose:** The `DatabaseMount` — the descriptor of a tenant's database that flows through pools and adapters — plus pool-keying.
**Key types / functions:**
- `DatabaseMount { id, tenant_id, project_id, engine, name, credential_ref, pool_policy, capability_overrides, inline_dsn, isolation }`.
- `CredentialRef { provider, reference, version }` — how the credential is resolved (Vault / adapter-registry); `version` participates in pool keys so a rotation forks a fresh pool.
- `PoolPolicy { min, max, idle_ttl_ms, max_lifetime_ms }` (`Default`: 0/10/30s/30min).
- `DatabaseMount::pool_key()` — the per-tenant pool identity (`tenant/project/id/engine/cred-version`).
- `DatabaseMount::effective_pool_key(share_shared_rls)` — **B4-pools**: when sharing is on AND the mount is `SharedRls`, the key becomes the connection *target* (a non-reversible `stable_hash` of the inline DSN, else the credential ref) — not the tenant — so every tenant pointing at one physical DB collapses to one pool. Safe only for `shared_rls` (its tenant scoping is re-applied per checkout). With sharing off it's byte-identical to `pool_key()`.
- `DatabaseMount::isolation()` / `tenant_schema()` — typed delegators into `isolation.rs`.
**How it connects:** Passed to `EngineAdapter::open_pool`, `PoolRegistry::get_or_create`, and `TxBeginRequest`; `PoolRegistry::drain_pool_key` / `pin_tx` key off `pool_key`.

### `src/operation.rs`
**Purpose:** The operation request/response wire shapes — what a data request *is* and what it returns.
**Key types / functions:**
- `DataOperationKind` — `List/Get/Insert/Update/Delete/Upsert/Batch/Aggregate`, with `ALL` (the canonical 8-element array for exhaustive iteration) and `wire_name()`.
- `DataOperation { op, resource, data, filter, sort, limit, offset, idempotency_key, expected_version, returning, aggregate, fields }` — the request. `DataOperation::project_rows` strips non-requested columns post-fetch; `DataOperation::batch_items` parses+validates the batch payload (non-empty array, no nested batches, each item has a `resource`).
- Aggregation: `AggFunc` (`Count/Sum/Avg/Min/Max`, an allowlist), `Aggregate { func, field, distinct, alias }`, `AggregateSpec { group_by, aggregates }`.
- `ReturningMode` (`None/Changed/Full`).
- `DataResult { rows, affected_rows, next_cursor, batch }` with batch envelopes `BatchSummary { atomic, items }`, `BatchItemOutcome { index, status, affected_rows, error }`, `BatchItemStatus` (`Ok/Error/Skipped`).
**How it connects:** `DataOperation` is the argument to `EnginePool::execute` / `TxHandle::execute`, the input to `validate_operation` and `plan`, and the source of `OpShape`. `DataResult` is the return.

### `src/plan.rs`
**Purpose:** Capability-aware routing (gap G6) — the two-phase planner that decides where an operation runs.
**Key types / functions:**
- `plan(op, engine, caps, ctx, federation_enabled) -> PlanDecision` — Phase 1 calls `validate_operation`; Phase 2 computes `OpShape::of` and walks the `const COST_POLICY` table (stream/transaction rules first → `Reject`; pattern-search/join-or-analytical after → may federate). Plain CRUD matches no rule → `Plan::Native`.
- `Plan` — `Native` / `Federate{target}` / `Reject(DataPlaneError)` (intentionally not `Clone`/`Eq`); `Plan::federation_target()` lets tests assert the target.
- `PlanDecision { plan, reason: &'static str }` — the decision plus a static log reason.
- `OpShape { requires_pattern_search, requires_joins, is_analytical, requires_stream, requires_transaction }` — pure booleans derived once. `requires_joins` is dormant (no join field on `DataOperation` yet).
- `WorkloadContext { stream_requested, in_transaction }` — request-level hints kept separate so `OpShape` stays pure.
- `resolve_federation(plan, enabled)` — the one-line seam: a `Federate` plan lowers to `NotImplemented` while federation is OFF (the default), so an unrunnable workload never "succeeds" silently.
- Internals: `CostRule` (fn-pointer predicates over `EngineCapabilities` — **no engine-name literal in the file**), `ShapeReq`, `Verdict`, `ANALYTICS_TARGET` ("analytics", a role token).
**How it connects:** Called by `data-plane-server` per request; reuses `validate_operation` for Phase 1; reads `EngineCapabilities` cost fields.

### `src/planner.rs`
**Purpose:** Phase-1 pre-flight validation and Phase-4 tiering — turning capability flags into clean contract errors before dispatch.
**Key functions:**
- `validate_operation(op, engine, caps) -> DataPlaneResult<()>` — rejects with `UnsupportedCapability` when `!supports_op`, and rejects a batch whose array length exceeds `max_batch_size`. Pure, conservative, parity-safe.
- `required_capability(kind) -> &'static str` — the flag name for the error message (`read`/`write`/`upsert`/`batch`/`aggregate`).
- `apply_capability_overrides(caps, overrides) -> EngineCapabilities` — **narrowing only**: an explicit `false` in the tenant's mask removes a capability; absent/`true`/non-bool leaves it; a package can never *widen* past the engine descriptor.
- `tier_gate(op, caps, overrides) -> DataPlaneResult<()>` — raises `CapabilityGated` (403) when the engine supports the op but the package mask removes it; a no-op without a mask or when the engine already can't (so the planner's reject fires instead).
**How it connects:** `validate_operation` is reused by `plan::plan` Phase 1; the server applies `tier_gate` using `DatabaseMount::capability_overrides` (stamped from the key-verify response).

### `src/ports.rs`
**Purpose:** The async trait seam between this crate and `data-plane-pool` — the abstractions the concrete adapters implement.
**Key traits:**
- `EngineAdapter` — `engine()`, `capabilities()`, `supported_ops()` (the dispatch source of truth the honesty test checks against the descriptor), `open_pool(mount)`, `health_check(pool)`.
- `EnginePool` — `mount_id()`, `execute(op, identity)`, `begin(TxBeginRequest)`, `close()`, plus default-`NotImplemented` opt-ins: `execute_raw(RawStatement, …)` (admin-gated raw SQL/command), `describe_schema(identity)` (M22 introspection), `apply_schema_ddl(SchemaDdlRequest, …)` (single-op DDL), `apply_migration(MigrationRequest, …)` (atomic named migration with a `_baas_migrations` marker).
- `TxHandle` — `tx_id()`, `mount_id()`, `execute()`, `commit()`, `rollback()`, `prepare()`.
- `PoolRegistry` — `get_or_create(mount)`, `release_idle()`, `close_mount()`, `stats()`, plus default-no-op `pin_tx`/`unpin_tx` (keep a pool alive during an in-flight tx) and `drain_pool_key` (the credential-rotation hook for gap G8, keyed on `pool_key` so it only drains the old cred version).
**Key types:** `RawStatement { statement, params, expect_rows }`, `MigrationRequest { name, statements }`, `MigrationResult { name, status, statements_run }`, `MigrationStatus` (`Applied`/`Skipped`), `EngineHealth`, `PoolStats`.
**How it connects:** Implemented entirely in `data-plane-pool`; held as `Box<dyn …>` by `data-plane-server`.

### `src/schema.rs`
**Purpose:** The engine-agnostic schema-introspection wire contract (M22) returned by `POST /v1/schema`.
**Key types:** `SchemaDescriptor { engine, tables }`, `TableSchema { name, primary_key, columns }`, `ColumnSchema { name, native_type, normalized_type, nullable, default, enum_values, references, inferred }`, `ForeignKeyRef { table, column }`, and `NormalizedType` (`Text/Integer/Float/Decimal/Boolean/Date/Datetime/Json/Uuid/Enum/Array/Objectid/Unknown` — snake_case on the wire; unmappable → `Unknown`). `inferred: true` marks sample-based guesses (Mongo without a `$jsonSchema` validator).
**How it connects:** Returned by `EnginePool::describe_schema`; forwarded verbatim by the TS query-router.

### `src/schema_ddl.rs`
**Purpose:** The engine-agnostic, single-operation schema-DDL contract (M22 step 2) for `POST /v1/schema/ddl`.
**Key types / functions:**
- `SchemaDdlOp` — `AddColumn/DropColumn/AlterColumnType/CreateTable/DropTable` (snake_case; `as_str()`).
- `SchemaDdlRequest { op, table, column, column_name, columns, primary_key }` with `require_column()` / `require_column_name()` / `require_create_spec()` validators that enforce which optional field each op needs (and that every PK column is a declared column or the auto-appended `owner_id`).
- `DdlColumnDef { name, normalized_type, nullable, default, enum_values }` — for `alter_column_type` the caller supplies the FULL target def (MySQL `MODIFY COLUMN` resets every attribute).
- `SchemaDdlResult { op, table, status }`, `SchemaDdlStatus::Applied`.
- `validate_default_expr(expr)` — guards a caller-supplied `DEFAULT` (interpolated, not bindable): rejects `;`, `--`, `/*`, and control characters; passes `0`, `'pending'`, `now()`, etc.
**How it connects:** Consumed by `EnginePool::apply_schema_ddl`; engines lower it through pure, identifier-validated builders. Single-op by contract because MySQL DDL self-commits.

### `src/transaction.rs`
**Purpose:** The transaction-session vocabulary.
**Key types:** `TxBeginRequest { identity, mount, isolation: Option<IsolationLevel>, timeout_ms }` (the argument to `EnginePool::begin`), `TxState` (`Open/Committed/RolledBack/Reaped`), `TxSession { tx_id: Uuid, tenant_id, mount_id, state, opened_at, expires_at }`.
**How it connects:** `TxBeginRequest` feeds `EnginePool::begin`, which returns a `Box<dyn TxHandle>`; the server's transaction store tracks `TxSession` lifecycle.

## Key flows

**1. A CRUD request → plan → validate → dispatch.**
A `DataOperation` arrives at `data-plane-server` with a resolved `DatabaseMount` and `RequestIdentity`. The server calls `plan(&op, &mount.engine, &caps, &ctx, federation_enabled)`:
- **Phase 1** — `plan` delegates to `validate_operation`. `caps.supports_op(&op.op)` is the gate; for a `Batch`, the array length is also checked against `caps.max_batch_size`. A `List`/`Get` needs `read`, `Insert`/`Update`/`Delete` need `write`, `Upsert` needs `upsert`, `Aggregate` needs `aggregate`. Failure → `Plan::Reject(UnsupportedCapability)` (mapped to 4xx) before any pool opens.
- **Phase 2** — `OpShape::of(&op, &ctx)` computes the shape. Plain CRUD has an empty shape, matches no `COST_POLICY` rule, and returns `Plan::Native`.
- The server (separately) applies `tier_gate(&op, &caps, mount.capability_overrides.as_ref())` — if the tenant's package mask narrowed the op away, that's `CapabilityGated` (403).
- On `Native`, the server resolves the mount's `effective_pool_key`, gets/creates a `Box<dyn EnginePool>` via `PoolRegistry::get_or_create`, applies the `ScopeDirective` from `mount.isolation().scope(&mount, &identity)`, and calls `pool.execute(op, identity)` → `DataResult`.

**2. A `$ilike` filter against an engine that can only do it remotely.**
A `List` carries `filter = {"name": {"$ilike": "ab%"}}`. Phase 1 passes (`read` is true everywhere). In Phase 2, `filter_has_pattern_search` flags `OpShape::requires_pattern_search = true`. The `ShapeReq::PatternSearch` cost rule fires; its `satisfied_by` predicate inspects `caps.cost.pattern_search`:
- `redis` is `Scan` → satisfied → `Plan::Native` (it serves `$like` locally).
- `http` is `Remote` → not satisfied; the rule's `can_federate` predicate is true → `Verdict::FederateOrReject` resolves to `Plan::Federate{target:"analytics"}`. With federation OFF (default), `resolve_federation` lowers that to `Plan::Reject(NotImplemented)` — the workload never silently succeeds. Flip `federation_enabled` and the same op resolves to `Federate{analytics}`.

A grouped `Aggregate` (`group_by` non-empty) follows the analogous `JoinOrAnalytical` rule: an engine with `joins: None` (and `aggregate` somehow enabled) federates → `NotImplemented` while OFF, while Postgres (`joins: Native`) stays `Native`.

## Build / feature notes

- **No feature flags.** `Cargo.toml` declares no `[features]`; engine selection (including the OFF-by-default DynamoDB adapter) lives in `data-plane-pool` / the workspace, not here.
- **Dependencies are minimal and all `workspace = true`:** `async-trait` (the `ports` traits), `chrono` (transaction timestamps), `serde` + `serde_json` (wire contracts), `thiserror` (`DataPlaneError`), `uuid` (`TxSession::tx_id`). Notably **no DB drivers, no hashing crate** — `isolation::tenant_hash8` is a hand-rolled FNV-1a precisely to avoid pulling `sha2`/`blake` into this crate.
- **`version`/`edition`/`rust-version` inherit from the workspace** (`version.workspace = true`, etc.).
- **Wire back-compat is a standing rule:** newer `EngineCapabilities` flags (`batch`, `aggregate`, `introspect`, `schema_ddl`) and several `DataOperation` / DDL fields use `#[serde(default)]` so a descriptor or payload serialized before a field existed still deserializes — with the honest `false`/`None` default.
- **Tests live inline** (`#[cfg(test)] mod tests` in most files) and are pure/fast since the crate has no I/O; they pin the honesty invariants (e.g. route capabilities never leak into `supports_op`, `safe_schema` is collision-free, masks narrow-only).
