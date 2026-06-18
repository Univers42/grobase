# engine-conformance

A reusable, test-only battery that drives any `EngineAdapter` through its public `EnginePool` surface against a **real** engine (no HTTP) and asserts the adapter serves *exactly* what its `EngineCapabilities` descriptor advertises.

## Why this exists

In this data plane every engine adapter ships an `EngineCapabilities` descriptor — a self-declared profile of what it can do (`upsert`, `batch`, `aggregate`, `transactions`, `introspect`, `ddl`, …). The danger is an adapter that *lies*: claiming a capability it doesn't really serve, or quietly serving an operation it claims to reject. This crate makes that impossible to ship. **The descriptor IS the conformance contract.**

`run_suite` reads the descriptor and tests both halves of it. For every capability the descriptor advertises, the suite proves the capability actually works through the real engine. For every operation the descriptor marks *unsupported*, the suite proves the pool errors out (`check_honesty`) — it guards the *negative space* so an adapter cannot silently succeed at an op it disavows. An engine therefore cannot pass while misrepresenting itself: every advertised capability must function, and every disavowed op must fail. New engines only merge once green here.

## How it works

`run_suite(adapter: Arc<dyn EngineAdapter>, mount: DatabaseMount) -> SuiteReport` is the entry point. The flow:

1. **Setup.** It reads `adapter.engine()` and `adapter.capabilities()`, then opens a real pool via `adapter.open_pool(mount).await`. The `mount` is built by the helper `mount_for(engine, tenant, dsn)`, which puts the DSN in `inline_dsn` (inline wins in the resolver, so no env map is needed) with a `CredentialRef { provider: "inline", … }`. A `RequestIdentity` is derived from the tenant via `identity()` (a `ServiceToken` source with `read`/`write` scopes).
2. **Bootstrap.** For relational engines (`scratch_create_sql` returns SQL for `postgresql`/`cockroachdb`, `mysql`/`mariadb`, `sqlite`, `mssql`) it creates the scratch table `conf_probe` — including the composite `UNIQUE(owner_id, id)` that owner-scoped upsert arbitrates on — via `execute_raw`. Postgres also pre-drops any unqualified shadow table (`scratch_predrop_sql`) so a `$user`-schema leftover doesn't hide the `public` one. Document/KV engines (mongo, redis) return `None` and create their resource implicitly on first write. A best-effort `Delete` clears stale rows for a clean slate.
3. **Probe.** It runs each per-capability check and records the outcome into a `SuiteReport`.
4. **Teardown.** Best-effort drop (`scratch_drop_sql`) or `Delete`, then `pool.close()`.

`SuiteReport` accumulates three buckets: `passed: Vec<String>`, `failed: Vec<(String, String)>` (name + error), and `skipped: Vec<String>`. `record(name, Result)` routes a check to passed/failed; `skip(name, why)` records a capability the descriptor turned off (e.g. `"upsert (descriptor: upsert=false)"`). `is_green()` returns true iff `failed` is empty — that boolean is the gate. The `Display` impl prints a `PASS`/`SKIP`/`FAIL` block plus a `→ N passed, N skipped, N failed` summary line.

**Capability gating.** A check runs only when its capability flag is set, otherwise it is skipped:

| Check | Gated on | What it asserts |
|-------|----------|-----------------|
| `check_crud` | always | insert → get → update → get → delete → get-after-delete returns no rows |
| `check_upsert` | `caps.upsert` | upsert inserts then updates the same key (`name` goes `one`→`two`) |
| `check_batch` | `caps.batch` | a clean 2-insert batch yields a `BatchSummary` with 2 items; then a poison item (empty-filter `Delete`, refused as a mass-write everywhere) tests the declared failure mode — `atomic=true` engines must roll the whole batch back, ordered engines must persist the item before the poison and skip the one after |
| `check_aggregate` | `caps.aggregate` | `count`→3 and `sum(n)`→6 over 3 inserted rows |
| `check_filtering` | always | `limit`; and for `caps.ddl` or `mongodb` ("rich") engines: `$eq` field filter returns 1 row, plus `sort` desc + `limit` returns the highest-`n` rows; KV/passthrough engines just get a basic `List` returning ≥3 rows |
| `check_transactions` | `caps.transactions` | `begin`/`commit` makes the row visible; `begin`/`rollback` leaves it invisible |
| `check_introspect` | `caps.introspect` | `describe_schema` surfaces the `conf_probe` table |
| `check_honesty` | always | for every `DataOperationKind::ALL` the descriptor reports unsupported (`!caps.supports_op`), executing it must error — never silently succeed |

The positive checks prove the *supported* ops work; `check_honesty` guards everything else. `num()` tolerates JSON-number-vs-string (mysql `DECIMAL` comes back as a string), and `expect_field` does typed string equality.

## File-by-file

### `src/lib.rs`
The reusable battery. Public surface: `run_suite()`, `SuiteReport` (with `is_green()`), and `mount_for()`. Internals: the per-capability `check_*` functions above, plus operation builders (`op`, `insert`, `update`, `upsert`, `get_op`, `list_all`, `batch`), the `raw()` helper over `execute_raw`, the `identity()`/`id_owner()` identity helpers, and the per-dialect scratch DDL (`scratch_create_sql`, `scratch_predrop_sql`, `scratch_drop_sql`). The scratch resource name is the constant `RESOURCE = "conf_probe"`. Adding a new relational engine means adding its dialect to these `scratch_*` functions.

### `tests/conformance.rs`
The driver that wires real adapters from `data-plane-pool` to the battery. The `#[tokio::test]` `engine_conformance` reads `CONFORMANCE_ENGINE` and `CONFORMANCE_DSN` from the environment (plus optional `CONFORMANCE_TENANT`, default `conf-tenant`). With `CONFORMANCE_ENGINE` unset it **skips cleanly** (so `cargo test` stays green in CI with no database). Otherwise it constructs the matching adapter — `postgresql`, `cockroachdb` (Postgres adapter with `PgDialect::Cockroach`), `mysql`, `mariadb` (`MysqlEngineAdapter::with_engine_name`), `mongodb`, `redis`, `sqlite`, `mssql` — builds the mount with `mount_for`, runs `run_suite`, prints the report, and asserts `report.is_green()`.

## Running it

Run against a real engine by exporting the env the driver reads:

```bash
CONFORMANCE_ENGINE=postgresql \
CONFORMANCE_DSN='postgres://user:pass@host:5432/db' \
cargo test -p engine-conformance
```

With no env set, the test skips and the workspace build stays green without infra. The live runs normally go through the `conformance-runner` compose service on the mini-baas network via the `make conformance-<engine>` targets.

This crate is **excluded from default builds**: the `data-plane-router` workspace's `default-members` omits it, so `cargo build` and the production Docker image never compile it — it is a test-only battery, not part of the router binary's dependency graph. It remains a workspace member, so `cargo test -p engine-conformance` still works. Its only non-toolchain dependencies are `data-plane-core` (the traits/vocabulary it drives) and `data-plane-pool` (the concrete adapters the test wires up).
