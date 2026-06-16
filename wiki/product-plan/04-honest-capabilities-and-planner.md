# 04 — Honest capabilities & the capability-aware planner

> Make the platform tell the truth, then make the truth route. The cost model (`EngineCapabilities.cost`) is the connective tissue between "all operations" (03) and "OLAP/OLTP" (05).

## Problem

1. **The descriptors lie.** `EngineCapabilities::postgresql()` (`capability.rs`) advertises `write:true, upsert:true, transactions:true` — but `postgres.rs` implements none of update/delete/upsert. The descriptors are hand-written constants, decoupled from the adapters.
2. **The planner trusts the lie.** The `validate_operation` I added (`planner.rs`) checks the *advertised* caps, so it waves an `update` through to an adapter that then 501s. It prevents *some* impossible ops but rubber-stamps unimplemented ones.
3. **The SDK trusts the lie.** `sdk/src/generated/engines.ts` is generated from `/v1/capabilities`, and the SDK's compile-time typing (`.upsert()` only if `upsert:true`) is therefore **type-safe over a falsehood** — it lets you call `.update()` on Postgres at compile time, then fails at runtime.
4. **The cost model is unused.** `cost { latency_class, pattern_search, joins }` exists and is surfaced at `/v1/capabilities`, but nothing reads it to route.

## Target

- **Capabilities are derived from what the adapter actually dispatches** — a descriptor cannot claim an op the code doesn't run.
- **`/v1/capabilities` reports implemented reality**, including the new feature flags (aggregate, cursor, search, joins) and the cost model.
- **The planner is the routing brain**: validate the [02 operation](02-operation-contract.md) against real caps, then decide *native / federation / reject* using `cost` — the hook 05 plugs into.
- **The SDK regenerates** from honest capabilities; its compile-time typing becomes true.

## Design

### 1. Make capabilities derive from the adapter

Add a per-engine **supported-operations set** that the adapter owns, and assert the descriptor matches it:

```rust
trait EngineAdapter {
  fn capabilities(&self) -> EngineCapabilities;
  fn supported_ops(&self) -> &'static [DataOperationKind];   // NEW — the truth
  fn supported_features(&self) -> EngineFeatures;            // NEW — agg/joins/search/cursor
}
```

`EngineCapabilities` is *computed* from `supported_ops`/`supported_features` (or a debug-assert that they agree). A startup self-check (and `make verify-m18`) fails if a descriptor advertises an op not in `supported_ops`. **No more lying by construction.**

### 2. The planner: validate → plan → route

```rust
enum Plan {
  Native,                       // run in the engine adapter
  Federate { engine: "trino" }, // route to Trino (05)
  Reject(DataPlaneError),       // honest 422
}

fn plan(op: &DataOperation, caps: &EngineCapabilities, ctx: &WorkloadContext) -> Plan {
  // 1. hard requirements (must be IMPLEMENTED, not just advertised)
  if !caps.implements(op.kind) { return Reject(UnsupportedCapability{..}); }
  if op.search.is_some() && caps.cost.pattern_search == None { return route_or_reject(...); }
  // 2. shape-based routing by COST
  if op.is_heterogeneous_join() || op.is_analytical(ctx) {
     if caps.cost.joins == None || ctx.prefers_olap() { return Federate{ "trino" }; }
  }
  Native
}
```

- **`is_analytical`** = has aggregation/group_by, or scans a large range, or the tenant's **workload context** (05) is OLAP. This is where 04 hands off to 05.
- Until 05 lands, `Federate` simply `Reject`s with a clear "needs analytics plane" message — additive and safe.

### 3. New capability flags (honest)

Extend `EngineCapabilities` with what 03 implements:

```rust
pub struct EngineCapabilities {
  // … existing …
  pub aggregate: bool,
  pub joins_native: bool,       // (replaces the buried cost.joins for the planner)
  pub search: SearchCapability, // none|like|fulltext
  pub cursor_pagination: bool,
  pub batch: bool,
}
```

These flip **only** when the adapter implements them (tied to 03's slices). The descriptor and the SDK move together.

### 4. SDK truth (link to 08)

- `sdk/scripts/codegen-engines.mjs` regenerates `generated/engines.ts` from the **honest** `/v1/capabilities`.
- `MiniBaasClient.introspectEngines()` already drift-checks static vs live — extend it to fail if a *feature* (agg/join/search) drifts, not just engine ids.
- The fluent builder (02) types `.update()/.aggregate()/.join()/.search()` as present **only** when the live capability says so — now truthfully.

## Slices

1. **S1 — `supported_ops` + self-check.** Each adapter declares its real ops; startup + `verify-m18` fail on mismatch. *This alone makes the platform honest* (Postgres descriptor will correctly stop claiming update until 03/A1 lands).

> **✅ Delivered (2026-06) — S1 (descriptor side), 5-agent hardened, live-verified.**
> - **Single source of truth:** `EngineCapabilities::supports_op(kind)` (capability.rs)
>   maps every op→flag; the planner (`validate_operation`) gates on it, so a flag
>   and its op can't disagree.
> - **Closed lies:** added an honest `batch: bool` (`false` ×5 — no adapter
>   implements `Batch`); fixed `mongodb transactions: true → false` (its `begin()`
>   is NotImplemented). Live: `/v1/capabilities` now reports `batch:false` ×5 and
>   mongo `transactions:false`; a `batch` op → **HTTP 400** `unsupported_capability`
>   (was a 501 deep in the adapter).
> - **Enforced, not just asserted (5-agent finding):** the descriptor is now also
>   checked on the **non-query routes** — `/v1/transactions` `begin` gates on
>   `transactions`, `/v1/admin/migrate` gates on `ddl` (new `require_capability`
>   helper in routes.rs). Live: `begin` on mongo → **400** (was 501); on postgres
>   → 201.
> - **Closed the one real reachable lie:** MySQL advertised `ddl:true` but had no
>   `apply_migration` → implemented `MysqlPool::apply_migration` (idempotent
>   `_baas_migrations` marker; documented MySQL's implicit-commit-on-DDL = non-
>   atomic batch, unlike Postgres).
> - **No-lying gate wired:** `capability_honesty.rs` (3 tests pinning descriptor ⟺
>   dispatch reality, `batch=false`, tx-flag⟺`begin()`); `make verify-m18` now runs
>   `cargo test` for it (was `cargo check` only). Tests: core 11 / pool 57 / server 11.
>
> **✅ Delivered (2026-06) — S1b: `supported_ops()` first-class + load-bearing, 3-agent hardened.**
> - `EngineAdapter::supported_ops(&self) -> &'static [DataOperationKind]` is now a
>   **required** trait method; each adapter declares a `pub(crate) const SUPPORTED_OPS`.
> - **Load-bearing both ways:** every adapter's `dispatch_op` *gates* on the const
>   (`if !SUPPORTED_OPS.contains(&op) → NotImplemented`), so the const drives what
>   dispatch accepts (descriptor↔const tie); and the dispatch match is now
>   **exhaustive by enumeration** (the `other =>` wildcard replaced by an explicit
>   `Batch =>` arm) so deleting a CRUD handler is a **compile error** (const↔arms
>   tie). The honesty test reads the real `crate::<mod>::SUPPORTED_OPS` consts —
>   no more hand-mirror.
> - **Boot self-check:** `assert_capability_honesty(&adapters)` in `AppState::new`
>   fails fast (panics) if any descriptor disagrees with `supported_ops()` — both
>   compile-time constants, so never runtime-triggerable.
> - De-duplicated the "all op kinds" array behind `DataOperationKind::ALL`.
>   Tests core 11 / pool 57 / server 11; `make verify-m18` PASS.
>
> **Still deferred. Inert (not lies, no op consumes them yet):** `stream`,
> `savepoints`, `two_phase_commit`, `cost.{joins,pattern_search}`,
> `isolation_levels` — advisory metadata until a join/search/stream op exists.
> **Pre-existing (record for [08](08-sdk-graphql-and-e2e-tests.md)):** the TS
> query-router `rustForwardedCaps()` stub + SDK baseline disagree with the Rust
> descriptor (e.g. postgres `upsert`) — the SDK is generated from the TS stub, not
> `/v1/capabilities`; unify in 08.
2. **S2 — Capability flags follow 03.** As each 03 slice implements an op/feature, flip the flag in the same PR. Capability and implementation are never out of sync again.
3. **S3 — Planner `plan()` with cost-based `Native|Reject`.** Wire into `execute_query` (replacing today's static allow-list + advertised-cap check).
4. **S4 — `Federate` hook** (stubbed to Reject), handed to 05.
5. **S5 — SDK regen + drift gate.**

## Verification

- **`verify-m18` "no-lying" assertion** — descriptor ⊆ implemented ops, for every engine. This is the permanent guard.
- Planner unit tests: op×caps×context → expected `Plan` (table-driven, pure).
- SDK type tests (`sdk/src/__type_tests__`) updated so `.update()` on Postgres is a *compile error* until A1 ships, then compiles — proving the typing tracks reality.

## Why this is sequenced before 05 and 08

- 05's routing **is** the planner's `Federate` branch — it needs the planner honest and cost-aware first.
- 08's SDK typing is only worth shipping once it tells the truth — otherwise you ship a type-safe lie.

## Risks

- **Self-check churn.** Making descriptors honest will *correctly* shrink advertised Postgres caps until 03/A1 lands — surface this as expected (the brochure briefly admits the gap, then 03 closes it). That's the point: honesty first.
- **Cost-model subjectivity.** `latency_class`/`joins` are coarse. Keep routing decisions explainable (log the chosen `Plan` + reason) so 05's behavior is debuggable.
