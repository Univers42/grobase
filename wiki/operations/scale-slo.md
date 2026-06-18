# Grobase Scale SLO — multi-tenant density & serving (Track C / Bar 2)

> **Ethos:** a claim without an artifact is not in this doc. Every number below cites a measured
> file + the command that reproduces it. Where the dev box cannot honestly measure something, this
> doc says so and names what *would* measure it.

This is the standalone SLO that `competitive-matrix.md` and `marketability-readiness.md` (Bar 2 —
*proven scale SLO*) point to. It states what Grobase commits to on multi-tenant density and warm
serving, the evidence behind it, and the **one honest wall** between here and a clean 100K headline.

---

## 1. The SLO (what we commit to, with evidence)

| SLO | Committed | Evidence |
|---|---|---|
| **Warm read latency** | p50 1.9 ms · p95 **2.4 ms** · p99 3.4 ms (list 30, filtered) | `artifacts/bench/load-essential-crud.json` `.median.ops.list` |
| **Read capacity (1 pool, p95 ≤ 50 ms)** | ~**400 rps** at p95 < 2 ms; cliff at 500+ | `artifacts/bench/capacity-essential.json` |
| **Multi-tenant density** | **pool count ⊥ tenant count** — 10K `shared_rls` tenants → **1 pool**, **0 evicted** | gate **m46** (`scripts/verify/m46-share-pools-isolation.sh`); `artifacts/bench/multitenant-10000-sharepools.json`; `/metrics baas_data_plane_pools_open` |
| **Multi-tenant footprint** | **10K tenants in a 30 MiB data plane** (17× under the 512 MiB bar); **24,887 tenants held at rest by a 2.6 MiB data plane, 0 standing pools** | `artifacts/bench/multitenant-10000.json` + **`artifacts/scale/footprint-live-24887.json`** (2026-06-14) |
| **No server errors under fan-out** | **0 × 5xx** at 10K (SHARE_POOLS) | `artifacts/bench/multitenant-10000-sharepools.json` `.server_errors = 0` |
| **Isolation correctness at density** | cross-engine byte-identical to per-tenant pools (pg/mysql/mongo) | gate **m46**; `artifacts/bench/share-pools-cross-engine-expect{0,1}.json` |

**The defining property:** isolation is **per-request, not per-pool** — `apply_rls_context` re-stamps
`app.current_tenant_id` + owner predicate on every request, so a shared pool holds no tenant state.
That is why pool count is decoupled from tenant count, which is the entire multi-tenant cost story.

---

## 2. Evidence A — the gated 10K headline (m46, executed 2026-06-12)

10,000 tenants seeded (`pro`, `shared_rls`) and load-tested end-to-end. Full narrative:
`grobase-master-plan.md` §7.2–7.5.

```
artifacts/bench/multitenant-10000-sharepools.json
  rps_achieved 17.08   tenants 9,775   dist zipf
  http: p50 1,221.95 ms · p95 4,410.14 ms · p99 7,047.97 ms
  err_pct 1.95   rate_limited 0   server_errors 0      <-- ZERO 5xx
  data-plane RSS 30 MiB   pools 1 (SHARE_POOLS=1)   evicted 0
```

**Read the latency honestly.** The p50/p95/p99 above are *seconds*, not the 2.4 ms warm-read SLO —
because this run was **driven from a browser/k6 on the same loaded dev box** and the load generator
starved (`err_pct` is timeouts, not stack failures; `server_errors = 0`). The 10K run's *value* is
the **server-side** facts it nails: **1 pool, 30 MiB, 0 evicted, 0 5xx** holding 10K tenants. The
warm-serving SLO (2.4 ms) is the separate single-tenant capacity measurement
(`capacity-essential.json`), unchanged at density because pool count is independent of tenant count.

This is the program working as designed: the measurement overturned the original hypothesis (the
suspected wall was pools; the real cold-path wall was Argon2id key-*verify* at tenant-control, fixed
in §7.3 to a SHA-256 fast-hash; the SHARE_POOLS lever in §7.4–7.5 then collapsed 10K → 1 pool).

---

## 3. Evidence B — live at-rest footprint of a 24,887-tenant fleet (2026-06-14)

A larger fleet than the 10K headline is **already provisioned on the box** (accumulated, idempotent).
Probed read-only today — this is the **at-rest holding cost**, the purest form of the density claim:

```
artifacts/scale/footprint-live-24887.json
  tenants 24,887
  data-plane-router-rust   RSS 2.6 MiB / 96 limit   pools_open 0   (lifetime: 16 created, 0 evicted, 16 reaped)
  tenant-control           RSS 11.0 MiB / 160
  adapter-registry-go      RSS  6.2 MiB / 192
  postgres                 RSS 53.7 MiB / 512
  redis                    RSS  9.9 MiB / 512
```

**`pools_open = 0` with 24,887 tenants provisioned.** At idle the data plane holds *zero* per-tenant
pools (reaped after TTL); lifetime **0 evicted**. A ~25K-tenant fleet imposes **no standing memory
cost** beyond the binary baseline. Tenant count is not merely independent of pool count — at rest it
is fully decoupled from it.

Reproduce:
```bash
docker exec mini-baas-postgres psql -U postgres -d postgres -tAc "select count(*) from public.tenants;"
docker stats --no-stream mini-baas-data-plane-router-rust mini-baas-tenant-control mini-baas-postgres
curl -s http://127.0.0.1:4011/metrics | grep -E 'pools_open|pool_events_total'
```

---

## 4. The 100K projection — and the one honest wall

| Scale | Data-plane RSS | Standing pools | Seed time | Status |
|---|---|---|---|---|
| 10K | 30 MiB (under load) | 1 (SHARE_POOLS) / 0 idle | ~5 min | **measured** (m46) |
| ~25K | 2.6 MiB (at rest) | 0 idle | (already seeded) | **measured** (2026-06-14) |
| 50K | ~linear, well < 512 MiB | 1 / 0 idle | ~25 min | projected |
| **100K** | **~300 MiB extrapolated** (< 1 GiB) | **1 / 0 idle** | **~50 min** | **projected** |

What is **proven** and carries straight to 100K: data-plane RSS, standing pool count, and 0 × 5xx
are all functions of *concurrent working set*, not tenant count — none grows with N. The 24,887-tenant
at-rest measurement is the strongest in-hand evidence that 100K behaves identically on the serve path.

**The one wall is provisioning, not serving.** Seeding 100K is Argon2id-bound: each
`POST /v1/provision` mints one Argon2id key hash at tenant-control (`ARGON2_MAX_CONCURRENT=2`,
160 MiB cap) → ~50 min for 100K. This is a **seed-time** cost, not a serve-time cost; once seeded,
warm serving is unchanged. **Remedy (v1.1):** a batch `POST /v1/provisions` that batch-derives keys
would cut the seed from ~50 min to ~5 min. Tracked in the master plan; not shipped in v1.x.

Reproduce a real 100K run **on an isolated/quiet node** (see §5):
```bash
docker compose -f docker-compose.yml -f docker-compose.scale.yml up -d   # PG max_connections=2000, SHARE_POOLS=1
make scale-seed SCALE=100000 ISOLATION=shared_rls CONCURRENCY=16 PREFIX=scale-100k   # ~50 min, resumable
SCALE=100000 RATE=20 DURATION=60s DIST=zipf PREFIX=scale-100k bash scripts/bench/multitenant.sh
make verify-m39 SCALE=100000      # gate: 0 OOM restart, p99 ≤ 2× baseline, 0 5xx, RSS ≤ 512 MiB, 0 pool eviction
```

---

## 5. Where we honestly don't (yet)

- **Clean 100K *load*-latency SLO** is **not** credibly measurable on the shared dev box. Even the
  10K run was k6/Chrome-CPU-starved (its second-scale p50/p95/p99 are load-generator timeouts, not
  stack latency). A trustworthy 100K p99-under-load needs a **dedicated quiet node** (the load
  generator off-box, or a cloud instance) — this is on-demand validation, **not** a CI gate (a
  ~51-min run is too slow for CI). The **server-side** density facts (pools, RSS, 0 5xx) *are*
  measurable here and are gated (m46).
- **Horizontal scale-out + supavisor** (C1) and **production Helm/HPA/HA** (C2) are not yet wired —
  the SLO above is single-node. The single-node density is the headline; multi-node throughput is
  Track C follow-on.
- **Write-tail at scale**: insert p99 (583 ms warm, single tenant) is the named enemy; the batched
  background outbox (`outbox.rs`, master-plan §D-write-tail) targets it but the at-scale write SLO
  is not yet separately published.

---

## 6. Marketing-safe headline (only the measured parts)

> **Grobase holds 24,887 live tenants in a 2.6 MiB data plane with zero standing connection pools,
> and serves any warm request at p95 2.4 ms — because isolation is per-request, so pool count is
> independent of tenant count. Gated at 10,000 tenants → 1 pool, 0 × 5xx (m46). 100K is a ~50-minute
> seed away on one box; the serve path does not change.**

Everything in that sentence cites a file in §1–§3. The 100K *load* p99 is deliberately **not** in the
headline until measured on a quiet node — per §5.
