# 02 — The universal operation contract

> The spine of the product. Everything else (03 adapters, 04 planner, 05 OLAP/OLTP routing, 08 SDK/GraphQL) consumes this one shape. Get it right once.

## Problem

Today's `DataOperation` (`crates/data-plane-core/src/operation.rs`) is a thin CRUD envelope:

```rust
pub struct DataOperation {
  pub op: DataOperationKind,                 // List|Get|Insert|Update|Delete|Upsert|Batch
  pub resource: String,
  pub data: Option<Value>,
  pub filter: Option<Value>,                 // opaque blob → only `col = val` equality today
  pub sort: Option<BTreeMap<String,String>>, // single map, no direction semantics enforced
  pub limit: Option<u32>, pub offset: Option<u32>,
  pub idempotency_key: Option<String>,
  pub expected_version: Option<Value>,
  pub returning: Option<ReturningMode>,
}
```

`build_where` in `postgres.rs` only emits `col = $n AND …`. There is **no** representation for: comparison/`IN`/`LIKE`/range operators, OR-groups, multi-key sort with direction, **cursor** pagination, **projection/select**, **aggregations**, **relationships/joins**, **search**. So the contract *cannot express* "beyond CRUD" — fixing adapters first would be building on sand.

## Target — a typed, engine-neutral operation model

Extend (don't replace) `DataOperation` with structured, optional sub-models. All additive (`#[serde(default)]`) so existing `{op, resource, filter:{...}}` traffic keeps working.

```rust
pub struct DataOperation {
  pub op: DataOperationKind,
  pub resource: String,
  pub data: Option<Value>,
  pub filter: Option<Filter>,        // structured predicate tree (was opaque Value)
  pub select: Option<Vec<Projection>>,   // columns / computed / aggregates
  pub sort: Vec<SortKey>,            // ordered, with direction + nulls
  pub page: Option<Page>,            // limit/offset OR cursor
  pub joins: Vec<Join>,              // relationships (engine- or federation-served)
  pub group_by: Vec<String>,
  pub having: Option<Filter>,
  pub search: Option<Search>,        // full-text / pattern
  pub idempotency_key: Option<String>,
  pub expected_version: Option<Value>,
  pub returning: Option<ReturningMode>,
}
```

### Filter — a safe predicate tree

```rust
pub enum Filter {
  And(Vec<Filter>), Or(Vec<Filter>), Not(Box<Filter>),
  Cmp { field: String, op: CmpOp, value: Value },   // eq ne lt lte gt gte
  In  { field: String, values: Vec<Value> },
  Like{ field: String, pattern: String, ci: bool }, // → pattern_search capability
  IsNull { field: String, negate: bool },
  Between{ field: String, low: Value, high: Value },
}
```

Every `field` is validated against `^[a-zA-Z_]\w{0,63}$`; every `value` is a **bound parameter**. The tree compiles to SQL (`build_where` becomes a recursive compiler), to a Mongo filter doc, to a Redis scan predicate, to Trino SQL — one tree, many backends.

> **✅ Delivered (2026-06) — the typed `Filter` AST + MySQL lowering, 5-agent hardened, live-verified.**
> `data-plane-core::filter` now has `Filter` (And/Or/Not/Cmp/In/Like/Between/IsNull)
> + `CmpOp` + `Filter::parse(&Value)` — the engine-agnostic `$`-grammar parsed and
> validated ONCE (operator allowlist, field rules, `$in` cap). **MySQL lowers it**
> (`lower_filter`), fixing a real bug: the old code bound `{$gte:18}` as a literal
> value → matched zero rows; now operators work (live: `age>=18` filters correctly).
> - **`Filter::fold()` → `Folded`** does constant-folding in the AST, so every SQL
>   engine gets the mutation guard for free — MySQL update/delete now refuse an
>   empty/tautology (`{$not:{$or:[]}}`) filter (live: → 400, parity with Postgres).
> - **🔒 CRITICAL fix (the 5-agent review caught what the security agent missed):**
>   `build_owner_filter`/`build_where` joined the client filter with the trusted
>   `owner_id` via a bare ` AND `, so a top-level `$or` parsed as
>   `(a) OR (b AND owner_id)` — the `a` branch **unscoped** (cross-owner leak on
>   MySQL, which has no RLS). Fixed by parenthesizing the whole client filter
>   `(…) AND owner_id = ?` on both MySQL and Postgres. **Live-verified:** a peer
>   tenant's row matching one `$or` branch does NOT leak.
> - Tests: core 16, pool 75.
>
> **Migration backlog (the architect's sequence — do before doc 05 Trino):**
> 1. **✅ Done (2026-06):** Postgres migrated off its inline grammar onto
>    `Filter::parse` + a new `lower_pg`/`lower_and`/`lower_or` (deleted ~120 lines
>    of duplicate parser + the `MAX_IN_LEN` dup). `compile_filter` is now a thin
>    wrapper. **Behavior-identical** — 75 pool + 16 core tests pass unchanged
>    (incl. injection, tautology data-loss guard, all operators, exact SQL shape);
>    1-agent verified faithful + safe; live-verified ($gte filters, $or+$like,
>    tautology delete→400). **Postgres + MySQL now share one grammar/validation;**
>    only the dialect lowering (`$n`+ILIKE vs `?`+LOWER) is per-engine.
> 2. Migrate **Mongo** onto `Filter` (lower to BSON), replacing its allowlist and
>    converging the grammar; extend `Filter` for the cross-engine ops it needs.
> 3. Extract a small **`SqlDialect`** (`quote_ident` / placeholder / `ilike`) so
>    Postgres (`$n`), MySQL (`?`), and the Trino adapter share one `lower<D>`.
> 4. A **`filter_operators` capability** (None/IdOnly/Comparison/Full) so Redis/HTTP
>    (which ignore operators today) are honest, and the planner can reject. ([04](04-honest-capabilities-and-planner.md))

### Value coercion — one policy, reused by every adapter (scheduled)

> Surfaced by the A1.1 review (5 agents): the JSON→engine value mapping is
> currently decided **per adapter**, and they diverge. Postgres' `JsonParam`
> rejects an out-of-range `int4` with a clean error; MySQL does
> `as_f64().unwrap_or(0.0)` (silent). That is the "engine semantic drift"
> [03](03-engine-adapters-full-crud-and-rich-reads.md) warns about.

Two concerns are tangled and must be split by layer:

- **Coercion policy (engine-neutral)** — "is `3.0` a valid integer?", "is this
  string a UUID/timestamp?", overflow = reject. This belongs in the contract
  layer as a shared `coerce(value, LogicalType) -> Result<Scalar, InvalidRequest>`
  written **once** and reused by all five adapters. A bad value is a **400**,
  uniformly, on every engine.
- **Wire encoding (engine-specific)** — the last-mile byte layout (`i32` vs `i64`
  binary for Postgres, BSON for Mongo). Stays in each adapter (e.g. Postgres'
  `JsonParam` becomes a thin shim over the shared `Scalar`).

This is the value-handling counterpart to the `Filter` compiler. Until it lands,
A1.1 ships the Postgres half (type-aware binding + honest rejection of
unsupported `numeric`/array/`bytea`/`time` columns — **no corruption**, but a
value/type mismatch is a 502 not yet a 400). Folding it in here also fixes:
`numeric` support (via `rust_decimal`), array columns (recurse on the array
element type), and the 502→400 reclassification of serialization mismatches.

### Projection / aggregation — the "beyond CRUD" reads

```rust
pub enum Projection {
  Field(String),
  Computed { expr: SafeExpr, alias: String },        // whitelisted functions only
  Agg { func: AggFunc, field: Option<String>, alias: String }, // count|sum|avg|min|max
}
```

Aggregations + `group_by`/`having` are what make it more than a key-value store. They map to SQL `GROUP BY`, Mongo aggregation pipeline, or Trino.

> **✅ Delivered (2026-06) — grouped aggregation (Postgres), 5-agent hardened, live-verified.**
> Shipped as a **first-class `DataOperationKind::Aggregate`** (not a `List` mode —
> see the divergence note below) with `AggregateSpec { group_by: Vec<String>,
> aggregates: Vec<Aggregate{ func, field, distinct, alias }> }`. `AggFunc` is an
> allowlist enum (count/sum/avg/min/max). Postgres `run_aggregate` →
> `SELECT to_jsonb(g) FROM (SELECT <group cols>, <func(arg) AS alias> FROM t
> WHERE <Filter> GROUP BY <group cols>) g ORDER BY … LIMIT $n`. Reuses the shared
> `Filter` compiler for WHERE; `count(*)`/`count(DISTINCT f)` supported; identifiers
> via `quote_ident`, function from the enum, values bound — **injection-safe**
> (security agent verdict: SAFE; isolation via RLS like `run_list`).
> - **Honest-capability gated:** `EngineCapabilities.aggregate` (Postgres `true`,
>   others `false`); the planner returns a clean **400 `unsupported_capability`**
>   on MySQL/Mongo/Redis/HTTP before dispatch. Pinned by the honesty test + boot
>   self-check + `make verify-m18`.
> - **Review fixes incorporated:** duplicate-output-column collision → 400 (was a
>   silent `to_jsonb` key-drop); `distinct` added to freeze the wire shape; planner
>   `aggregate_gated_by_capability` test.
> - Live: `GROUP BY region` count+sum sorted (east 230 / west 150), `avg`=95,
>   `count(DISTINCT)`=2, MySQL aggregate→400, collision→400. Tests core 17 / pool 76.
>
> **🐞 Follow-ups (architect):** (1) **Reconcile the op model** — this shipped the
> split `group_by`/`aggregates` shape; doc-02 above models aggregation as a `List`
> mode with a unified `select: Vec<Projection>`. These two "what columns come out"
> representations will collide when projection/computed-fields land — decide and
> document which is canonical. (2) Add **`having: Option<Filter>`** (reuses the
> `Filter` compiler). (3) When MySQL/Trino implement aggregate, **hoist the
> `func(arg) AS alias` assembly to core** (engine-neutral, like the Filter AST) so
> only `to_jsonb`/placeholder syntax stays per-dialect. (4) A `value/type` mismatch
> (e.g. `sum` on a text column, unknown group column) is a **502** not 400 — folds
> into the value-coercion work. (5) **Expose via the TS query-router** (`AdapterOp`
> /DTO/proxy/SDK don't carry `aggregate` yet — reachable only on the Rust plane).

### SortKey / Page — deterministic ordering & cursors

```rust
pub struct SortKey { pub field: String, pub dir: Dir, pub nulls: Nulls }
pub enum Page { Offset { limit: u32, offset: u32 }, Cursor { limit: u32, after: Option<String> } }
```

**Cursor pagination** (keyset) replaces deep `OFFSET` for large datasets — opaque base64 of the last sort tuple, validated against the requested `sort`.

### Join — relationships, engine- or federation-served

```rust
pub struct Join { pub resource: String, pub on: Vec<(String,String)>, pub kind: JoinKind, pub select: Vec<Projection> }
```

A join the engine can do natively (Postgres/MySQL `cost.joins == native`) runs in-engine; a cross-engine/heterogeneous join (`joins == none`) is **routed to Trino** (see [05](05-olap-oltp-unified-query-plane.md)). The contract is identical either way — that is the whole point.

## Capability mapping (the link to 04)

Each operation shape declares the **capabilities it requires**, so the planner (04) can accept/route/reject by *implemented* reality:

| Operation feature | Required capability |
|---|---|
| `Like`/`search` | `cost.pattern_search != none` |
| `joins` (in-engine) | `cost.joins == native\|limited` |
| `joins` (heterogeneous) | federation available (Trino plane up) |
| aggregations/`group_by` | `aggregate` (new cap flag) |
| `Cursor` page | `cursor_pagination` (new cap flag) |
| `Update`/`Delete`/`Upsert`/`Batch` | `write`/`upsert` **and adapter-implemented** |

## The SDK shape (the link to 08)

The SDK mirrors the contract as a fluent, capability-typed builder:

```ts
baas.engine('postgresql', dbId, 'orders')
  .select(['status', { agg: 'sum', field: 'total', as: 'revenue' }])
  .where({ status: { in: ['paid','shipped'] }, created_at: { gte: '2026-01-01' } })
  .groupBy('status').orderBy('-revenue').cursor(50)
  .run();                                 // ← .join(), .search() only typed when caps allow
```

## Slices (each independently shippable, all additive)

1. **S1 — Filter tree.** Add `Filter` to core; make `postgres.rs build_where` a recursive compiler; keep accepting the legacy `{col: val}` object (auto-translate to `And[Cmp eq]`). Unit-test the compiler (tree → SQL + params) exhaustively.
2. **S2 — Sort + offset/cursor.** `SortKey`/`Page`; keyset cursor encode/decode (pure, tested).
3. **S3 — Projection + aggregation + group_by/having.** Read path only.
4. **S4 — Joins (in-engine).** Native joins for relational engines; reject (clean 422) where unsupported — until 05 routes them to Trino.
5. **S5 — Search.** `Like`/pattern → relational; map to Mongo `$regex`/text index; Postgres `ILIKE`/`tsvector`.

Each slice extends the contract + the Postgres adapter first (reference impl), then 03 fans it out to the other engines.

## Verification

- **Pure unit tests** for every compiler (Filter→SQL, cursor codec, projection→SQL) — these are cheap and where correctness lives.
- **Property test**: random Filter trees never produce unparameterised SQL (fuzz the field/value injection surface).
- The contract change is `#[serde(default)]`-additive → existing `/v1/query` traffic and the TS proxy envelope are unaffected (verified by `make verify-m18`).

## Risks & guards

- **Injection surface grows.** Mitigate: identifiers validated centrally; values always bound; a single `quote_ident` + a `compile_filter` that *cannot* emit raw values. Add the fuzz test as a permanent gate.
- **Over-modeling.** Don't model what no engine implements. Ship S1–S3 (covers 90% of real use) before S4–S5.
- **Contract churn breaking the TS proxy.** The proxy builds the envelope; keep new fields optional and add them to `RustProxyContext`/proxy only as 03 implements them.
