# 07 — Scale, HA & deployment (Helm/K8s from the manifest)

> Make it survive a node, scale a tier, and deploy as more than one developer's Compose. Sequenced after 02–06 so we scale a *finished* product, not a half-built one.

## Problem

- **Single-node Compose only.** `docker-compose.yml` + the edition manifest run on one host. No HA, no horizontal scale, no rolling deploy. A node loss = total outage.
- **The manifest stops at Compose.** The plane/edition model (Makefile `PROFILES_*`/`EDITION_*`) is the right abstraction but compiles only to `--profile` flags — not to K8s. `docs/projet-back.md §9.4` already names "Kubernetes / Helm / GitOps" as the gap.
- **No per-tenant resource ceilings.** Pools, OLAP RAM, and connections are unbounded per tenant (ties to [06](./06-saas-multitenancy-quotas-billing.md)).
- **Stateful coupling** — Postgres/Mongo/Redis/MinIO are single instances; the realtime/outbox path assumes one of each.

## Target

1. **Helm chart(s) generated from the edition manifest** — one source of truth ([02 layer model](../architecture/02-layer-edition-model.md)) compiling to *both* Compose (dev) and Helm/Kustomize (prod). `helm install baas --set edition=prod` stands up the same shape.
2. **Horizontal scale for stateless tiers** — query-router (TS), data-plane-router (Rust), the Go control daemons, mongo-api, etc. run N replicas behind the gateway; pools are per-replica with ceilings.
3. **HA for stateful tiers** — Postgres (primary+replica / Patroni or a managed PG), Redis (sentinel/cluster), Mongo (replica set — already used for change streams), MinIO (distributed). Document the "bring your own managed data store" path too.
4. **Rolling, zero-downtime deploys** + health/readiness already present (every service has `/health/live|ready`).
5. **Per-tenant ceilings** — pool max, OLAP concurrency, connection caps, enforced from the plan.

## Design

### 1. Manifest → Helm (the keystone)

Promote the Make manifest to the small YAML form already sketched in [02 §6](../architecture/02-layer-edition-model.md):

```yaml
planes:   { rust: {profiles:[rust-data-plane]}, go: {...}, analytics: {...}, … }
editions: { query: [core,data,go,rust,adapter,background], prod: [...], … }
```

A generator (a script or a tiny Go tool) emits:
- **Compose** profile selection (today's behavior), and
- **Helm values / Kustomize overlays** — one Deployment+Service per plane service, HPA for stateless tiers, StatefulSets for stores, with the *same* env contracts.

The Makefile gains `make helm EDITION=prod` next to `make up EDITION=prod`. **One manifest, two runtimes** — the invariant from [02 §7](../architecture/02-layer-edition-model.md).

### 2. Stateless tier scaling

- query-router, data-plane-router, control-plane daemons, mongo-api, background services → `replicas: N` + HPA on CPU/RPS.
- Pools are **per-replica**; the per-mount `PoolPolicy.max` × replicas must respect the tenant DB's connection ceiling → expose a global cap (use a pooler — **Supavisor** is already in the stack — in front of tenant Postgres where applicable).
- Sticky-session-free: every request carries its identity envelope; no in-memory session affinity (the transaction registry is the one exception — pin tx by routing the `tx_id`'s follow-ups to the owning replica, or move tx state to Redis).

### 3. Stateful HA

| Store | HA approach | Notes |
|---|---|---|
| Postgres (platform) | primary + sync replica (Patroni) or managed | RLS + logical replication already on |
| Mongo | replica set | already required for change streams |
| Redis | sentinel or cluster | outbox streams + cache + rate-limit buckets |
| MinIO | distributed (4+ nodes) | object storage + Iceberg warehouse |
| Trino (OLAP) | coordinator + worker pool | scale workers per OLAP load; per-tenant concurrency cap |

### 4. Deploy mechanics

- Rolling updates via Deployment strategy; readiness gates traffic (already implemented).
- Config/secrets via K8s Secrets / external secret operator → Vault (already in the control plane).
- GitOps (Argo/Flux) optional: the edition manifest is the desired state.

## Slices

1. **S1 — Manifest YAML + generator** producing Compose (parity with today) — proves the single source of truth before touching K8s.
2. **S2 — Helm chart** for one stateless service (query-router) + its Service/HPA; `make helm` renders it.
3. **S3 — Full edition chart** (all planes) for stateless tiers; stores as "bring-your-own / managed" first.
4. **S4 — Stateful HA** charts (PG replica, Redis sentinel, Mongo RS, MinIO distributed).
5. **S5 — Tx state externalization + replica-safe routing**; per-tenant ceilings from the plan.

## Verification

- `helm install` an edition in a kind/k3d cluster; the **same e2e matrix (08)** passes against it as against Compose.
- Kill a query-router replica under load → no failed requests (HPA + readiness).
- Kill the PG primary → replica promotes; writes resume within SLO.
- Edition parity: Compose and Helm render the *same* set of services for a given edition (a generator test).

## Risks

- **Stateful HA is the hard part** — prefer managed data stores in the chart's default "prod" path; self-hosted HA (Patroni etc.) is opt-in and documented as advanced.
- **Connection storms** — N replicas × per-mount pools can exhaust tenant DBs; the global cap + pooler is mandatory before scaling replicas.
- **Don't K8s-ify prematurely** — S1 (manifest+generator) delivers value (single source of truth) even before Helm; ship it first.

## Multi-instance correctness (Track-2 C — decisions, implemented 2026-06-13)

These are the ADRs that make horizontal scaling *correct*, not just possible.

### C1 — Rate limit is authoritative across replicas (DONE)
The product limiter lives in the **data plane**, not Kong. The Rust token bucket
is the single-node default (sub-µs, zero network); `ratelimit-redis` (now in the
data-plane `default` features, runtime-selected via
`DATA_PLANE_RATELIMIT_BACKEND=redis`) makes the per-tenant limit a **single
shared `drl:{tenant}` bucket** so N replicas cannot each admit the full tier
rate. Fail-open if Redis is unreachable; single-node is byte-unchanged. Proven
by **gate m51** (two limiter instances on one Redis admit ≈ burst, not 2×).
Binocle SKUs build `--no-default-features` so they never carry it.

### C2 — Kong rate-limiting stays `policy: local` (per-node) by default
Kong's `rate-limiting` plugin is the **per-IP DoS shield**, NOT the product
limiter (that's C1, per-tenant). `policy: local` means each Kong node shields
itself — correct and zero-dependency for single-node. For a multi-Kong-node
deployment that wants a *globally consistent* per-IP shield, flip the plugin to
`policy: redis` (+ `config.redis.host`) in a Kong overlay; it is deliberately
NOT the default because it adds a Redis hop to every request for a shield that
per-node already satisfies. The product per-tenant limit (C1) is already global.

### C3 — Caches stay per-instance (DONE, by decision)
`verify_cache` (api-key→identity) and `mount_cache` ((tenant,db_id)→DSN) stay
**per-replica**, not shared. Rationale: a miss is cheap post fast-hash
key-verify (~ms, not the old Argon2id seconds), the 30 s TTL bounds staleness,
and **B3** bounds the only correctness-sensitive case — a revoked key is evicted
on its next request via `/v1/admin/evict-verify` (gate m50). A shared cache
would add a network hop to the hot path to save a sub-ms recompute: a bad trade.
This is the **cell architecture** — each data-plane replica is self-sufficient;
only the *durable* shared state (Postgres, Redis streams, the rate-limit bucket)
is centralized.

### C5 — `SHARE_POOLS` decision matrix
| Deployment | `DATA_PLANE_SHARE_POOLS` | Why |
|---|---|---|
| **self-host (base default)** | `0` | Isolation-first; per-tenant pools, small tenant counts, no shared-pool reasoning to audit. |
| **scale / SaaS** (`docker-compose.scale.yml`) | `1` | The 100K-on-one-box lever: shared_rls tenants on one DB collapse to a single pool keyed by connection target, not tenant — pool count becomes independent of tenant count. Isolation is per-request (`apply_rls_context` re-stamps `app.current_tenant_id` + the owner predicate), **proven byte-identical** to per-tenant pools across all 7 engine adapters (gate m46). |
| **prod overlay** | commented entry (operator opts in) | `docker-compose.prod.yml` carries a commented `DATA_PLANE_SHARE_POOLS=1` so a multi-tenant prod operator enables it deliberately after reading this matrix. |

### C4 — Realtime drop visibility (remaining)
The realtime gateway drops events on slow-consumer overflow today only via a
`debug!` log. A `baas_realtime_drops_total` counter + `/metrics` (mirroring the
data-plane atomic pattern) is the remaining C item; it lives in the
`realtime-agnostic` sub-repo and ships with the next realtime image bump.
