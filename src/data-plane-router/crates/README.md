# data-plane-router — crate map

The Rust **data plane** of the mini-baas / Grobase Backend-as-a-Service. This is
the engine that takes an authenticated HTTP data request, decides whether and
where it can run, enforces multi-tenant isolation, and executes it against one of
eight database engines behind long-lived connection pools.

It is the Rust side of the project's TypeScript→Rust **shadow → parity → cutover**
migration: it replaces the legacy TS query-router's "new client per request"
behaviour with pooled, capability-checked, tenant-isolated execution.

## The four crates (layered bottom-up)

```
                 ┌─────────────────────────────────────────────┐
   HTTP request  │  data-plane-server   (the axum binary)       │
  ───────────────►  routes · auth · ABAC · ratelimit · quota ·  │
                 │  usage · graph · nano/one editions           │
                 └───────────────┬─────────────────────────────┘
                                 │ holds Box<dyn EnginePool>
                 ┌───────────────▼─────────────────────────────┐
                 │  data-plane-pool   (concrete adapters)       │
                 │  postgres · mysql · mongo · sqlite · mssql · │
                 │  redis · http · dynamodb + registry/creds    │
                 └───────────────┬─────────────────────────────┘
                                 │ implements the traits from
                 ┌───────────────▼─────────────────────────────┐
                 │  data-plane-core   (pure vocabulary, no I/O) │
                 │  capabilities · planner · filter · isolation │
                 │  mounts · operations · the `ports` traits    │
                 └─────────────────────────────────────────────┘

   engine-conformance ── test-only battery; depends on core + pool,
                         excluded from the production binary's build.
```

| Crate | What it is | Lines | I/O? | README |
|-------|-----------|------:|------|--------|
| [`data-plane-core`](./data-plane-core/README.md) | Pure domain vocabulary + the trait seam (`EngineAdapter`/`EnginePool`/`PoolRegistry`), the query planner/validator, capability descriptors, filters, isolation strategies, mounts, operations, schema/DDL contracts. | ~2.5k | **None** | [→](./data-plane-core/README.md) |
| [`data-plane-pool`](./data-plane-pool/README.md) | Concrete `EngineAdapter` implementations for 8 engines + the pool registry, mount resolver, credential providers, and TLS. Enforces per-request tenant isolation. | ~12k | DB drivers | [→](./data-plane-pool/README.md) |
| [`data-plane-server`](./data-plane-server/README.md) | The axum HTTP binary: routing, request auth, ABAC, rate-limit/quota/usage, metrics, graph, plus the **nano** and **one** single-binary product editions. | ~10k | HTTP | [→](./data-plane-server/README.md) |
| [`engine-conformance`](./engine-conformance/README.md) | Test battery that drives each adapter against a real engine and asserts it serves **exactly** what its capability descriptor advertises. | ~0.6k | tests | [→](./engine-conformance/README.md) |

Start with **`data-plane-core`** — its `ports.rs` (the traits) and `capability.rs`
(the descriptors) are the vocabulary every other crate speaks.

## The disciplines that explain the whole design

These three ideas recur in every crate; understanding them makes the code legible.

**1. Capability honesty.** Each engine advertises an `EngineCapabilities`
descriptor (defined in `core`, e.g. `EngineCapabilities::postgresql()`). The
descriptor is the single source of truth: the planner gates on it, every adapter
must implement *exactly* the op set its descriptor derives via `supports_op`, and
the `engine-conformance` battery fails the build if an adapter lies. An engine
**never silently degrades** an unsupported operation — it returns a precise
contract error (`UnsupportedCapability`), and a tier-masked one returns
`CapabilityGated` (403).

**2. Multi-tenant isolation, re-applied per request.** A `DatabaseMount` carries
an `Isolation` strategy (`SharedRls` / `SchemaPerTenant` / `DbPerTenant` /
`TenantOwned`). The default `SharedRls` re-applies tenant scoping on every pool
checkout from the verified `RequestIdentity` — Postgres via RLS GUCs
(`app.current_user_id` / `app.current_tenant_id`), the other engines via an
`owner_id`/`tenant_id` predicate plus write-decoration so a forged request body
can't leak cross-tenant rows (Redis namespaces keys; HTTP forwards `X-Owner-Id`).
Because the pool holds **no** tenant state, the **shared-pool** optimization
(`DATA_PLANE_SHARE_POOLS` + `shared_rls`) can collapse every tenant on one
physical backend to a single pool.

**3. Shadow → parity → cutover.** The whole crate exists to replace TypeScript
without behaviour drift. Wherever a new path could diverge, the parity branch is
byte-identical to the legacy one (e.g. an absent isolation string degrades to
`SharedRls`; sharing-off pool keys are identical to per-tenant keys). Deletions of
legacy code are gated on proven parity — see the repo's `CLAUDE.md` migration gates.

## How a request crosses the crates

1. **`data-plane-server`** receives the HTTP request → `auth` verifies the API
   key / JWT and builds a `RequestIdentity` → `abac` authorizes it → the mount is
   resolved into a `DatabaseMount`.
2. The server calls **`data-plane-core`**'s `plan()` / `validate_operation()`:
   Phase 1 rejects an impossible `(engine, op)` pair *before* a pool opens; Phase
   2 routes by the engine's advertised cost capabilities. `tier_gate()` then
   applies the tenant's package mask.
3. On a `Native` plan, the server asks **`data-plane-pool`**'s `DefaultPoolRegistry`
   for a `Box<dyn EnginePool>` (keyed by `effective_pool_key`), resolving
   credentials through a `CredentialProvider` and opening the pool if needed.
4. The pool checks out a connection, applies the isolation `ScopeDirective`, and
   the concrete adapter executes the `DataOperation`, returning a `DataResult`
   the server serializes to JSON.

## Product editions & feature flags

The same workspace builds several shapes via cargo features (see each crate's
`Cargo.toml` and the `Dockerfile*` at the workspace root):

- **Default / full router** — all stable engines on; the multi-engine data plane.
- **`nano`** (`Dockerfile.nano`) — PocketBase-class single binary, SQLite-only,
  built with the size-optimized `profile.nano`. Adds `data-plane-server::nano`.
- **`one`** (`Dockerfile.one`) — "our PocketBase": adds OAuth, TOTP/MFA, SMTP
  mail, file storage + thumbnails, and an admin UI at `/_/` (the
  `data-plane-server::one*` modules).
- **`dynamodb`** — OFF by default; pulling in the AWS SDK would break byte-parity,
  so it's an opt-in 8th engine.
- **`control-pg`** — server-backed automations + transactional outbox.

`engine-conformance` is a workspace member but **not** in `default-members`, so
`cargo build` and the Docker images never compile it; run it with
`cargo test -p engine-conformance` (or the `make conformance-*` targets).

## Where to read next

- New to the data plane? Read [`data-plane-core/README.md`](./data-plane-core/README.md)
  end to end — it's the smallest crate and defines everything else.
- Want to know how an engine enforces isolation? See the per-engine sections in
  [`data-plane-pool/README.md`](./data-plane-pool/README.md).
- Looking for an HTTP endpoint or an edition? See
  [`data-plane-server/README.md`](./data-plane-server/README.md).
