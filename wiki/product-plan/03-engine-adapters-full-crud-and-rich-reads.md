# 03 — Engine adapters: full CRUD + rich reads

> Implement the [02 operation contract](02-operation-contract.md) in every adapter. **This is the product.** Until it lands, the platform is partial CRUD on 5 engines and the descriptors lie.

## Problem (measured, not assumed)

Actual `dispatch_op` coverage in `crates/data-plane-pool/src/*.rs`:

| Engine | list | get | insert | update | delete | upsert | batch | agg/join/search |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| **postgresql** | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| mongodb | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| mysql | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| redis | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| http | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |

**Postgres — the flagship — has no update/delete/upsert.** `postgres.rs::dispatch_op` falls through to `NotImplemented` for everything except List/Get/Insert. No engine does batch, aggregation, join, or search.

## Target

1. **Full CRUD on all engines** (Postgres U/D/upsert/batch first — it's the worst and most-used).
2. **Rich reads** (filter operators, projection, sort, cursor, aggregation) across all relational engines; best-effort on Mongo; honest rejection on Redis/HTTP where impossible.
3. Every implemented op flips a **real** capability flag (04) — the adapter is the source of truth, not the descriptor.

## Phase A — finish CRUD (close the embarrassing gaps)

### A1 — Postgres `update`/`delete`/`upsert` (highest priority)

`postgres.rs` already has the safe primitives: `quote_ident`, `json_param`, `build_where`, the RLS-context + tenant transaction. Adding the missing ops is mechanical and low-risk:

```rust
// dispatch_op:
DataOperationKind::Update => run_update(client, op, identity).await,
DataOperationKind::Delete => run_delete(client, op, identity).await,
DataOperationKind::Upsert => run_upsert(client, op, identity).await,
```

- `run_update`: `UPDATE {t} SET {col=$n,…} {WHERE …} RETURNING to_jsonb`. **Reuse `build_where`** for the predicate; bind every value; refuse an empty filter unless an explicit `all: true` (no accidental full-table updates).
- `run_delete`: `DELETE FROM {t} {WHERE …} RETURNING …`; same empty-filter guard.
- `run_upsert`: `INSERT … ON CONFLICT ({key}) DO UPDATE SET …`; key columns from `expected_version`/op metadata; re-inject trusted `owner_id` exactly as `run_insert` does.
- All run **inside the existing tenant transaction** with RLS GUCs set → tenant isolation preserved.

**Gate:** unit tests for SQL shape; live test that update/delete/upsert round-trip and that an empty-filter mutation is rejected. This single slice removes the most damaging gap.

> **✅ Delivered (2026-06) — A1 done, multi-agent hardened, live-verified.**
> `postgres.rs` now implements `update`/`delete`/`upsert` via pure, unit-tested
> SQL builders (`build_update_sql`/`build_delete_sql`/`build_upsert_sql` +
> `execute_mutation`). Four specialised review agents (security, DSA/perf,
> design, audit) audited the diff; **all critical findings were incorporated**:
> - **Correctness:** alias the table `AS t` so `to_jsonb(t)` is valid for
>   schema-qualified resources (also fixed the latent bug in `run_insert`);
>   upsert uses `query` (not `query_one`) with real `affected_rows`.
> - **Security:** `owner_id` forced into the upsert **conflict target**
>   `(owner_id, key…)` so ON CONFLICT arbitration is tenant-local; `owner_id`
>   predicate added to update/delete (defense-in-depth beyond RLS, matching
>   Mongo/MySQL); `request.jwt.claims` built with `serde_json` (no JSON-injection
>   of the RLS principal); `owner_id` immutable on update/upsert.
> - **Performance:** honor `ReturningMode::None` (count-only, no unbounded
>   materialisation); canonicalise (sort) column order to recover prepared-
>   statement cache hits.
> - **Tests:** 9 new unit tests (postgres.rs was the only adapter with none).
>
> **Live-verified:** insert/update/delete/upsert all 200; a cross-tenant update
> returns `affected:0`; an `owner_id`-steal attempt leaves ownership unchanged;
> empty-filter mutation refused. `cargo test -p data-plane-pool` 43/43,
> `make verify-m18` PASS.
>
> **🐞 Found, fold into upcoming slices (not regressions of A1):**
> 1. `json_param` maps JSON integers to `i64` → **fails to bind to `int4`
>    columns** ("error serializing parameter 0"). Pre-existing (affects insert
>    too). This is the **type-handling** work — make binding column-type-aware
>    (or send numbers via a coercible representation). Do it as part of the
>    operation-contract value handling ([02](02-operation-contract.md)).
> 2. Validation errors (empty filter, no updatable columns) return
>    `DataPlaneError::Backend` → **HTTP 502** where they should be **400/422**.
>    Add an `InvalidRequest` error variant + map it; route all request-shape
>    failures through it.
> 3. Tables in the realtime publication need a PK / `REPLICA IDENTITY` for
>    UPDATE/DELETE (a Postgres logical-replication requirement — real tenant
>    tables have PKs; document it).

> **✅ Delivered (2026-06) — A1.1: type-aware binding + honest 4xx, 5-agent hardened.**
> Closes findings #1 and #2 above.
> - **#1 — type-aware binding.** New `JsonParam(Value): ToSql` in `postgres.rs`
>   chooses the binary encoding from the **target column type** (Postgres infers
>   each `$n` at PREPARE): JSON number → `int2/4/8`, `float4/8`; JSON string →
>   `uuid`, `timestamp(tz)`, `date`, text; objects/arrays → `jsonb`. **Live-
>   verified**: insert/update/upsert/delete on an `int4`+`uuid`+`timestamptz`
>   table (the exact shape that used to fail) all succeed.
> - **#2 — honest status codes.** New `DataPlaneError::InvalidRequest` → **HTTP
>   400 `invalid_request`**. All request-shape validations across **every**
>   adapter (postgres/mysql/mongo/redis/http — 17 sites) now return 400, not
>   502. Live: empty-filter mutation → **400**.
> - **🔒 Security (5-agent convergent, CRITICAL).** The first cut used
>   `accepts() == true` + a raw inner `to_sql`, which bypassed postgres-types'
>   `WrongType` guard — a JSON string into a `bytea` column (which accepts any
>   bytes) would be **silently corrupted**. Fixed by delegating through
>   `to_sql_checked`; a true mismatch is now rejected. **Live-verified**:
>   `string→int4` → error **and 0 rows stored** (no corruption).
> - Tests: 11 new (`JsonParam` widths/overflow/uuid/timestamp/date/jsonb +
>   `type_mismatch_is_rejected_not_corrupted`) + a `map_data_plane_error`
>   status-mapping test. `cargo test` 54 (pool) / 10 (server) / 11 (core),
>   `make verify-m18` PASS.
>
> **🐞 Still deferred (recorded in [02](02-operation-contract.md)):** `numeric`/
> `decimal`, array, `time`/`interval`/`inet`/`bytea` columns are **honestly
> rejected** (no corruption) but not yet bindable — needs the shared value-
> coercion layer. A `string→int4`-style **value** mismatch is still a 502
> (serialization error) rather than 400 — reclassify when coercion is centralised.

### A2 — `batch` on all engines

Add `run_batch` (array of homogeneous ops) — multi-row `INSERT … VALUES (...),(...)`, Mongo `bulkWrite`, MySQL multi-row, a Redis pipeline. Honour the planner's `max_batch_size` ceiling (already enforced upstream). Transactional where the engine supports it.

### A3 — Parity sweep

Mongo/MySQL/Redis/HTTP already have U/D/upsert; audit them against the **02** contract (do they honour structured `Filter`, or only equality?) and bring them up to the Postgres reference.

## Phase B — rich reads (the "beyond CRUD")

> **✅ Delivered (2026-06) — B1: Postgres filter operators + sort, 5-agent hardened, live-verified.**
> `postgres.rs` `build_where` is now a recursive, injection-safe compiler
> (`compile_filter`/`compile_junction`/`compile_column`/`compile_operator`),
> backward-compatible with the legacy equality map, shared by list/update/delete:
> - **Operators:** `$eq $ne $lt $lte $gt $gte $like $ilike $in $between $null`
>   plus `$and`/`$or`/`$not` boolean composition. Identifiers via `quote_ident`,
>   operators → fixed SQL, values **always bound** (no interpolation), keys sorted
>   for cache-stable statements. `$in` capped at 1000 elements.
> - **Sort:** `build_order_by` wired into `run_list` (`{col:"asc"|"desc"}`,
>   allowlisted direction, quoted columns).
> - **🔒 Data-loss fix (5-agent CRITICAL):** the first cut let a *tautology*
>   (`{"$not":{"$or":[]}}` → `NOT (FALSE)` = `WHERE TRUE`) slip past the empty-
>   filter mutation guard → a full-owner-table UPDATE/DELETE. Fixed with a
>   constant-folding `Pred` (Unconstrained/AlwaysFalse/Sql) + param rollback, so a
>   tautology folds to `Unconstrained` → empty `WHERE` → the guard refuses it.
>   **Live-verified:** `delete {$not:{$or:[]}}` → 400, 0 rows deleted.
> - Live: `$gte`/`$in`/`$or`+`$like`/`$between`/`$not` all filter correctly; sort
>   asc/desc correct; bad operator → 400. 17 filter/sort tests; `cargo test` 68 (pool).
>
> **🐞 Deferred (recorded below + in [02](02-operation-contract.md)):**
> 1. **Architect's #1 — hoist the filter to a typed `Filter` AST in
>    `data-plane-core`** (doc 02 S1 "one tree, many backends"), so all adapters
>    *lower* one validated tree instead of each re-parsing raw `Value`. Today the
>    compiler is Postgres-only and the engines **diverge**: MySQL `build_owner_filter`
>    is equality-only (silently binds `{$gte:18}` as a value → wrong rows), Mongo
>    `json_to_doc` passes the filter raw to BSON.
> 2. **🔒 ✅ FIXED (2026-06): Mongo NoSQL-injection.** Added a recursive
>    **default-deny operator allowlist** (`reject_unsafe_operators` +
>    `SAFE_MONGO_OPERATORS`) on the filter path, so `$where`/`$expr`/`$function`/
>    `$accumulator`/`$jsonSchema` are rejected at any nesting depth with a 400.
>    A 3-agent review found a HIGH bypass — `run_upsert` built its `_id` filter
>    from the client `id` via `value_to_bson` *without* the allowlist — fixed by
>    requiring a scalar `id`. Added a symmetric write-data guard (top-level
>    `$`-keys → 400). **Live-verified:** `$where`/`$expr`/nested `$function`/
>    upsert-object-id/write-`$rename` all → 400. (Deferred: `$regex` ReDoS bound;
>    geospatial/text operators currently rejected; the real dedup is the typed
>    `Filter` AST in #1 — until then postgres and mongo carry parallel grammars.)
> 3. **Perf:** `$in` emits N placeholders (one prepared statement per arity);
>    switch to `= ANY($1)` when the array-typed param lands with value-coercion.
> 4. **Fan-out parity:** MySQL/Mongo need the operator compiler; Redis/HTTP get
>    honest rejection. (MySQL/Mongo already do sort; Redis ignores it.)

Implement the 02 read features, Postgres as reference, then fan out:

| Feature | Postgres / MySQL | Mongo | Redis / HTTP |
|---|---|---|---|
| Filter operators (eq/ne/lt/in/like/between/null, AND/OR/NOT) | recursive `compile_filter` → `WHERE` | filter doc (`$gt`,`$in`,`$regex`,`$or`) | limited: key-pattern + post-filter, or **reject** |
| Projection / `select` | column list / `to_jsonb` subset | `$project` | n/a → reject |
| Aggregation + `group_by`/`having` | `GROUP BY` + agg funcs | aggregation pipeline | reject |
| Sort (multi-key, dir, nulls) | `ORDER BY` | `$sort` | reject (or in-memory) |
| Cursor pagination (keyset) | `WHERE (sort_tuple) > (cursor)` | range on sort key | n/a |
| Search (pattern/full-text) | `ILIKE` / `tsvector @@` | `$regex` / text index | reject |
| Joins (in-engine) | `JOIN` | `$lookup` (limited) | reject → **Trino** (05) |

Redis/HTTP get **honest rejections** (clean 422 `unsupported_capability`) for what they can't do — which is correct, and only possible once capabilities are honest (04).

## Cross-cutting implementation rules

- **One compiler, reused everywhere.** `compile_filter(&Filter, &mut params) -> String` for SQL; a `to_mongo(&Filter) -> Document`; a `to_trino(&Filter)`. Write once, test exhaustively, reuse in update/delete/list/aggregate.
- **Safety is non-negotiable.** Identifiers via `quote_ident`; values via `json_param` as bound params; the compiler has **no** path that interpolates a value. Carry over the fuzz gate from 02.
- **Tenant scope unchanged.** Every read/write still runs under the RLS GUC (Postgres), `search_path` (schema-per-tenant), or owner filter (Mongo) — new ops must thread identity exactly like the existing ones.
- **Transactions.** Mutations use the per-op tx already in `execute`; the multi-statement tx path (`/v1/transactions`) gets a **reaper** (the `expires_at` field already exists, marked dead-code) so abandoned txns release pooled connections.

## Slices

1. **PG update/delete/upsert** (A1) — the flagship fix.
2. **PG rich reads** (B: filter tree, projection, sort, cursor) — reference impl.
3. **PG aggregation/group_by/having**.
4. **Fan-out** to MySQL → Mongo → (reject-map) Redis/HTTP, one engine per slice, each behind its own tests.
5. **Batch** across engines + tx reaper.

## Verification

- Per-engine unit tests for each compiled statement.
- **The e2e matrix (08):** `engine × operation` through the gateway, asserting both success cases and honest 422s. This matrix becomes a CI gate — it's what would have caught "Postgres can't delete."
- `make verify-m18` extended to assert each adapter dispatches the ops its descriptor advertises (a static "no lying" check).

## Risks

- **Mutation safety** — an unguarded update/delete with no filter is a data-loss footgun. The empty-filter guard + tests are mandatory.
- **Engine semantic drift** — "upsert" means different things per engine; document the contract's exact semantics and make each adapter conform or honestly reject.
- **Scope creep on Redis/HTTP** — resist forcing relational semantics onto them; reject cleanly and let the planner (04) route relational workloads elsewhere.
