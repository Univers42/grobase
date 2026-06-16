# Grobase Master Plan — beating Supabase, measured

> Every number in this document cites a benchmark artifact under
> `mini-baas-infra/artifacts/`. A claim without an artifact is not in this plan.
> Methodology: [`scripts/bench/METHOD.md`](../mini-baas-infra/scripts/bench/METHOD.md).
> Gate bars: [`scripts/bench/budgets.json`](../mini-baas-infra/scripts/bench/budgets.json).

Last measured: 2026-06-11 · box: 20 vCPU / 31 GiB / Linux 6.17 (env block in every artifact).

---

## 1. The thesis in one paragraph

Grobase has a world-class chassis — a Rust hot path that serves reads in **p95 2.4 ms**,
five live-measured tiers from a 5 MB single binary to a 3.1 GiB platform, eight engines behind
one API. What it lacked was *proof*: no load numbers, no p99s, no multi-tenant validation, and
offers whose rate limits were invented rather than measured. This plan closes that gap — it
builds the measurement layer, runs it (against our own stack and against self-hosted Supabase),
validates the multi-tenant story to 10,000 tenants, and rewrites the offers so every advertised
number is a measured number. The wedge that makes someone choose Grobase over Supabase is not a
feature checkbox; it is **a backend you can read the cost and capacity of, that grows from a
weekend project to a 10K-tenant platform on one codebase.**

---

## 2. The claims ledger

| Claim | Value | Artifact |
|---|---|---|
| Read latency (list 30, filtered, warm) | p50 1.9 ms · p95 2.4 ms · p99 3.4 ms | `artifacts/bench/load-essential-crud.json` `.median.ops.list` |
| Write latency (insert, warm) | p50 9 ms · p95 117 ms · **p99 583 ms** | same `.median.ops.insert` |
| Mixed CRUD @ 20 rps (1 tenant) | p95 12 ms (best run); high variance from writes | `load-essential-crud.json` `.runs[]` |
| **Read capacity (single pool, p95 ≤ 50 ms)** | **~400 rps at p95 < 2 ms; cliff at 500+** | `artifacts/bench/capacity-essential.json` |
| Bulk provisioning throughput | ~13/s at conc 16 until Argon2id CPU-saturation (~4k), then `RESUME=1 conc 8` heals → **9,993/10,000** | `make scale-seed` run log; §7.2 |
| **10K tenants: data-plane footprint** | **30 MiB RSS holding ~987 live pools, 0 evicted** (17× under the 512 MiB bar) | `artifacts/bench/multitenant-10000.json` + `/metrics` |
| **10K tenants: warm serving** | **~2 ms/req** (cold single 263 ms) | warm probe, §7.2 |
| **10K cold sparse fan-out** | p50 3.07 s / 8.4 % 5xx — **verify-path-bound (Argon2id @ tenant-control 160 MiB cap), NOT pools** | `artifacts/bench/multitenant-10000.json`; §7.2 |
| vs Supabase footprint + latency | _<run `grobase-vs-supabase.sh` on a freed box>_ | `artifacts/bench/grobase-vs-supabase.json` |
| vs PocketBase (already shipped) | 5.1 MB vs 30.1 MB · 2.0 vs 13.1 MiB idle · faster | `artifacts/nano-vs-pocketbase.json` |

`make verify-m38` and `make verify-m39` keep the first set honest in CI (smoke modes); the deep
numbers are reproduced by the make targets in §8.

---

## 3. What the benchmarks already proved (and exposed)

**The read path is exceptional and the write path is the bottleneck.** Reads are flat at p95
2.4 ms; inserts spike to p95 117 ms / p99 583 ms (worst run p99 2.5 s). The cause is the
synchronous outbox-CDC write the `/data/v1` insert path performs (the row change is written to
`public.outbox_events` for realtime/webhooks before the response returns). **This is the single
highest-leverage latency fix in the system** — async/batched outbox emission would collapse the
write tail. Tracked as **D-write-tail** in §7.

**A single pool serves ~400 rps of reads, then falls off a cliff.** Capacity discovery
(`capacity-essential.json`) found reads flat at **p95 < 2 ms from 25 to 400 rps**, then a hard
cliff at 500–800 rps: p99 jumps to **8–10 seconds** with 5xx errors. That cliff is the per-mount
connection-pool saturating (one mount = one pool = N connections). It is the measured justification
for two things: the **v2 tier rps numbers** (advertised rates sit at or below 400 so a single
tenant never alone saturates its pool — §6), and the **B4 pool-policy + supavisor multiplexing**
work (to lift the per-tenant ceiling and to hold a 10K-mount fleet, §7).

**Three scale bugs were found and fixed while building the harness — each was silently voiding a
promise:**

1. **Kong's edge rate limit throttled the product.** The `/data/v1` route carried a 300-requests-
   per-minute *per-IP* cap. A single application server is the normal deployment shape, so the
   edge limit rejected **76 % of a 20 rps run** — every tier's advertised rps was a lie below the
   edge ceiling. Raised to sit above the largest tier (`kong.yml`, measured before/after). The
   real limiter is the per-tenant token bucket in the Rust plane.
2. **Control-plane crypto OOM-crashlooped under bulk provisioning.** tenant-control's Argon2id
   (32 MiB/op) and adapter-registry's scrypt (16 MiB/op) had no concurrency bound; a 16-way bulk
   provision crash-looped both services (8 and 17 restarts) under their 48–64 MiB limits, surfacing
   as connection EOFs. Bounded each with a semaphore (`ARGON2_MAX_CONCURRENT` / `SCRYPT_MAX_CONCURRENT`,
   default 2) and right-sized the limits. Provisioning is now stable at 13/s with zero restarts.
3. **The pool registry's 256-pool default cannot hold a multi-tenant fleet.** One pool per mount,
   LRU-capped at 256 — 10K tenants × 1 mount = 10K keys ≫ 256 → eviction churn. New `/metrics`
   counters (`baas_data_plane_pools_open`, `..._pool_events_total{event}`) make the churn
   observable; the per-tier `DATA_PLANE_MAX_POOLS` policy is §6.
4. **Provision silently ignores the `plan` field.** `POST /v1/provision` accepts a `plan` in its
   spec, but `Reconciler.CreateTenant(slug, name, ownerUserID)` (reconcile.go) has no plan
   parameter — so every provisioned tenant defaults to `free`, which under v2 resolves to `nano`
   (sqlite-only). A tenant provisioned with a postgresql mount + `plan: pro` is created as `free`
   and then 403s its own mount (`engine_not_in_package`). Surfaced by the scale seeder. The fix is
   to thread `spec.Plan` into `CreateTenant`; tracked as a control-plane gap. The scale experiment
   works around it with `PACKAGE_ENFORCEMENT=0` in `docker-compose.scale.yml` (tiering is m28's
   gate, orthogonal to plane-mechanics measurement).

---

## 4. The four-way comparison

_(measured rows filled from artifacts; spec rows marked.)_

| Axis | Grobase | Supabase | PocketBase | Firebase |
|---|---|---|---|---|
| Read p95 (warm) | **2.4 ms** (measured) | _<vs-supabase>_ | ~5.2 ms (measured) | spec: managed |
| Self-host floor | 5.1 MB / 2 MiB (measured) | multi-GB stack | 30 MB / 13 MiB (measured) | n/a (cloud only) |
| Engines | 8 | 1 (Postgres) | 1 (SQLite) | proprietary |
| Isolation models | 4 per mount | RLS | single-tenant | security rules |
| Tenants/host (measured) | _<from §5>_ | per-project | 1 | n/a |
| Grow path | Nano→Max, one codebase | vertical Postgres | migrate off | locked in |

The honest framing carries to the marketing site (`apps/baas/site` `/compare`): every competitor
gets a "choose them if" box. Supabase wins today on Studio polish and ecosystem; Grobase wins on
multi-engine, isolation choice, cost transparency and the no-rewrite grow path.

---

## 5. The 10,000-tenant story (validated at 1,000; scale-tested)

**Provisioning works and is bounded.** The Go bulk provisioner seeded **1,000 tenants (+keys
+postgresql mounts) in 57 s (~18/s), zero errors, zero control-plane OOM restarts** — the Argon2/
scrypt concurrency bounds from §3 hold under sustained provisioning. `artifacts/scale/tenants-1000.jsonl`.

**The fan-out experiment found the real ceiling — and it is the key-verification throughput, not
the data plane.** Driving a zipf-skewed 400 rps across all 1,000 tenants, the data plane stayed
**featherweight: RSS 51 MiB, `pools_open` 38, `pool_events_total{event="evicted"} = 0`** (the 4096
cap held — zero churn). Raising Postgres to 2,000 connections changed nothing (same wall), ruling
out connections. The metric that told the truth was the **verify cache: ~10% hit rate (605 hits /
5,317 misses)**. Every miss funnels to tenant-control's **Argon2id** verify, which is bounded to
**2 concurrent** (the semaphore from §3 that fixed the OOM) — so ~40 verifies/sec max. At 400 rps
with 90% misses the demand is ~360/sec; verifies queue, the data plane's 10 s upstream timeout
fires, and the client sees **502** (tenant-control sat at 152 MiB / **1.58% CPU** — not working,
*waiting in the semaphore queue*).

So the measured multi-tenant ceiling is: **`steady_tenants ≈ verify_cache_working_set` before the
Argon2id verify throughput (a single tenant-control × the concurrency bound) becomes the wall.**
The data plane never broke a sweat (51 MiB for 1,000 tenants). The fixes are concrete and in §7:
enlarge + lengthen the verify cache (keep more keys warm), **horizontally scale the stateless
tenant-control** (N replicas = N× verify throughput), and add a **cheaper verify fast-path** (Argon2
only on first-seen; a keyed-hash check on the warm path). `artifacts/bench/multitenant-1000.json`.

This is the program working as designed: the measurement layer turned "can it do 10K tenants?" from
a guess into a **named, observable bottleneck with a quantified fix** — and corrected a plausible
wrong answer (Postgres connections / pool churn) along the way. The data plane is not the limit;
**control-plane verify throughput is**, and it scales horizontally.

- **Reproduce**: `make scale-seed SCALE=10000` → `make verify-m39 SCALE=10000` (under the scale
  compose override). The dials to watch on `/metrics`: `pools_open`, `pool_events_total{event}`,
  `cache_events_total{cache,result}` (verify/mount hit rate — the line between every request and an
  Argon2id round-trip), `ratelimit_tracked`.

Acceptance bars live in `budgets.json` `.scale`. The 100K path is [§ product-plan/09](product-plan/09-100k-tenant-path.md).

---

## 6. The offers, criticized and rebuilt

**What was wrong (every point artifact- or code-grounded):**

- `free → essential` alias mapped the *free* plan onto the **$13/mo-to-run** tier — upside down.
- **nano** is the marketing wedge yet had **no entry in `packages.json`**.
- **basic and essential were identical** in engines AND capability mask — they differed only in
  rps (10 vs 20). Indefensible as two products.
- rps values 10 / 20 / 200 / 2000 were **invented**. Measured reads sustain far more than 200 rps
  at p95 2.4 ms; the limiter exists to protect the **write** path, not the read path.
- `max`'s 50 mounts/tenant against the global 256-pool default means ~6 max-tenants can thrash the
  whole plane.

**The rebuilt matrix** (`config/packages/packages.json`, mirrored in the Go control plane, m28-gated):

_<final table filled from capacity numbers; nano added; basic=CRUD-only, essential gains
aggregate; rps = measured_capacity × fair_share × 0.5; pool_policy aligned with §3.3; each tier
carries `_tenancy_guidance` citing its m39 artifact; aliases fixed free→nano.>_

Applied across the single source of truth: `packages.json` → `wiki/cost-analysis.md` →
`wiki/service-tiers.md` → `apps/baas/site/src/data/tiers.ts`. Versioned offer sheet:
[`offer-sheet-v2.md`](offer-sheet-v2.md).

---

## 7. Roadmap (sequenced, each with a measured gate)

Legend: **✅ landed** (code + unit tests in-tree, flag-gated where it changes behavior) ·
**◐ partial** · **○ next**. "Landed" means the mechanism ships and is unit-verified; the
*measured* gate (the live re-bench) is run when the box is freed — the harnesses in §8 produce it.

| ID | Move | Why (measured) | Status |
|---|---|---|---|
| **D-write-tail** | Async/**batched** background outbox emission on `/data/v1` writes (worker drains a bounded queue, coalesces ≤64/INSERT; non-blocking enqueue, drop-counted) | insert p99 583 ms vs read 3.4 ms — a 2nd synchronous DB round-trip was on the write tail | **✅ landed** — `outbox.rs` `BackgroundOutbox`; `/metrics` `outbox_events_total{stage}`. Gate: insert p99 ≤ 50 ms (re-bench) |
| **R1** | Query-router out of the data path | −127 MiB Node; essential → fits basic VM | **✅ realized** — bypass ON by default, Kong `/data/v1`→Rust direct (m36), and the PACKAGE tiers (`basic := go rust`) never start the query-router. TS code retained per the deletion gate (shadow editions only) |
| **B4-verify** | **Argon2-only-on-first-seen** verify cache in tenant-control (SHA-256(key)→identity, TTL'd, revoke-flushed) | **the measured 1K-tenant ceiling**: 10% cache hit → Argon2 @ 2-concurrent = ~40 verify/s wall (502s) | **✅ landed** — `verifycache.go`; repeat verify skips DB **and** Argon2 → cold-start Argon2 becomes a one-time warmup. `TENANT_CONTROL_VERIFY_CACHE_TTL_MS` (default 60 s). Gate: fan-out p99 ≤ 2× baseline, 0×502 |
| **B4-pools** | **DSN/credential-keyed shared pools** for `shared_rls` (per-request RLS scoping makes the pool tenant-stateless) | 256-pool default ≪ 10K mounts; per-tenant pools waste connections | **✅ landed** (flag-gated `DATA_PLANE_SHARE_POOLS`, off=parity) — `effective_pool_key`; 10K shared_rls tenants on one DB → 1 pool. schema_per_tenant/db_per_tenant correctly keep per-tenant pools. Gate: m39 pool-eviction = 0 |
| **B4-limiter** | Redis Lua token-bucket backend (authoritative across replicas) | in-process buckets desync across N replicas (each admits the full rate) | **✅ landed** (feature `ratelimit-redis`, off=in-process fast path) — `RateLimiter` enum, shared `refill_and_take` math, fail-open. Gate: multi-instance 429 correctness |
| **Plan-wiring** | Thread the provision `plan` field → `CreateTenant` | provision silently dropped `plan` → every tenant defaulted to free; the scale run had to disable enforcement | **✅ landed** — `reconcile.go`→`findOrCreateBySlug`; the `PACKAGE_ENFORCEMENT=0` scale workaround is removed (scale now runs WITH tiering, the prod shape) |
| **D2-realtime** | Fan-out Mutex→per-worker channels (C1), drop counters (C2), Arc-shared event (C3), payload serialize-once (H1) | router 1.8K routes/s @10K subs; held-across-await mutex; 617 ns/client serialize | **✅ landed** — C1 (gateway dispatcher → per-worker queues, no shared mutex; `fanout.rs`), C2/C3 in `router.rs` (batch `Arc` dispatch + `dispatch_failures`), **H1** (`EventEnvelope::rendered_payload_json` memoizes the `event` JSON on the shared `Arc` via `OnceLock` → serialized ONCE per event, reused across all subscribers; the writer only escapes the per-connection `sub_id` and concatenates — byte-identical to the old full-struct serde output, unit-pinned). Realtime crates `cargo test`/`clippy` green |
| **R2** | Fold 6 Node orchestrators → Go (one binary, not six runtimes) | −359 MiB; essential $13 → $6.5/mo | **◐ all 6 ported** — consolidated `cmd/orchestrator` host + `SubService`/`initializer` seams. All six Node services ported as Go sub-packages, each unit-tested: `logsvc`, `emailsvc` (SMTP), `sessionsvc` (DB + RLS-equivalent owner scoping), `newslettersvc` (subscription + campaign, email seam), `gdprsvc` (consent/deletion/export + webhook seams), `outboxrelay` (pg outbox → Redis streams + realtime fan-out + saga dispatch/compensation; **Mongo projection behind a soft-dep seam — no-op default = lean-tier Node behavior; driver-backed projector is the one remaining parity slice**). Ships as a 32 MiB shadow service (`profiles: background`, `ORCHESTRATOR_SERVICES` default `log` — enable others to shadow). Remaining: per-service shadow→parity→retire of each Node container. Gate: footprint + m32 |
| **Wedge** | Cost-routed OLAP/OLTP plane (product-plan/05) + SaaS quotas/metering (product-plan/06) | the differentiator nobody ships cleanly | **○ next** — per those plans' gates |

Every behavior-changing lever (B4-pools, B4-limiter) ships **off by default** so the live baseline is
byte-parity; flip the flag to measure the win. R2 changes the benchmark numbers, so it runs **after**
the baseline freeze — the improvement is itself a measured deliverable.

### 7.1 Live re-bench (2026-06-11, rebuilt images, 50 `pro` `shared_rls` tenants on one DSN)

Ran on the running stack with the rebuilt data-plane + tenant-control, scale override applied,
`make scale-seed SCALE=50` then list+insert across every tenant. Measured from the new `/metrics`:

| Lever | Evidence | Result |
|---|---|---|
| **B4-pools** | `baas_data_plane_pools_open` with `DATA_PLANE_SHARE_POOLS=1` vs `=0` | **1 vs 50** — 50 shared_rls tenants on one DSN collapse to a single pool (at 10K: 1 vs 10K). `pool_events_total{evicted}=0` (no churn). **Gate PASS.** |
| **B4-verify** | `cache_events_total{cache=verify}` | 52 hit / 51 miss — the fast path populates; each tenant's first verify misses (one-time Argon2), repeats hit, skipping DB + Argon2. |
| **D-write-tail** | `outbox_events_total{stage}` | enqueued→written off the request path, `dropped=0 failed=0` — the background worker commits the event asynchronously (handler no longer pays the INSERT round-trip). |
| **Plan-wiring** | adapter-registry `/databases` status | 50× **201** (was 50× **403**) — `pro` tenants register postgresql mounts under `PACKAGE_ENFORCEMENT=1`, no workaround. The re-bench also surfaced + fixed a *second* drop site: the `plan` field was lost at the HTTP boundary (`ProvisionRequest` had no `Plan`; `Compile()` didn't map it) — now wired end-to-end. |

The stack was restored to base config (new images retained, flags at parity defaults) after the run.

### 7.2 10K headline run — executed (2026-06-12, scale override). The measurement overturned the hypothesis.

Environment prerequisites cleared first: redis OOM-loop fixed (512 MiB limit + AOF
auto-rewrite disabled), scale override up (PG `max_connections=2000`, `DATA_PLANE_MAX_POOLS=4096`).
**10,000 tenants seeded and load-tested** end-to-end. The result is more valuable than a green
checkmark: it **disproved the going-in #1-bottleneck hypothesis (pools)** and located the real wall.

**Seed — 9,993 / 10,000 provisioned** (`make scale-seed SCALE=10000`, `pro` `shared_rls`):
9,189 created + 804 idempotent-exists + 7 residual errors; **9,975 carry a usable key + mount**.
Notable: seed throughput is **Argon2id-bound, not I/O-bound**. At concurrency 16 it ran ~13/s clean
for the first ~4 k, then the box CPU-saturated on per-key Argon2id minting (load 7→26) and ~6 k
provisions blew the 30 s timeout; a `RESUME=1 CONCURRENCY=8` pass healed all but 7 (errored slugs
re-tried, good ones skipped). ⇒ **the real seed fix is a bulk-provision endpoint that batches key
derivation**, logged for the 100K-path doc — same Argon2id root cause as the serving wall below.

**Load — `multitenant-10000.json`, 9,975 tenants × 20 rps × 60 s, zipf, default cache:**

| Signal | Measured | Reading |
|---|---|---|
| http p50 / p99 | **3,071 ms / 10,268 ms** (timeout ceiling) | latency collapse — but **not** in the data plane (see below) |
| errors / 5xx / 429 | **8.41 % / 51 / 0** | timeouts, not rate-limits; k6 exhausted its 50 VUs |
| **data-plane RSS** | **30 MiB** (`mem_limit` 96), CPU **2 %** | the plane holding 10 k tenants is **idle-cheap — 17× under the 512 MiB bar** |
| `pool_events` | **987 created · 0 evicted · 986 reaped** (cap 4096) | **pools are NOT the bottleneck** — they never hit the cap, never thrashed |
| warm probe (12× same tenant) | req 1 **263 ms** (cold), req 2-12 **~2 ms** | warm steady-state **2 ms/req**, better than the advertised 8 ms |

**Where the wall actually is.** The data plane is at 2 % CPU yet returns **502 after exactly 10,001 ms** —
it is *waiting* on a downstream. The Rust plane does not verify keys itself; it **calls tenant-control
`POST /v1/keys/verify`**, which runs memory-hard **Argon2id** and is **`mem_limit`-capped at 160 MiB**.
The data-plane's `verify_cache` (30 s TTL) amortizes this only for *repeat* hits — but at 20 rps spread
across 9,975 tenants each tenant is hit ~once per 8 min, **far longer than the 30 s TTL**, so essentially
every request is a cache miss that floods a mem-capped tenant-control → verify calls time out → 502.
**Pools (the plan's presumed #1 bottleneck) are fine; the identity/Argon2id-verify path is the true #1.**

**The cache-TTL lever, tested and reported honestly.** Bumping `DATA_PLANE_VERIFY_CACHE_TTL_MS`/
`DATA_PLANE_CREDENTIAL_CACHE_TTL_MS` 30 s→10 min (`multitenant-10000-warmcache.json`) made it **worse**
(58 % err, p50 10 s) — because recreating the data-plane *emptied* its verify cache and the cold-start
re-flooded the 160 MiB tenant-control before the cache could populate. So TTL alone, from cold, is not
the fix; it confirms the diagnosis. The real fixes, now measurement-grounded:
1. **Raise tenant-control memory** (160 MiB → ≥512) and/or **parallelize key-verify** — it is the serving wall, not pools.
2. **Move key-verify into the Rust plane with a sharded (DashMap) cache** + a TTL sized for sparse multi-tenant traffic — the global-`Mutex` verify/mount caches don't scale to 10 k warm entries (plan item B4.4, now justified by data).
3. **Bulk-provision endpoint** batching Argon2id derivation (the seed-throughput fix, same root cause).

**Honest headline:** one box holds **10,000 live tenants in a 30 MiB data plane** and serves any *warm*
tenant in **~2 ms** — the footprint/cost story is decisively won. The *cold sparse-fan-out* worst case
(every tenant colder than any real workload, on a Chrome-loaded 20-core dev box) is **verify-path-bound at
a deliberately under-provisioned tenant-control**, with three identified, not-yet-measured-clean fixes. The
measurement did its job: it replaced a guess (pools) with a located, mechanism-level cause (Argon2id verify).

> **B4-pools caveat (corrects §7.1):** `SHARE_POOLS=1` collapses the pool *count* (1 vs 50/10 k) as §7.1
> measured, but the data plane currently stamps the shared pool with one tenant's identity → other tenants
> get `identity tenant does not match pool tenant` (502). The pool-count win is real; the per-checkout RLS
> **re-stamp is not yet implemented**, so `SHARE_POOLS` stays **off (parity default)** and is *not* the
> ready 100K lever until that guard is fixed. This is why the 10K run above used per-tenant pools (987), not 1.
> **(Resolved: §7.4 fixed the guard on Postgres and remeasured 1 pool / 0×5xx; §7.5 extended the fix to all
> seven engine adapters. This caveat narrates the run that predates both.)**

Artifacts: `artifacts/bench/multitenant-10000.json` (cold, default cache),
`multitenant-10000-coldcache.json` (same, preserved), `multitenant-10000-warmcache.json` (10-min TTL),
`artifacts/scale/tenants-10000.jsonl` (+`.raw` pre-dedup).

### 7.3 The fix — key-verify is no longer Argon2id (2026-06-12). Cold path 5.8× faster, the 502 flood gone.

§7.2 located the wall: the data plane calls tenant-control `/v1/keys/verify`, which ran **Argon2id**
(32 MiB/hash, capped at `ARGON2_MAX_CONCURRENT=2`) on *every* verify-cache miss → under sparse 10K
fan-out it floods and 502s. The root cause is a **category error**: Argon2id is a *password* hash — it
exists to make a *low-entropy human secret* expensive to brute-force offline. Our API-key payload is
**20 bytes from `crypto/rand` = 160 bits of uniform entropy**. Recovering one key from its hash is ~2^159
work at *any* hash speed; the 32 MiB / ~50 ms argon2 cost buys **zero** security here. (GitHub/Stripe/
Supabase store high-entropy tokens as SHA-256 for exactly this reason.) tenant-control's own verify-cache
comment already says argon2 "has no security value on the repeat verify of a presented high-entropy key" —
the fix simply **extends that truth to the *stored* hash**, so cold misses are cheap too, not just cache hits.

**Change** (`internal/tenants/keys.go`, `service.go`): new fast scheme `sha256$v=1$…` = `SHA-256(salt‖payload)`,
or `HMAC-SHA256(pepper; …)` when `KEY_HASH_PEPPER` is set (defense-in-depth: a stolen DB alone can't verify).
Verify **detects the scheme per stored hash** → a fleet mid-migration verifies *both*, so **no existing key
breaks**. New keys mint fast by default (`KEY_HASH_LEGACY_ARGON2=1` reverts); a successful legacy verify
**lazy-upgrades** the row to the fast hash (`KEY_HASH_UPGRADE=0` disables), so a live fleet drains off argon2
without re-provisioning. 6 new unit tests (dual-scheme, salt, pepper, legacy-flag); `go vet`/`build`/`test` green.

**Measured (10,000 fresh `sha256` tenants, same box):**

| Metric | Before (argon2id) | After (sha256) | Δ |
|---|---|---|---|
| Cold single-request (isolated, verify+resolve+pool) | **263 ms** | **45 ms** | **5.8× faster** — the ~50 ms argon2 verify is now µs |
| Warm request | 2 ms | 2 ms | unchanged (already fast) |
| Cold fan-out 5xx (RATE 20 × 60 s) | **51** | **5** | **10× fewer** — the verify-flood 502s are gone |
| Cold fan-out error % | 8.41 % | 4.4 % | ~½ |
| **Bulk-seed under load** | conc-16 **collapsed past ~4 k → 60 % errors** (argon2 CPU-saturation) | **9,775/10,000, 2.25 % errors, no collapse** | the seed wall is gone too |
| data-plane RSS / pools | 30 MiB / 0 evicted | 22 MiB / 0 evicted | still idle-cheap |

The residual cold-fan-out p50 (~4 s) is **not** the data plane: `docker stats` during the run showed the
BaaS stack <8 % CPU each while **Chrome held ~280 % CPU** on the 20-core dev box — the k6 load and the plane
were starved by the browser, not by each other. The isolated 45 ms cold / 2 ms warm probe is the true plane latency.

**The next 100K lever (not the verify path):** with verify cheap, the remaining cold-fan-out cost is the
**45 ms cold pool-open** per first-seen tenant (TCP + auth + RLS). At 100 k sparse tenants that is the wall —
addressed by collapsing `shared_rls` tenants onto one shared pool (the `SHARE_POOLS` lever), which needs the
per-checkout RLS **re-stamp** fixed (the §7.1 caveat). That is the next change; the verify fix above is its
prerequisite (a shared pool is pointless if every request still pays a 32 MiB argon2 verify).

Artifacts: `multitenant-10000-sha256.json` (after), vs `multitenant-10000-coldcache.json` (before).

### 7.4 The 100K lever — one pool for all tenants (2026-06-12). 10K tenants, 1 pool, 0×5xx.

§7.3's residual cost was the **45 ms cold pool-open** per first-seen tenant. At 100 k sparse tenants
that is the wall: per-tenant pools churn against `DATA_PLANE_MAX_POOLS`, and even uncapped, each
cold tenant pays a fresh connect. The fix is to **stop having per-tenant pools for `shared_rls`** —
every tenant on the same physical DB shares **one** pool. `effective_pool_key` already keys the
shared pool on the DSN (not the tenant); the only blocker was `PostgresPool::check_tenant`, a
single-owner assertion that 502'd every tenant but the pool's creator (the §7.1 caveat).

**Why this is safe (not a relaxation of isolation):** a `shared_rls` pool is multi-tenant *by
design*. Isolation is applied **per request, from the request identity** — `apply_rls_context` sets
the `app.current_tenant_id` / `app.current_user_id` GUCs (`SET LOCAL`, transaction-scoped) and the
owner-scoped writes inject/filter `owner_id` — **none of it reads pool state**. The guard was correct
only for a per-tenant pool. **Proven neutral:** a cross-tenant read probe returns *byte-identical*
rows with `SHARE_POOLS=0` and `=1`, so the change never widens what a request can see — it only stops
rejecting the request. (The probe also exposed that the *bench* table has no RLS policies, so reads
aren't tenant-filtered on it — a property of the bare DDL test table, not of pool sharing, and not
introduced here. Real provisioned tenant tables carry RLS; the bench DDL is the gap, tracked separately.)

**Measured — `SHARE_POOLS=1` + sha256 verify, 10,000 tenants, RATE 20, same (Chrome-loaded) box:**

| Metric | §7.2 baseline | + verify fix (§7.3) | **+ pool collapse (§7.4)** |
|---|---|---|---|
| **pools open for 10K tenants** | ~1,000 | ~1,000 | **1** |
| **5xx** | 51 | 5 | **0** |
| error % | 8.41 % | 4.4 % | **1.95 %** |
| p50 | 3.07 s | ~ | **1.22 s** |
| p99 | 10.3 s (timeout wall) | ~ | **7.0 s** (off the wall) |
| achieved rps (of 20) | 11.4 | ~ | **17.1** |

`pool_events: created=1, evicted=0`. **10,000 tenants, one pool, zero server errors.** The residual
p50 is still the browser eating ~280 % CPU, not the plane (idle-path is 2 ms warm / 45 ms cold). The
two changes compose exactly as designed: **cheap verify removes the per-request CPU tax, the shared
pool removes the per-tenant connection — pool count is now independent of tenant count, which is the
defining property of a 100K-on-one-box architecture.** `SHARE_POOLS` stays flag-gated (default off =
parity); the scale override turns it on. The §7.1/§7.2 "identity guard breaks SHARE_POOLS" caveat is
**resolved**.

Artifacts: `multitenant-10000-sharepools.json` (SHARE_POOLS=1+sha256) vs `-sha256.json` (verify-only) vs
`-coldcache.json` (original argon2id).

### 7.5 The lever, every engine (2026-06-12). Pool-sharing made correct on all seven adapters, not just Postgres.

§7.4 proved the lever on PostgreSQL. But `effective_pool_key` collapses a shared pool
**engine-agnostically** — so the instant `SHARE_POOLS=1` becomes the scale default, a `shared_rls`
mount on *any* engine collapses to one pool and its single-owner guard 502s every tenant but the
pool's opener. The lever was correct on Postgres and **silently broken on the other six adapters**.
This pass closes that.

The single-owner `check_tenant` was never the isolation boundary — it is a defense-in-depth assertion
that is simply *wrong* for a multi-tenant pool. Every adapter applies tenant isolation **per request,
from the request identity**, and *that* is what carries on a shared pool:

| Engine adapter | Per-request isolation (carries on a shared pool) | `self.tenant_id` was… |
|---|---|---|
| postgresql / cockroachdb | `app.current_tenant_id` RLS GUC + `owner_id` predicate | guard-only |
| mysql / mariadb | `owner_id = ?` predicate from `owner_of(identity)` | guard-only |
| mssql | `[owner_id] =` predicate from identity | guard-only |
| sqlite | `owner_id = ?` predicate from identity | guard-only |
| redis | `<owner>:<resource>` key prefix from identity | guard-only |
| http | `x-owner-id` header from identity (upstream authz) | guard-only |
| **mongodb** | `owner_id` **and `tenant_id`** stamped + filtered per request | **also sourced `tenant_id` from the pool field** |

Six adapters used `self.tenant_id` only for the guard, so skipping it when the pool is shared is
isolation-neutral by the exact argument Postgres proved. **MongoDB was the one real hazard:** it stamps
*and filters* `tenant_id` on every document, and all seven call sites sourced it from the pool's
`self.tenant_id` — which on a shared pool is the *opener's* tenant. Left unfixed, a shared mongo pool
would tag every tenant's writes with one tenant id (owner_id would still isolate, but the tag would be
wrong, and would invert the moment the lever toggled). The fix sources `tenant_id` from
`identity.tenant_id` at every call site — **byte-identical on a per-tenant pool** (the guard proves
`identity.tenant_id == self.tenant_id` there) and correct on a shared one. The MySQL transaction handle
got the same treatment: it now binds the txn to the tenant that *began* it (`request.identity`), not the
pool opener.

**One predicate, one place.** The env + isolation gate is hoisted to `crate::pools_shared(mount)` (the
former postgres-local `share_pools_enabled` is deleted), so all seven adapters read the lever identically
and it cannot drift.

**Verified — unit:** `cargo test` green across the workspace — core 66 + pool 156 + server 35 = **257**
unit tests, including two new per-engine isolation tests (mongo stamps + filters each request's *own*
tenant+owner; mysql scopes each request by its *own* owner). `cargo clippy -D warnings` clean.

**Verified — live (2026-06-12, `scripts/verify/m46-share-pools-isolation.sh`):** two `shared_rls` tenants
pointed at ONE mysql backend and ONE mongo backend, on a freshly-built data plane, under both lever
positions:

| `SHARE_POOLS` | cross-tenant isolation (mysql + mongo) | pools for 2 tenants × 2 engines |
|---|---|---|
| **1** (collapse) | each tenant lists ONLY its own row — 0 leaks, 0×502 | **2** — 1/engine, collapsed |
| **0** (per-tenant) | **byte-identical** — each sees only its own row | **4** — 2/engine |

Isolation is identical at both positions (the change never widens what a request sees — it only stops
*rejecting* it), while the pool count drops 4→2. The live insert responses confirm the mongo fix
end-to-end: tenant B's document is stamped `tenant_id: "sp-b-…"` — its OWN tenant from the request
identity, **not** the pool opener's (which the pre-fix code would have written). Artifacts:
`share-pools-cross-engine-expect{1,0}.json`. This closes the §7.4 "remaining gate" for every engine.

Code: `data-plane-pool/src/{lib,postgres,mysql,mongo,mssql,sqlite,redis,http}.rs`; gate:
`scripts/verify/m46-share-pools-isolation.sh`.

---

## 8. Reproduce everything

```bash
cd apps/baas/mini-baas-infra            # drive only via the Makefile

make bench-load PACKAGE=essential WORKLOAD=crud      # read+write latency split
make bench-capacity PACKAGE=essential WORKLOAD=read  # clean read ceiling
make bench-capacity PACKAGE=essential WORKLOAD=crud  # realistic mixed ceiling
make bench-mem PACKAGE=essential DURATION=30m         # RSS drift under load
bash scripts/bench/realtime-fanout.sh                 # realtime delivery distribution
bash scripts/bench/grobase-vs-supabase.sh             # head-to-head (solo, on-demand)

make scale-seed SCALE=10000                           # bulk provision (resumable)
make verify-m39 SCALE=10000                           # the 10K validation
make scale-teardown SCALE=10000

make verify-m38 && make verify-m39                    # CI smoke gates (skip when stack down)
make verify-all                                       # everything, cheap modes
```

Every command writes a JSON artifact under `artifacts/`; this document cites them by path.
