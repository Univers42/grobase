# Grobase Offer Sheet v2 — measured, criticized, rebuilt

> Companion to [`grobase-master-plan.md`](./grobase-master-plan.md) and
> [`cost-analysis.md`](./cost-analysis.md). v1 tiers (the ones live in
> `config/packages/packages.json` before this revision) had invented rate
> limits and two indistinguishable tiers. v2 derives every number from a
> benchmark artifact. Footnotes cite the artifact; rows marked _(spec)_ are not
> yet measured.

## The critique of v1 (each point is code- or artifact-grounded)

1. **`free → essential` alias is upside down.** The free plan resolved to the tier that costs
   **~$13/mo to run** (`cost-analysis.md`). Free should resolve to the cheapest shape, not the
   mid one.
2. **`nano` — the flagship wedge — had no entry in `packages.json`.** It is the measured
   PocketBase-killer (5.1 MB / 2.0 MiB, `artifacts/nano-vs-pocketbase.json`) yet was unsellable
   through the tier system.
3. **`basic` and `essential` were the same product.** Identical engines (`[sqlite, postgresql]`)
   AND identical capability mask (`read/write/upsert`, no `batch/aggregate/ddl`). They differed
   only in rps (10 vs 20) and pool size. Two SKUs, one product.
4. **The rps numbers (10 / 20 / 200 / 2000) were invented.** Measured reads sustain far more than
   200 rps at **p95 2.4 ms** (`load-essential-crud.json`); the limiter exists to protect the
   **write** path (insert p99 583 ms — the outbox tail), not the read path. A `basic` cap of
   10 rps throttles reads that the plane serves effortlessly.
5. **`max`'s 50 mounts/tenant ignores the global 256-pool default.** ~6 max-tenants registering
   their quota would exceed the pool registry and thrash it (`registry.rs` `DEFAULT_MAX_POOLS`).

## v2 design rules

- **rps is measured.** `rps = floor(read_capacity × fair_share × 0.5)` where `read_capacity` is
  from `bench-capacity WORKLOAD=read` and `fair_share` is the slice a tier is sold. burst = 2×rps.
- **Tiers differ in capability, not just rate.** `basic` = CRUD-only (the Node-free Rust path);
  `essential` gains `aggregate` (it carries the Node orchestration that can serve it); `pro` adds
  multi-engine + batch + transactions; `max` adds DDL + everything.
- **`nano` is first-class** (engines `[sqlite]`, the single-binary edition).
- **Aliases fixed**: `free → nano`, `pro → pro`, `enterprise → max`. A migration widens the
  `tenants.plan` CHECK so `nano`/`basic` are assignable going forward (additive, non-destructive).
  **Consequence (correct, by design):** under `PACKAGE_ENFORCEMENT=1`, a free-tier tenant is now
  `nano` = **sqlite-only** — it cannot register a PostgreSQL mount until it upgrades to `basic`+.
  This is the tier ladder doing its job (verified live: the engine allowlist returns
  `403 engine_not_in_package`). Tooling that provisions PostgreSQL mounts for many tenants (the
  scale seeder) must set an explicit `plan` of `basic`+ — `make scale-seed` defaults to `pro`.
- **`pool_policy.max_mounts` is bounded by the per-tier `DATA_PLANE_MAX_POOLS` policy** so a tier's
  mount quota can never exceed what the plane can hold for its expected tenant density.
- **Every tier carries `_tenancy_guidance`**: "serves ~N tenants comfortably" cited to its m39
  scale artifact.

## v2 tier matrix

_(rps/burst columns filled from `artifacts/bench/capacity-*.json`; tenancy from
`artifacts/bench/multitenant-*.json`.)_

| Tier | Engines | Capabilities | rps / burst | Mounts | Runs on (measured) | Infra $/mo | Retail | Serves ~ |
|---|---|---|---|---|---|---|---|---|
| **nano** | sqlite | CRUD + graph + masks | 50 / 100 | 1 | 2.0 MiB / 1 binary | $2 | Free / $5 | 1 app |
| **basic** | sqlite, postgresql | CRUD | 100 / 200 | 1 | ~460 MiB / 11 svc | $6 | Free / $9 | 1 app |
| **essential** | postgresql, sqlite | CRUD + **aggregate** | 200 / 400 | 2 | ~660 MiB / 13 svc | $13 | $25–39 | 1 product |
| **pro** | +mysql/mongo/redis/cockroach | +batch +transactions | 400 / 800 | 10 | ~1.4 GiB / 28 svc | $21 | $59–99 | < $1/tenant amortized |
| **max** | +mssql/http | +DDL (all) | 800† / 1600 | 50 | ~3.1 GiB / 41 svc | $41 | $149–299 | < $1/tenant amortized |

The rps column is the v2 change — **measured, not invented**: a single mount sustains ~400 rps of
reads at p95 < 2 ms before the connection cliff (`capacity-essential.json`), so the formula is
`floor(400 × fair_share × 0.5)`. nano/basic/essential sit comfortably below the single-pool ceiling;
pro is at it; **†max's 800 rps requires the B4 pool-policy + supavisor multiplexing to sustain past
the single-pool cliff — flagged, not yet sustained on one node**.

Retail is **unchanged from the shipped catalog** (`cost-analysis.md` + the marketing site): infra
floor × ≥3 margin, with pro/max funded by multi-tenant amortization (< $1/tenant — the m39 run
proves the density). v2 does not re-price; it makes the *capabilities and rates* measured and the
*aliases* sane.

## Applied to

`config/packages/packages.json` (+ the byte-identical Go mirror, m28-gated) · `cost-analysis.md`
· `service-tiers.md` · `apps/baas/site/src/data/{tiers,competitors}.ts`. The migration widening
`tenants.plan` ships as an additive SQL file under `scripts/migrations/postgresql/`.
