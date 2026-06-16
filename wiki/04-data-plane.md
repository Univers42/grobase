# 04 — Data plane plan (Rust): capability-aware, isolation-pluggable execution

> [00 Overview](00-overview.md) · [01 Gap analysis](01-gap-analysis.md) · [02 Layer & edition model](02-layer-edition-model.md) · [03 Control plane](03-control-plane.md) · **04 Data plane** · [05 Orchestration & roadmap](05-orchestration-observability-roadmap.md)

The data plane is the **hot path**. It is Rust because it owns long-lived per-mount connection pools and must deliver predictable latency under load — something the previous per-call TypeScript adapters structurally could not. Resolves **G5, G6, G8** (data-plane half).

---

## 1. What exists today (and it's good)

`docker/services/data-plane-router/` is a clean 3-crate workspace:

```
data-plane-core   contracts: EngineAdapter, EnginePool, PoolRegistry, TxHandle,
                  DataOperation, DataResult, EngineCapabilities, DatabaseMount, RequestIdentity
data-plane-pool   adapters: postgres, mongo, mysql, redis, http + resolver + registry (per-pool-key cache)
data-plane-server axum HTTP: /v1/query, /v1/transactions*, /v1/admin/raw, /v1/admin/migrate,
                  /v1/permissions/decide (in-Rust ABAC), /v1/capabilities, /v1/health
```

Already true and worth protecting:

- **Strategy pattern done right** — `AppState::new` registers one `Arc<dyn EngineAdapter>` per engine into `DefaultPoolRegistry`; adding an engine touches one line (`routes.rs`).
- **Pools are keyed by `DatabaseMount::pool_key()`** = `tenant/project/id/engine/credential_version` — so credential rotation naturally forks a new pool and old ones drain.
- **Cross-tenant guards** — `validate_identity_mount` rejects when `identity.tenant_id != mount.tenant_id`; transactions check the opener's tenant before resuming a `tx_id`.
- **Admin surface exists** — `/v1/admin/raw` (DDL/aggregations, `service_role`/`admin`-gated) and `/v1/admin/migrate` (atomic per-tenant migration with a `_baas_migrations` marker) close the "full DB control" gap the audit flagged.
- **Optional in-Rust PDP** — `/v1/permissions/decide` runs a local ABAC evaluator when `DATA_PLANE_PERMISSION_BUNDLE` is set, else 503 → caller falls back to permission-engine HTTP.

---

## 2. Gap: capabilities are advertised but not enforced (G6)

**Problem.** `execute_query` checks only a **static allow-list** (`["postgresql","mongodb","mysql","redis","http"]`) and that `identity.tenant_id == mount.tenant_id`. It does **not** validate the *operation* against the engine's `EngineCapabilities`. The rich `cost { latency_class, pattern_search, joins }` model is defined and unused. A `stream` op against Redis, or a join-shaped query against a KV store, isn't rejected with a clear contract error — it just fails deep in an adapter.

**Plan — a planner stage before dispatch.** Insert a pure function between validation and `registry.get_or_create`:

```rust
fn plan(op: &DataOperation, caps: &EngineCapabilities) -> Result<Plan, DataPlaneError> {
    match op.kind {
        Stream      if !caps.stream       => Err(UnsupportedCapability{capability:"stream"}),
        Upsert      if !caps.upsert       => Err(UnsupportedCapability{capability:"upsert"}),
        Transaction if !caps.transactions => Err(UnsupportedCapability{capability:"transactions"}),
        _ => Ok(route_by_cost(op, &caps.cost)),   // native | fdw | federation(Trino) | reject
    }
}
```

- Returns a typed 422 `unsupported_capability` (the error variant already exists) instead of a deep backend failure.
- `route_by_cost` uses `joins`/`pattern_search`/`latency_class` to decide native vs federation (hand a join over heterogeneous engines to Trino, which the `analytics` plane already provides) vs honest rejection.
- The SDK already encodes these caps at compile time; the planner makes the **runtime** agree. The two stay in sync via `/v1/capabilities` + the SDK's `introspectEngines()` drift check.

---

## 3. Gap: isolation model isn't selectable (G5)

**Problem.** Scoping is hard-coded to shared-schema RLS + owner_id. The `DatabaseMount` carries `tenant_id`/`project_id` and `/v1/admin/migrate` can build per-tenant schema, but nothing *chooses* a layout.

**Plan — an `IsolationStrategy` the pool consults per request.** Add to `data-plane-core` and thread it through `EnginePool::execute`:

```rust
enum Isolation { SharedRls, SchemaPerTenant, DbPerTenant }

trait IsolationStrategy {
    // what the adapter must do before running the op
    fn prepare(&self, mount: &DatabaseMount, id: &RequestIdentity) -> ScopeDirective;
}
// ScopeDirective ∈ { SetGuc("app.current_tenant", id), SetSearchPath("tenant_<id>"), None }
```

| Strategy | Postgres adapter does | Mongo adapter does |
|---|---|---|
| `shared_rls` (today) | `SET app.current_tenant = $tenant` + rely on RLS | inject `owner_id` filter |
| `schema_per_tenant` | `SET search_path = tenant_<id>` | per-tenant **database** name |
| `db_per_tenant` | distinct mount/DSN (resolver returns tenant DSN) | distinct mount/DSN |

The strategy is selected from the mount (a `capability_overrides`/metadata field already exists on `DatabaseMount`) and provisioned by the control-plane orchestrator ([03 §2.2](03-control-plane.md)). `db_per_tenant` needs no execution change — it's just a different DSN, which `pool_key` already isolates.

> **✅ Delivered (2026-06) — `schema_per_tenant` enforcement.** `DatabaseMount`
> gained an `isolation` field (`shared_rls` default | `schema_per_tenant` |
> `db_per_tenant`) + a `tenant_schema()` helper that derives a **sanitized**
> `tenant_<id>` name (only `[a-z0-9_]`, safe to interpolate into `SET search_path`,
> which can't bind params). The Postgres adapter applies
> `SET LOCAL search_path TO <schema>, public` right after the RLS context, inside
> the same per-op transaction — a **no-op** for shared/db-per-tenant mounts, so
> existing traffic is unchanged (parity-safe). **Verified live**: same table name,
> tenant and DSN, a `schema_per_tenant` mount reads `tenant_acme.widgets` while a
> shared mount reads `public.widgets`. Unit tests cover derivation, injection-char
> sanitization, truncation and the empty case; `cargo test -p data-plane-core`
> (10/10) + `make verify-m18` **PASS**.
>
> **✅ Persisted + forwarded (2026-06), every link verified.** Isolation now
> flows through the whole stack:
> - adapter-registry stores an `isolation` column on `tenant_databases` (added
>   idempotently by `EnsureSchema`); `POST /v1/provision` sends it;
>   `/databases/:id/connect` returns it. **Verified live**: a `schema_per_tenant`
>   mount stores + returns `schema_per_tenant`; a no-isolation mount defaults to
>   `shared_rls`.
> - the query-router carries it from `fetchConnection` into the Rust mount
>   envelope (`AdapterResponse.isolation` → `RustProxyContext.isolation` →
>   `mount.isolation`) — implemented, **type-checked, and deployed** (image
>   rebuilt).
> - the Rust pool pins `search_path` for `schema_per_tenant` — **verified live**
>   (the isolation slice above).
>
> **🐞 Pre-existing gateway bug blocks the live api-key round-trip (not isolation).**
> Kong's `query-router` route is `paths: [/query/v1]` + `strip_path: true`, which
> forwards `/<dbId>/tables/<table>`, but the NestJS controller is
> `@Controller('query')` → it needs `/query/<dbId>/...`. A query through Kong
> returns **404** before any data logic runs. The fix is a gateway/controller
> path alignment (drop the controller's `query` prefix, or stop over-stripping)
> — the same path-rewrite class of work as [03 §2.3](03-control-plane.md). Until
> then the round-trip is verified link-by-link, not in one HTTP call.

---

## 4. Gap: credential provider isn't pluggable (G8, data-plane half)

**Problem.** `resolver.rs` resolves DSNs from inline (`mount.inline_dsn`) or an env-backed `EnvMountResolver`. `credential_ref.provider` is carried but unused; Vault is not a source.

**Plan — a `CredentialProvider` seam** chosen by `credential_ref.provider`:

```rust
#[async_trait]
trait CredentialProvider {                 // resolver.rs
    async fn resolve(&self, r: &CredentialRef) -> Result<Dsn>;
}
// "inline"           -> mount.inline_dsn (today's fast path, kept)
// "adapter-registry" -> GET adapter-registry /databases/:ref/connect (service token)
// "vault"            -> Vault KV v2 read at r.reference, version r.version
```

Rotation story: control-plane bumps `credential_ref.version` → next request computes a new `pool_key` → new pool opens, old one ages out by `PoolPolicy.max_lifetime_ms`. No request ever sees a torn credential. This composes with `make secrets-rotate GROUP=tenant-dsn` from [03 §2.4](03-control-plane.md).

---

## 5. Transactions, raw, migrate — finish wiring to the edge

These Rust endpoints exist but aren't all exposed through the product:

- `/v1/transactions` + `/{id}/execute|commit|rollback` — a 30s-TTL registry with a per-tenant guard. **Plan:** add the planned **reaper task** (the `expires_at` field is already stored, marked `#[allow(dead_code)]`) so abandoned tx connections are reclaimed, and surface `.transaction()` in the SDK (G9, [05](05-orchestration-observability-roadmap.md)).
- `/v1/admin/raw` + `/v1/admin/migrate` — route via Kong `/admin/v1/migrate` ([03 §2.3](03-control-plane.md)) so per-tenant DDL is a product capability, not an internal-only call.

---

## 6. Observability of the data plane (G7, data-plane half)

**✅ Delivered (2026-06) — `/metrics` on the Rust router.** A dependency-free
Prometheus exposition (`crates/data-plane-server/src/metrics.rs` + an axum
`from_fn_with_state` counting middleware) serves, in the same `baas_*` shape as
the Go control plane: `baas_service_up`, `baas_uptime_seconds`,
`baas_http_requests_total{status}`, and **`baas_data_plane_pool_connections{mount,engine,state}`**
sourced live from `PoolRegistry::stats()` (the `PoolStats{active,idle,waiting}`
gauges). Prometheus scrapes it via the `rust-data-plane` job. With the Go half
shipped earlier, **all three planes are now scrapeable** (G7 metrics done).

**Still pending:** W3C `traceparent` propagation so a query-router span
continues into Rust (needs the TS proxy to send `traceparent` *and* the Rust
router to parse/continue it) — tracked in [05](05-orchestration-observability-roadmap.md).

---

## 7. Guardrails — what must NOT regress

This plane is under the strict deletion-gate doctrine (`.claude/instructions.md`). Any change here:

1. keeps `validate_identity_mount`'s cross-tenant rejection,
2. keeps every user value **parameter-bound** (never string-interpolated) and identifiers validated against `^[a-zA-Z_]\w{0,63}$`,
3. is proven at parity before any product-mode flip,
4. adds engines/strategies **additively** — one registration line, no call-site churn.

---

## 8. How I (Claude) help here

- Implement `plan()` as a pure, unit-tested function over `EngineCapabilities` (table-driven: every op × every engine → expected verdict) before touching dispatch — pure functions are the cheapest place to be correct.
- Add `IsolationStrategy` to `data-plane-core` and implement `SchemaPerTenant` in the Postgres adapter behind a mount flag, with an integration test that two tenants on the same DB cannot read each other's schema.
- Add the `CredentialProvider` trait + the `vault` impl, and the tx **reaper** task, each as its own small PR with `make rust-data-plane-check` + `make verify-m18` green.
- Never enable a new code path in production mode until `make parity` ([05](05-orchestration-observability-roadmap.md)) returns a recorded green verdict for the affected routes.
