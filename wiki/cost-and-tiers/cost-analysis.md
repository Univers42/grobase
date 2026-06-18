# Cost Analysis — What Each Tier Costs to Run (Fly.io)

Companion to [`service-tiers.md`](./service-tiers.md). That doc says *what* each tier is; this one
says *what it costs* — per tenant, per month, on Fly.io — and **what to cut next** to make it
cheaper. The PocketBase-class floor tier (`nano`, one binary, ~$2/mo) is specced in
[`nano-edition.md`](./nano-edition.md). Every RAM number is **measured live** (`make bench-footprint`,
`mini-baas-infra/artifacts/footprint-*.json`, 2026-06-11), not estimated. The Fly numbers are
derived from [Fly.io's published pricing](https://fly.io/docs/about/pricing/) (June 2026).

> **See also → [`cost-model.md`](./cost-model.md):** the canonical, multi-hoster, artifact-cited cost
> model (Fly + Hetzner + AWS, with the single source of truth at `config/cost-model.json` and the
> m145 gate). This doc is the older Fly-only narrative + the R1–R5 reduction roadmap; `cost-model.md`
> §5 supersedes its worked arithmetic.

> TL;DR — A private, full-CRUD back-end (`basic`) costs **~$6/mo** (under $2 if it scale-to-zeroes).
> The data path now runs in **3.3 MiB of Rust** where it used to take **127 MiB of Node** — **~38×
> lighter and 5× faster**. The biggest remaining win is folding the six Node `*-service`
> orchestrators into Go (~359 MiB → ~24 MiB), which would drop `essential` from ~$13 to ~$6.5/mo.

---

## 1. Measured footprint per tier

| Tier | Running RAM | Images | Services | Node svcs | Heavy engines |
|---|---|---|---|---|---|
| **nano** | **2.1 MiB** (1 static binary, MEASURED) | **5.16 MB** | **1** | **0** | SQLite in-process; CRUD+schema+graph+scoped keys+SSE — gated by `m37`, see [`nano-edition.md`](./nano-edition.md) |
| **one** | **2.2 MiB** (1 static binary, MEASURED) | **6.41 MB** | **1** | **0** | nano + accounts (password/OAuth2 matrix/OTP/TOTP MFA) + files + filtered realtime + admin dashboard — gated by `m40`–`m45`, see [`nano-vs-pocketbase.md`](../competitive/nano-vs-pocketbase.md) |
| **basic** | **463 MiB** | 0.9 GB | 11 | **0** | SQLite (in-process), PostgreSQL |
| **essential** | **949 MiB** | 2.9 GB | 19 | 8 | pg only (mongo runs optional/off) |
| **pro** | **1361 MiB** | 5.3 GB | 28 | 9 | + MySQL, Mongo, Redis, MinIO, realtime |
| **max** | **3128 MiB** | 11.1 GB | 41 | 11 | + CockroachDB, MSSQL, Trino, Debezium, MariaDB |

**Where the weight is** — this is the validation of the Rust/Go/TS three-plane design:

| Language | Examples (measured RAM) | Per-process |
|---|---|---|
| **Rust** | data-plane-router **3.3**, realtime 17.8 | 3–18 MiB — featherweight |
| **Go** | webhook-dispatcher 6.8, gotrue 11.8, adapter-registry 37.9, tenant-control 58.6 | 7–59 MiB — light |
| **Node** | query-router 62.7, permission-engine 64.7, log 83.9, outbox-relay 67.5, … | **46–84 MiB each** — the weight |
| **Engines** | mongo 130, mssql 204, debezium 201, trino 497, cockroach 733 | 130–733 MiB — optional, max-only |

Rust/Go processes are **5–20× lighter than the equivalent Node process**. The ~8 Node orchestration
services (~486 MiB combined in `essential`) and the JVM-based engines are what cost real money.

**On vCPU:** at idle, `docker stats` CPU% is noise; what you pay Fly for is *provisioned* vCPU. The
`cpus:` budget in compose sums to roughly **1 vCPU of real work** for basic/essential when idle —
these tiers are **RAM-bound, not CPU-bound**, until they take real traffic.

---

## 2. The Fly.io cost model

Fly bills running Machines per second by a CPU/RAM preset, plus storage and egress. Every shared-CPU
preset decomposes to the **same two unit rates** (verified across all four presets — e.g.
`shared-cpu-1x` 256 MB = $2.02 = 0.25 GB×$5 + 1 vCPU×$0.77; `shared-cpu-8x` 2 GB = $16.15):

> **Compute/month ≈ ($0.77 × shared vCPUs) + ($5.00 × GB of RAM)**

| Resource | Rate |
|---|---|
| Shared vCPU | **~$0.77 / vCPU / month** |
| RAM | **~$5.00 / GB / month** |
| Performance vCPU | ~$22 / vCPU / month (only the Trino/Cockroach-heavy `max` needs these) |
| Persistent volume | $0.15 / GB / month |
| Egress | $0.02 / GB (NA/EU) · $0.04 (APAC/SA) · $0.12 (Africa/India) |
| Dedicated IPv4 | $2 / month (optional — shared IPv4 and IPv6 are free) |
| **Scale-to-zero** | a stopped Machine bills only $0.15/GB rootfs — an idle `basic` is **< $2/mo** |

We model two deployment shapes because they cost very differently: **(A)** one dedicated stack per
tenant (private app / mono-tenant) and **(B)** a shared multi-tenant cloud.

---

## 3. Cost per tenant per month

### (A) Dedicated stack per tenant — private app / mono-tenant cloud

Provision = measured running RAM + headroom, rounded to a deployable VM. Region: NA/EU, shared CPU.
Volume/egress are conservative working assumptions (a small app's data + modest traffic).

| Tier | Provision | Compute | + Volume | + Egress | **All-in / tenant / mo** |
|---|---|---|---|---|---|
| **nano** | 1 vCPU · 256 MB | $2.02 | ~$0.30 (2 GB) | ~$0.20 | **≈ $2–3**  (< $1 idle, scale-to-zero) |
| **one** | 1 vCPU · 256 MB | $2.02 | ~$0.30 (2 GB) | ~$0.20 | **≈ $2–3**  (< $1 idle) — same VM class as nano; the app-backend features are binary weight, not RAM |
| **basic** | 1 vCPU · 1 GB | $5.77 | ~$0.45 (3 GB) | ~$0.50 | **≈ $6–7**  (< $2 idle) |
| **essential** | 2 vCPU · 2 GB | $11.54 | ~$0.75 (5 GB) | ~$1 | **≈ $12–14** |
| **pro** | 4 vCPU · 3 GB | $18.08 | ~$1.50 (10 GB) | ~$1.50 | **≈ $20–23** |
| **max** | 8 vCPU · 6 GB | $36.15 | ~$3.00 (20 GB) | ~$2 | **≈ $40–45** |

### (B) Shared multi-tenant cloud — the real SaaS economics

In a real multi-tenant deployment the control plane, data plane, and engine clusters are **shared**.
A new tenant adds only a schema/database plus a small slice of RAM, so:

> **Marginal cost of tenant N+1 ≈ storage only ($0.15/GB) + a few MiB of RAM.**

A single `pro` host (~$21/mo of infra) amortized across ~50 tenants ≈ **$0.40–1.00/tenant/month**.
The dedicated-stack table above is therefore the **worst case** (one tenant carrying a whole stack);
`pro`/`max` are meant to be sold per-seat or per-usage, where the margin lives.

### Suggested retail (cost is the floor, not the price)

Retail depends on positioning, support, and SLA — not just infra. A typical ~3× infra markup, or
amortized-multi-tenant economics for the upper tiers:

| Tier | Infra cost | Suggested retail | Why |
|---|---|---|---|
| **nano** | ~$2 (or < $1 idle) | **Free / $5** | headless single binary; landing pages, prototypes, machine-to-machine |
| **one** | ~$2 (or < $1 idle) | **$5–9** | *our PocketBase*: accounts + OAuth + MFA + files + admin UI on the same $2 VM — PB-class product, 26× lighter under load (see nano-vs-pocketbase.md) |
| **basic** | ~$6 (or < $2 idle) | **Free / $9** | lean microservice stack; SQLite-first, room to scale out |
| **essential** | ~$13 | **$25–39** | one full-feature product; ~3× markup |
| **pro** | ~$21 dedicated / < $1 amortized | **$59–99** | multi-engine SaaS; fat margin when multi-tenant |
| **max** | ~$41 dedicated / < $1 amortized | **$149–299** | enterprise/multi-tenant, max-security, analytics |

---

## 4. Old way vs new way

| | Old way (all-TypeScript, no tiers) | New way | Win |
|---|---|---|---|
| **Hot data path** | query-router 62.7 + permission-engine 64.7 = **127 MiB** of Node | data-plane-router-rust **3.3 MiB** (ABAC + field-masks in-process) | **~38× less RAM**, **5× faster** (8 ms vs 40 ms/req) |
| **Smallest deployable** | no Node-free path existed → full Node fleet ≈ **2.0 GB** | **basic 463 MiB** | **~4.3× less RAM**, **~$18 → ~$6/mo** |
| **Full-feature shape** | `essential` with the "kitchen-sink" data-plane profile ≈ **2066 MiB** | `essential` **949 MiB** | **2.2× less** (profile un-bucketing + mongo-optional) |
| **Images on disk** | every tier pulled Trino/Debezium even when unused | engines load only when a tier asks | `max` ~14 GB → 11 GB; lean tiers 0.9–2.9 GB |

The benchmark behind the data-path numbers is in [`cutover-status.md`](../archive/cutover-status.md): the
Rust `/data/v1` door is **8 ms/req vs the legacy 40 ms/req**.

---

## 5. What to do to reduce further

All additive and gated — the query-router stays as the fallback; **no TypeScript is deleted** until
live-traffic + parity + CI all PASS (per the project's cutover discipline).

**R1 — Retire query-router + permission-engine from the path (built, parity-proven, just gated).**
They are already replaced by the Rust `/data/v1` plane, proven row-identical by `make verify-m36`.
Routing `essential` through Rust drops **~127 MiB** (949 → ~822) and removes two Node images. The
only remaining step is the app flipping its base path `/query/v1` → `/data/v1`. Low risk.

**R2 — Consolidate the six Node `*-service` orchestrators into Go (the biggest win).**
email 46 + newsletter 52 + gdpr 57 + session 52 + log 84 + outbox-relay 67 = **~359 MiB** across six
Node processes, each paying a ~50–84 MiB V8/`node_modules` floor to do very little. Folded into one
or two Go services (compare webhook-dispatcher at **6.8 MiB**, gotrue 11.8) → **~24 MiB, ≈ 15× less.**
Result: `essential` ~822 → **~490 MiB — it fits the `basic` VM**, dropping its Fly bill from ~$12 to
**~$6.5/mo**. Ship one service at a time, shadow → parity.

**R3 — Node image + heap diet.** Each Node image is 252 MiB. A distroless/alpine base plus
`--max-old-space-size` heap caps shrinks images to ~80 MiB and trims RSS — lower disk and rootfs
cost, no behavior change. Applies to whatever Node survives R1+R2.

**R4 — Share engine clusters for multi-tenant.** `pro`/`max` RAM is dominated by engines (cockroach
733, trino 497, mssql 204, mongo 130). Run **one shared cluster** with schema/db-per-tenant (the
isolation models already support this) instead of per-tenant containers → per-tenant marginal RAM
≈ 0. This is what turns dedicated-`max` ($41) into amortized (< $1/tenant).

**R5 — (stretch) more Rust.** outbox-relay (67 MiB) and mongo-api (55 MiB) are the next candidates to
fold into the Rust data plane (it already emits the outbox CDC rows). Lower priority than R1–R4.

**Projected end-state after R1 + R2 + R3:**

| Tier | Now | After R1+R2 | Fly/mo (dedicated) |
|---|---|---|---|
| **basic** | 463 MiB | 463 MiB (already Node-free) | ~$6 → ~$6 |
| **essential** | 949 MiB | **~490 MiB** | $12–14 → **~$6.5** |

A full-feature back-end for one app: **~$18 (old) → ~$13 (now) → ~$6.5 (after Go consolidation)** —
with the data path staying 38× lighter and 5× faster than the original TypeScript.

---

## Reproduce these numbers

```bash
# RAM / image / disk per tier (writes artifacts/footprint-<tier>.json)
make bench-footprint PACKAGE=basic
make bench-footprint PACKAGE=essential
make bench-footprint PACKAGE=pro
make bench-footprint PACKAGE=max

make verify-m32        # assert every tier still fits its budget bar
```

Compute cost = `($0.77 × vCPUs) + ($5.00 × GB RAM)` + `$0.15/GB` volume + `$0.02/GB` egress (NA/EU).

**Sources:** [Fly.io pricing](https://fly.io/docs/about/pricing/) · live
`mini-baas-infra/artifacts/footprint-*.json` (`make bench-footprint`, 2026-06-11) · data-path
benchmark in [`cutover-status.md`](../archive/cutover-status.md).
