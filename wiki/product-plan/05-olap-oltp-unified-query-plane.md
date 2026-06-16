# 05 — OLAP/OLTP unification: one query plane, two worlds

> The heart of the vision: *the BaaS can connect/disconnect layers to run as an OLAP or an OLTP model, with different resource footprints* — and a client issues a query **without knowing or caring** which world serves it. The platform routes by cost; the tenant flips the context.

## Where we are (~30% there)

- **Deploy-shape switching: done.** The plane/edition orchestration (Makefile manifest + compose profiles) already stands up an **OLTP-leaning** stack (`query`/`prod`: Rust engine pools + realtime + outbox, light) or an **OLAP-leaning** stack (`analytics`: **Trino + Iceberg + MySQL**, heavy). Resource footprint genuinely differs; planes attach/detach live.
- **Runtime intelligence: missing.** Trino is reachable only via a **separate** Kong `/sql` route — *not* in `/query/v1` or the SDK. The cost model (04) is unused for routing. OLAP/OLTP is a deploy choice, not a per-tenant/per-query **context**. There's no OLTP→lakehouse tiering.

## Target

1. **One query plane.** `/query/v1` (and the SDK) is the only surface. The [planner](04-honest-capabilities-and-planner.md) decides per operation: serve from the **OLTP engine pool** (Rust) or the **OLAP federation** (Trino) — same [operation contract](02-operation-contract.md), same response shape.
2. **OLAP/OLTP as a switchable context.** A first-class `workload_mode` ∈ `oltp | olap | auto`, set per **tenant / project / request**, that biases routing and (optionally) activates/deactivates the analytics plane for that tenant — changing the resource footprint deliberately.
3. **Cost-driven routing.** Point reads / writes / small filtered lists → engine pool. Aggregations, heterogeneous joins, large scans, federated multi-source queries → Trino. Driven by `cost {latency_class, joins, pattern_search}` + the workload context.
4. **Lakehouse tiering (optional, later).** OLTP tables projected into Iceberg for cheap analytical scans, so OLAP queries don't hammer the transactional store.

## Design

### 1. A Trino engine adapter (fold federation into the plane)

Add a `TrinoEngineAdapter` implementing the **same `EngineAdapter` trait** as the others. It:
- compiles the [02 operation](02-operation-contract.md) (filter tree, projection, aggregation, joins) to **Trino SQL**,
- runs it over the Trino REST API against the right **catalog** (`postgresql`/`mongodb`/`mysql`/`iceberg`), and
- returns the normalised `DataResult`.

Now Trino is *not* a separate endpoint — it's a routing target inside the unified plane. `cost.latency_class = Fdw`, `joins = Native` (Trino joins across catalogs).

### 2. WorkloadContext + routing

```rust
pub struct WorkloadContext {
  pub mode: WorkloadMode,        // oltp | olap | auto (from tenant/project/request)
  pub freshness: Freshness,      // realtime | bounded-staleness (OLAP can read the lakehouse)
}
```

The planner's `Plan::Federate` branch (stubbed in 04) becomes real:

```
plan(op, caps, ctx):
  mode == oltp                      → Native (reject if engine can't)
  mode == olap                      → Federate(trino)
  mode == auto:
     op.is_point_or_small_write     → Native
     op.has_aggregation|group_by    → Federate(trino)
     op.is_heterogeneous_join       → Federate(trino)
     op.scans_large_range           → Federate(trino) if analytics plane up, else Native
     else                           → Native
```

Routing is **logged with its reason** (debuggability) and **flag-gated** (`QUERY_ROUTER_OLAP_ROUTING`) until parity-proven.

### 3. Where the context comes from

- **Tenant/project default**: stored alongside the tenant (or the mount) — `workload_mode` column; set at provision time (extend `/v1/provision`).
- **Per-request override**: an operation field / SDK `.context('olap')` for ad-hoc analytics.
- **Resource coupling**: when a tenant is `olap`, the orchestrator (control plane) ensures the analytics plane is up for them; when no tenant needs OLAP, it can be torn down — *this is the "different place taken in resources" the vision asks for*, made automatic.

### 4. The two footprints, made explicit

| Context | Active layers | Footprint | Latency profile |
|---|---|---|---|
| **OLTP** | Rust engine pools, realtime, outbox, Redis | light (≈ today's `query` edition) | ms point ops, transactional |
| **OLAP** | + Trino, Iceberg/MinIO lakehouse, MySQL analytical | heavy (Trino is GB-RAM) | seconds, scans/joins/aggregations |
| **auto** | both available; per-query routing | medium, elastic | best per op |

The orchestrator (control plane) ties `workload_mode` ⇄ active planes, so choosing OLAP literally provisions the OLAP layer and vice-versa.

## Slices

1. **S1 — TrinoEngineAdapter (read-only).** Compile filter/projection/aggregation/join → Trino SQL over one catalog; return `DataResult`. Unit-test the SQL compiler; live-test an aggregation via Trino through `/query/v1`.
2. **S2 — Planner `Federate(trino)` real.** Route `olap`-mode + aggregation/join ops to the Trino adapter; flag-gated; `make parity` OLTP-path unchanged.
3. **S3 — WorkloadContext plumbing.** Add `workload_mode` to tenant/mount + provision + the request; thread to the planner.
4. **S4 — Resource coupling.** Orchestrator activates/deactivates the analytics plane per tenant demand (`make up-analytics` equivalent via the control plane).
5. **S5 — Lakehouse tiering (optional).** A job projects selected OLTP tables → Iceberg; OLAP reads prefer the lakehouse for bounded-staleness queries.

## Verification

- Live: the **same** SDK query (an aggregation/join) returns correct results whether routed Native or to Trino — proving one plane, two worlds.
- A tenant flipped `oltp → olap` shows the analytics plane coming up and the query routing changing (logs + footprint).
- `make parity OLD=oltp NEW=auto` proves auto-routing doesn't change results for OLTP-shaped queries.

## Risks

- **Result-shape parity** between in-engine and Trino must be exact (types, nulls, ordering). The parity gate is mandatory before `auto` becomes default.
- **Trino cold-start / resource cost** — activating OLAP per tenant must be deliberate and rate-limited (ties to [06 quotas](06-saas-multitenancy-quotas-billing.md)); never auto-spin Trino on a stray query.
- **Security** — Trino runs cross-catalog; the adapter must apply the **same tenant scoping** (predicate injection / catalog restriction) as the native path. No federation bypass of isolation.
