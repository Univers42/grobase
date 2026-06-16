# 02 — Layer & edition model: changing layers according to need

> [00 Overview](00-overview.md) · [01 Gap analysis](01-gap-analysis.md) · **02 Layer & edition model** · [03 Control plane](03-control-plane.md) · [04 Data plane](04-data-plane.md) · [05 Orchestration & roadmap](05-orchestration-observability-roadmap.md)

This is the conceptual core of the product. It defines the vocabulary and the manifest that turn "a pile of compose profiles" into **a backend whose shape you choose**.

---

## 1. Three axes of "change layers according to need"

A consumer never says "give me these containers." They say one of three things, at three different altitudes:

| Axis | Question answered | Unit | Who chooses | Bound at |
|---|---|---|---|---|
| **Edition** | *Which planes run at all?* | a named set of planes | operator | deploy time (compose / Helm) |
| **Engine** | *Which database backs this resource?* | an `EngineAdapter` | tenant/app | mount-creation time |
| **Isolation** | *How are tenants kept apart?* | an `IsolationStrategy` | product/tenant | provisioning time |

Plus two runtime dials that swap an implementation **without** changing the shape:

- **Product mode** — `shadow | enabled` per plane (which implementation serves traffic).
- **Permission mode** — `abac | rbac` (how decisions are computed).

Get these four concepts first-class and "change layers" stops being a migration project and becomes configuration.

---

## 2. Planes → profiles (the lower half of the manifest)

A **plane** is a coherent capability slice. It maps to one or more compose profiles. This table is the single source of truth that the Makefile and (later) Helm consume.

```
PLANE            COMPOSE PROFILE(S)        ROLE
core   (always)  (none)                    waf, kong, postgres, gotrue, postgrest, redis, db-bootstrap
data             data-plane                mongo, mongo-api, realtime, ai, analytics, debezium
control          control-plane             vault, pg-meta, permission-engine, schema-service, gdpr, supavisor, studio
go               go-control-plane          adapter-registry, tenant-control, webhook-dispatcher
rust             rust-data-plane           data-plane-router (engine pools)
adapter          adapter-plane             query-router, outbox-relay, permission-engine, data-plane-router
background       background                email, newsletter, session, analytics, ai, gdpr, log, webhook-dispatcher
analytics        analytics                 trino, mysql, iceberg-rest, analytics-service
storage          storage                   minio, storage-router
realtime         realtime                  realtime
functions        functions                 functions-runtime (Deno edge)
observability    observability             prometheus, grafana, loki, promtail, log-service
ops              ops, backups              pg-backup
studio           studio                    studio admin UI
```

> **Cleanup owed (G1).** Some services carry redundant profile memberships (`extras` mixed with `analytics`/`storage`/`data-plane`). The manifest above is the intended canonical mapping; the compose `profiles:` lists should be reconciled to it so a plane means exactly one thing.

---

## 3. Editions → planes (the upper half of the manifest)

An **edition** is a named, validated set of planes — a "known-good shape."

| Edition | Planes | Intended use |
|---|---|---|
| `lean` | core | Auth + relational REST only. The smallest useful BaaS. |
| `query` | core + data + go + rust + adapter + background | The multi-tenant universal query product (the flagship path). |
| `realtime` | `query` + realtime + storage | Adds WS fan-out and object storage. |
| `analytics` | core + data + storage + analytics | Federation/lakehouse reads (Trino + Iceberg). |
| `full` | every plane | Everything, for demos and CI. |
| `prod` | `query` + storage + realtime + observability + ops | Production default: flagship + durability + telemetry. |

Operator experience (delivered by the Makefile in [05](05-orchestration-observability-roadmap.md)):

```bash
make up                 # default edition (query)
make up EDITION=lean    # smallest
make up EDITION=full    # everything
make up-analytics       # add just the analytics plane to a running stack
make down-analytics     # drop it again — "change layers" live
make planes             # list planes & their profiles
make editions           # list editions & their planes
```

---

## 4. Engine layer — swap the database, keep the API

Engines plug into the data plane through one trait (`crates/data-plane-core/src/ports.rs`):

```rust
trait EngineAdapter {
    fn engine(&self) -> &str;
    fn capabilities(&self) -> EngineCapabilities;
    async fn open_pool(&self, mount: DatabaseMount) -> Result<Box<dyn EnginePool>>;
    async fn health_check(&self, pool: &dyn EnginePool) -> Result<EngineHealth>;
}
```

Live today: `postgresql`, `mongodb`, `mysql`, `redis`, `http`. Adding one is a single registration line in `AppState::new` plus a pool impl in `data-plane-pool`. The capability descriptor it returns is what the SDK and the planner consume.

**Negotiation contract (target — closes G6):** for every operation the planner asks the mount's capabilities:

```
op.requires(stream)      → engine.stream      must be true, else 422 unsupported_capability
op.requires(transaction) → engine.transactions must be true, else open a compensating saga
op.shape == join         → cost.joins != none, else route to Trino federation or reject
```

The SDK already encodes this at compile time; the planner makes it true at runtime.

---

## 5. Isolation layer — choose how tenants are separated (closes G5)

Define an `IsolationStrategy` consumed by both provisioning (how a tenant's storage is laid out) and the data plane (how each request is scoped):

| Strategy | Storage layout | Per-request scoping | Cost | When |
|---|---|---|---|---|
| `shared_rls` (today) | one schema, `tenant_id`/`owner_id` columns | `SET app.current_tenant` + RLS / `owner_id` filter | cheapest, densest | many small tenants |
| `schema_per_tenant` | one DB, schema per tenant | `search_path = tenant_<id>` | medium | noisy-neighbour isolation, per-tenant DDL |
| `db_per_tenant` | one database (or cluster) per tenant | distinct `DatabaseMount` / DSN | priciest, hardest isolation | regulated / large tenants |

The primitives already exist — `DatabaseMount{tenant_id, project_id}`, RLS, and Rust `/v1/admin/migrate` for per-tenant schema. What's missing is the **strategy object** that decides search_path/connection and the provisioning step that lays storage out accordingly. Detailed in [04](04-data-plane.md).

---

## 6. The manifest, concretely

Phase 1 (now): the manifest lives as Make variables — `PLANE_<name>` and `EDITION_<name>` (see [05](05-orchestration-observability-roadmap.md)). That is enough to drive Compose and is the single source of truth.

Phase 2 (later): promote it to a small YAML the Makefile and a Helm-values generator both read, so Compose and K8s stay in lockstep (G11):

```yaml
planes:
  rust:    { profiles: [rust-data-plane] }
  go:      { profiles: [go-control-plane] }
  # …
editions:
  query:   [core, data, go, rust, adapter, background]
  prod:    [core, data, go, rust, adapter, background, storage, realtime, observability, ops]
```

Keep Phase 1 until a second runtime (Helm) actually needs Phase 2 — don't build the YAML compiler before there's a consumer.

---

## 7. Invariants the model must hold

1. **A plane is independently startable/stoppable** against a running core. `make up-analytics` / `make down-analytics` must not disturb the data path.
2. **Editions are validated shapes.** CI boots each edition and runs its smoke subset (G10).
3. **Swapping an implementation (product mode) never changes the public contract.** That is what the parity gate guarantees ([05](05-orchestration-observability-roadmap.md)).
4. **The manifest is the only place planes/editions are defined.** No target hand-writes `--profile` lists.

These four invariants are what let a user "change layers according to need" safely instead of bravely.
