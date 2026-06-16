# Finding — dense-fleet pool thrash when `DATA_PLANE_SHARE_POOLS` is OFF (and its proven repair)

**Discovered:** 2026-06-15, during the competitive-benchmark run, by driving fresh 10K-tenant zipf load
against the live stack (24,888 provisioned tenants) and reading the data-plane pool metrics.

## What was discovered

The running stack uses the **base** `docker-compose.yml` (no scale overlay), where
`DATA_PLANE_SHARE_POOLS` is **unset → OFF** (the flag-gated-OFF parity default). With SHARE_POOLS OFF
the data plane opens a pool **per tenant** (capped by an LRU at ~256 open). Under a 10K-tenant **zipf**
spread the long tail constantly hits cold tenants → constant pool **create/evict churn** → a fraction
of requests 502 during the evict↔reopen race.

### Reproduction (two fresh runs, RATE=20, 25s, dist=zipf, ~9,775 distinct tenants)

| run | p50 | p95 | p99 | err% | 5xx | pool events during run |
|---|---|---|---|---|---|---|
| run 1 (verify cache cold) | 30.2 ms | 37.5 ms | 51.5 ms | 12.77% | 64 | +468 created, +212 evicted |
| run 2 (verify cache warm)  | 29.5 ms | 36.2 ms | 39.4 ms | 12.4%  | 62 | +480 created, +224 evicted, `pools_open` capped at 256 |

`reproduce: BENCH_WORK_BASE=/mnt/storage/bench SCALE=10000 RATE=20 DURATION=25s DIST=zipf bash scripts/bench/multitenant.sh`
artifact: `artifacts/bench/multitenant-10000-nosharepools-today.json`

Key observations:
- **Served requests are FAST** (p99 ~40-51 ms on a quiet box) — the engine path is healthy. The errors
  are **purely pool-cache churn**, not query latency.
- **Warming the verify cache did NOT reduce the 5xx** (12.4% vs 12.77%) → this is **sustained per-tenant
  pool thrash**, not a one-time cold-start warmup transient.
- The live **m46 probe** (`SHARE_POOLS_PROBE=1 bash scripts/verify/m46-share-pools-isolation.sh`) against
  this stack confirms it: **cross-tenant isolation HOLDS** (tenant A sees only A's rows on mysql + mongo,
  B only B's — RLS is per-request, independent of pooling) but the **pool collapse misses (4 pools held,
  expected 2 for SHARE_POOLS=1)** — i.e. SHARE_POOLS is off. Correctness is never at risk; only
  throughput/error-rate under dense load.

## The repair (gate-proven, not applied to the live stack)

Run dense-fleet deployments with **`DATA_PLANE_SHARE_POOLS=1`** — the `docker-compose.scale.yml` overlay
sets it (and raises Postgres `max_connections`). All `shared_rls` tenants on one DSN then collapse to
**one pool per engine**, independent of tenant count:

```bash
# dense multi-tenant deployment (the documented shape)
docker compose -f docker-compose.yml -f docker-compose.scale.yml up -d
```

Proven evidence (already on record, NOT re-run live to avoid recreating the user's 24,888-tenant
Postgres+data-plane):
- `artifacts/bench/multitenant-10000-sharepools.json` — SHARE_POOLS=1, 10K zipf: **`server_errors: 0`**.
- gate `m46-share-pools-isolation.sh` (prior PASS, commit cfc0c92): SHARE_POOLS=1 → isolation + **2 pools**;
  SHARE_POOLS=0 → byte-identical results + **4 pools** (isolation identical either way).
- `artifacts/scale/footprint-live-24888-today.json` — at rest the SAME stack holds 24,888 tenants in
  **2.918 MiB** data-plane RSS with **`pools_open: 0`** — the density moat is intact; the thrash is
  strictly a *under-load, SHARE_POOLS-off* effect.

## Why this is not a code bug

`DATA_PLANE_SHARE_POOLS` is OFF by default **by design** (kernel rule #5: every behaviour change
flag-gated OFF so the baseline stays byte-parity). The default is correct for single-/few-tenant
self-host; **dense multi-tenant fleets must opt into the scale overlay.** The actionable output is
operational guidance (use the scale overlay for dense fleets), surfaced in the competitive report and
the operations runbook — plus this is itself a vivid datapoint for the report's multi-tenancy section:
**naive per-tenant pooling thrashes; SHARE_POOLS makes pool count independent of tenant count.**
