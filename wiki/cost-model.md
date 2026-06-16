# Cost Model — Re-derive Every Dollar

This is the **auditable** cost model for Grobase: what a node costs to run, what a tenant costs on
it, what we'd charge, and where the margin lives. It exists so a **skeptic can re-derive every
dollar** from a measured artifact or a dated price snapshot — no number here is invented.

- **Single source of truth:** [`config/cost-model.json`](../mini-baas-infra/config/cost-model.json)
  (v1, `as_of: 2026-06-15`). The wiki, the site cost simulator, and the cost-model gate all consume
  it. **Edit the JSON, not this prose** — this doc walks through what the JSON encodes.
- **Companions:** [`cost-analysis.md`](./cost-analysis.md) (the older Fly-only narrative — superseded
  by §5 here for the worked arithmetic), [`service-tiers.md`](./service-tiers.md) (*what* each tier
  is), [`pricing-honesty-audit.md`](./pricing-honesty-audit.md) (the offer-vs-reality audit §6
  reconciles against), [`nano-vs-pocketbase.md`](./nano-vs-pocketbase.md),
  [`scale-slo.md`](./scale-slo.md) (the density evidence behind §2).
- **As of:** 2026-06-15. **Cloud prices drift** — see the loud caveat in [§3](#3-hoster-pricing).

> **The three words that are NOT the same.** **COST** is what a node consumes (RAM floor + density +
> storage + egress). **PRICE** is what we charge. **MARGIN** is `price − cost`. And **human /
> support / on-call / SRE is none of these** — it is a separate operational line, never folded into
> infra cost or the per-tenant RAM math ([§6](#6-honesty-cost-vs-price-vs-margin)).

---

## 1. The cost basis — every dimension

Every line item that contributes to running cost, from `cost-model.json.cost_dimensions`. The
**driver** column is the load-bearing honesty flag: **measured** = there is a benchmark artifact;
**priced** = a hoster line-item rate (a dated snapshot, [§3](#3-hoster-pricing)); **note** = a
business/policy input with **no artifact** (do not treat as measured).

| # | Dimension | Unit | Driver | What it is / where it comes from |
|---|---|---|---|---|
| 1 | RAM — idle/baseline floor per edition | MiB | **measured** | Fixed per-node cost regardless of tenant count. nano 2.008 → max 3634 MiB. The dominant fixed cost on small tiers. Src `footprint-*.json` + `nano-vs-pocketbase.json` ([§2](#2-measured-inputs)). |
| 2 | RAM — per-tenant marginal **at rest** (the density moat) | MiB/tenant | **measured** | ~0.0001173 MiB/tenant (~0.12 KiB) @ `shared_rls`, `pools_open=0`. **Conditional:** holds only because `SHARE_POOLS` decouples pool count from tenant count. This is the *holding* cost, not the under-load cost. Src `footprint-live-24888-today.json`. |
| 3 | RAM — per-tenant working-set **under load** | MiB/active-tenant | **measured** | ~0.003 MiB per *concurrently-loaded* tenant (~30 MiB data plane for 10K zipf-concurrent, `server_errors=0`). A function of concurrent working set, not provisioned count — **the realistic packing constraint, not the at-rest moat.** Src `multitenant-10000.json` + m46. |
| 4 | vCPU — compute cores | vCPU | **priced** | Bench box = 20 vCPU. A single mount sustains ~400 read rps at p95<2 ms before the pool cliff. RAM dominates, so vCPU is the secondary priced input. Src `capacity-essential.json`. |
| 5 | Persistent block storage — Postgres data volume | GB-mo | **priced** | Per-tenant row/table data on the postgres volume. Only postgres **RSS** (43.99 MiB) is measured; the **on-disk GB-per-tenant** is **not in any artifact** → modeled via `factors.storage_gb_per_tenant_default` (**ESTIMATED**). |
| 6 | WAL + backup storage | GB-mo | **priced** | WAL retention + logical per-tenant backups (B6, `042_tenant_backups.sql`, pg-backup sidecar — periodic, no standing RSS). GB **not in any artifact** — fold into block storage or model separately; **ESTIMATED**. |
| 7 | Egress / network bandwidth | GB | **priced** | Outbound transfer to clients. **Not captured in any current artifact** → `factors.egress_gb_per_tenant_default` (**ESTIMATED**). This is where "cheap" clouds get expensive at scale (Fly $0.02, Railway $0.05, AWS $0.09; Hetzner bundles 20 TB). |
| 8 | Object storage — MinIO/S3 | GB-mo | **priced** | File uploads. MinIO **compute** RSS measured (74.4 MiB) but the **cost driver is GB stored**, not in artifacts. Separate $/GB-mo line from block storage. pro/max only. |
| 9 | Observability overhead | MiB | **measured** | loki 333.5 + trino 684.1 + debezium 248.1 + prometheus 33 + promtail 56.1 + grafana 47.7 MiB. pro/max/prod only — amortize across tenants. Largest non-DB block in max. Src `footprint-max.json`. |
| 10 | Realtime + functions runtime | MiB | **measured** | Realtime router 2.887 MiB RSS; functions-runtime mem_limit 256m, **state=DOWN at idle** (on-demand). Invocation/connection-driven — do **not** count the functions ceiling as steady-state. |
| 11 | Managed-Postgres HA premium | USD/mo | **priced** | Track-C SLA add-on (supavisor 512m + HA replica). **Not a base cost, NO Grobase artifact — ESTIMATED.** Honest comparator only: AWS RDS db.t3.medium single-AZ = $52.56/mo (~1.7× raw EC2). Not yet in the per-tier numbers ([§6](#6-honesty-cost-vs-price-vs-margin), open Q6). |
| 12 | Control-plane + gateway fixed overhead | MiB | **measured** | Go control plane (tenant-control 6.6 + adapter-registry 8.0 + orchestrator 8.8 + webhook-dispatcher 10.1 + function-scheduler 5.0 ≈ 38) + kong 102.4 + gotrue 7.9 + postgrest 12.0 MiB. Fixed per node, divided across all tenants. Src `footprint-live-24888-today.json`. |
| 13 | Reserved headroom / safety margin | fraction | **note** | Gap between measured RSS and mem_limit ceilings + burst capacity. `factors.headroom_pct=0.30`. Advertised rps = `floor(measured_ceiling × fair_share × 0.5)`. |
| 14 | **NON-INFRA — human / support / on-call / SRE** | USD/mo | **note** | **NOT a server resource. NO artifact. MUST NOT be folded into infra cost or the per-tenant RAM math** — bill as a separate operational line (support tier / SLA / on-call). Distinct from COST vs PRICE vs MARGIN. |

**Measured vs priced vs noted, at a glance:** dimensions **1, 2, 3, 9, 10, 12** are *measured*
(artifact-backed). Dimensions **4–8, 11** are *priced* (hoster rates — and where a per-tenant GB
default appears, **5/6/7/8** are also flagged **ESTIMATED** because no artifact measures GB-per-tenant
yet). Dimensions **13, 14** are *notes* (policy/business inputs). The honest distinction matters:
**only the measured rows are facts; the priced rows are dated snapshots; the noted rows are
assumptions.**

---

## 2. Measured inputs

### 2.1 Per-component RAM (each row cites its artifact + make target)

From `cost-model.json.components`. `basis_kind` = **measured** (a real RSS from `docker stats`) or
**mem_limit** (the compose ceiling budget, used only where no isolated RSS was captured — treat as a
*budget*, not a floor). Reproduce any row with the `make` target in its source string.

| Component | Plane | Basis (MiB) | Kind | Artifact · make target |
|---|---|---|---|---|
| data-plane-router (Rust) | data | **2.918** | measured | `footprint-live-24888-today.json` (RSS holding 24,888 tenants) · `make bench-footprint`; limit 96m |
| realtime (Rust) | realtime | 2.887 | measured | `footprint-live-24888-today.json` · `make bench-footprint EDITION=pro`; limit 128m (pro-load shows 19.6) |
| tenant-control (Go) | control | 6.562 | measured | `footprint-live-24888-today.json` · `make bench-footprint`; limit 160m |
| adapter-registry (Go) | control | 8.047 | measured | `footprint-live-24888-today.json` · `make bench-footprint`; limit 192m |
| orchestrator (Go) | control | 8.832 | measured | `footprint-live-24888-today.json` · `make bench-footprint`; limit 32m |
| webhook-dispatcher (Go) | control | 10.12 | measured | `footprint-live-24888-today.json` · `make bench-footprint`; limit 96m |
| function-scheduler (Go) | control | 5.004 | measured | `footprint-live-24888-today.json` · `make bench-footprint`; limit 96m |
| query-router (TS/Node) | app | 53.36 | measured | `footprint-live-24888-today.json` · `make bench-footprint`; limit 128m |
| permission-engine (TS/Node ABAC PDP) | app | 56.41 | measured | `footprint-live-24888-today.json` · `make bench-footprint`; limit 128m |
| storage-router (TS/Node) | storage | 54.64 | measured | `footprint-live-24888-today.json` · `make bench-footprint`; limit 128m |
| session-service (TS/Node) | app | 65.7 | measured | `footprint-essential.json` · `make bench-footprint PACKAGE=essential`; limit 128m |
| schema-service (TS/Node) | app | 128 | **mem_limit** | `docker-compose.yml` limit 128m (no isolated RSS; siblings measure ~57–70 — treat as ceiling) |
| email-service (TS/Node) | app | 57.8 | measured | `footprint-max.json` · `make bench-footprint PACKAGE=max`; limit 128m |
| newsletter-service (TS/Node) | app | 66.3 | measured | `footprint-essential.json` · `make bench-footprint PACKAGE=essential`; limit 128m |
| gdpr-service (TS/Node) | app | 65.1 | measured | `footprint-essential.json` · `make bench-footprint PACKAGE=essential`; limit 128m |
| log-service (TS/Node) | app | 69.7 | measured | `footprint-essential.json` · `make bench-footprint PACKAGE=essential`; limit 128m |
| outbox-relay (TS/Node CDC) | app | 67.1 | measured | `footprint-essential.json` · `make bench-footprint PACKAGE=essential`; limit 256m |
| analytics-service (TS/Node) | app | 65 | measured | `footprint-max.json` · `make bench-footprint PACKAGE=max`; limit 128m |
| ai-service (TS/Node) | app | 66.4 | measured | `footprint-max.json` · `make bench-footprint PACKAGE=max`; limit 256m |
| mongo-api (TS/Node) | app | 64.6 | measured | `footprint-pro.json` · `make bench-footprint PACKAGE=pro`; limit 128m |
| functions-runtime (TS/Node) | app | 256 | **mem_limit** | `docker-compose.yml` limit 256m (**state=down/0 MiB** in `footprint-max.json` — on-demand; do NOT count as steady-state) |
| kong (API gateway) | gateway | 102.4 | measured | `footprint-live-24888-today.json` · `make bench-footprint`; limit 1g (core 154.3, essential/pro 118.5 — varies) |
| postgrest (auto-REST) | gateway | 12.04 | measured | `footprint-live-24888-today.json` · `make bench-footprint`; limit 128m |
| waf (edge WAF) | gateway | 61.6 | measured | `footprint-essential.json` · `make bench-footprint PACKAGE=essential`; limit 256m (core cold 20.1) |
| gotrue (auth) | control | 7.891 | measured | `footprint-live-24888-today.json` · `make bench-footprint`; limit 128m |
| postgres (primary DB) | db | 43.99 | measured | `footprint-live-24888-today.json` (RSS holding 24,888 tenants `shared_rls`) · `make bench-footprint`; limit 512m |
| redis (cache/session) | db | 4.176 | measured | `footprint-live-24888-today.json` · `make bench-footprint`; limit 512m |
| mysql | db | 63 | measured | `footprint-pro.json` · `make bench-footprint PACKAGE=pro`; limit 384m |
| mongo | db | 91 | measured | `footprint-pro.json` · `make bench-footprint PACKAGE=pro`; limit 512m |
| mariadb | db | 8 | measured | `footprint-max.json` · `make bench-footprint PACKAGE=max`; limit 384m |
| mssql | db | 422.5 | measured | `footprint-max.json` · `make bench-footprint PACKAGE=max`; limit 2g |
| cockroach | db | 413.9 | measured | `footprint-max.json` · `make bench-footprint PACKAGE=max`; limit 1g |
| minio (object storage) | storage | 74.4 | measured | `footprint-pro.json` · `make bench-footprint PACKAGE=pro`; limit 512m (**cost driver is GB stored, not this RSS**) |
| trino (analytics / JVM) | observability | **684.1** | measured | `footprint-max.json` · `make bench-footprint PACKAGE=max`; limit 2g — **largest single component** |
| debezium (CDC / JVM) | observability | 248.1 | measured | `footprint-max.json` · `make bench-footprint PACKAGE=max`; limit 384m |
| iceberg-rest (catalog / JVM) | storage | 68.8 | measured | `footprint-max.json` · `make bench-footprint PACKAGE=max`; limit 384m |
| loki (logs) | observability | 333.5 | measured | `footprint-max.json` · `make bench-footprint PACKAGE=max`; limit 512m |
| prometheus (metrics) | observability | 33 | measured | `footprint-max.json` · `make bench-footprint PACKAGE=max`; limit 512m |
| promtail (log shipper) | observability | 56.1 | measured | `footprint-max.json` · `make bench-footprint PACKAGE=max`; limit 128m |
| grafana (dashboards) | observability | 47.7 | measured | `footprint-max.json` · `make bench-footprint PACKAGE=max`; limit 256m |
| supavisor (conn pooler) | db | 512 | **mem_limit** | `docker-compose.pooler.yml` limit 512m (C1 seam, not in base editions; Supabase's pooler measured 202.2 for ref) |
| pg-backup (logical backup) | db | 128 | **mem_limit** | `docker-compose.yml` limit 128m (periodic; no standing RSS) |
| studio (admin UI) | app | 384 | **mem_limit** | `docker-compose.yml` limit 384m (not in measured editions) |
| vault (secrets) | control | 256 | **mem_limit** | `docker-compose.yml` limit 256m (secrets profile; no standing RSS in edition footprints) |

### 2.2 Per-edition idle floor (the fixed per-node cost)

Each tier's `component_ram_sum_mib` is the measured idle floor — what a node pays before a single
tenant logs in. Each row cites the package-level footprint artifact.

| Tier | Idle floor (MiB) | Verdict bar | Artifact · make target |
|---|---|---|---|
| **nano** | **2.008** | (single binary) | `nano-vs-pocketbase.json` (`nano.rss=2.008`, image 4.9 MB) · `make nano-build` + footprint. vs PocketBase **13.11 MiB** RSS / 30.1 MB binary, same box. |
| **basic** | **309.8** | ≤512 (pass) | `footprint-basic.json` · `make bench-footprint PACKAGE=basic` |
| **essential** | **821.7** | ≤1024 (pass) | `footprint-essential.json` · `make bench-footprint PACKAGE=essential` |
| **pro** | **1188.4** | ≤1500 (pass) | `footprint-pro.json` · `make bench-footprint PACKAGE=pro` |
| **max** | **3634.0** | ≤3700 (pass) | `footprint-max.json` · `make bench-footprint PACKAGE=max` |

### 2.3 The density moat — per-tenant marginal RAM

This is the number the whole multi-tenant economics rests on (`cost-model.json.density`):

> **At rest: ~0.0001173 MiB/tenant (~0.12 KiB).** 24,888 tenants live in a **2.918 MiB** data plane
> with `pools_open=0`.
> Src: [`artifacts/scale/footprint-live-24888-today.json`](../mini-baas-infra/artifacts/scale/footprint-live-24888-today.json)
> (2026-06-15), reproducing `footprint-live-24887.json` (2026-06-14, 2.6 MiB / 24,887).

> **Under load (the realistic packing figure): ~0.003 MiB per concurrently-active tenant.** ~30 MiB
> data plane holds 10K zipf-concurrent tenants with `server_errors=0`.
> Src: [`artifacts/bench/multitenant-10000.json`](../mini-baas-infra/artifacts/bench/multitenant-10000.json)
> (gate **m46**).

This is **why** it works (and the cited evidence in [`scale-slo.md`](./scale-slo.md) §Evidence-B,
which records *"24,887 live tenants in a 2.6 MiB data plane with zero standing connection pools"*):
with `DATA_PLANE_SHARE_POOLS=1`, **pool count is independent of tenant count**, so per-tenant
marginal RAM collapses toward zero. Reproduce:

```bash
docker exec mini-baas-postgres psql -tAc 'select count(*) from public.tenants'
docker stats --no-stream data-plane-router
curl 127.0.0.1:4011/metrics | grep pool        # pools_open == 0 at rest
```

**Three caveats the model carries (`density.caveats`) — these are load-bearing:**

1. **At-rest ≠ under-load.** The 0.000117 moat is the *holding* cost. The realistic packing
   constraint is `per_tenant_underload_mib` (~0.003) **and** the rps fair-share ceiling — not the
   at-rest moat. The simulator defaults to the under-load + rps regime for honest tenants-per-node.
2. **`SHARE_POOLS` is an overlay, NOT the base default.** With it OFF (base compose), the same 10K
   zipf load thrashes the pool LRU → **62 server_errors / 12.4% err_pct**
   ([`multitenant-10000-nosharepools-today.json`](../mini-baas-infra/artifacts/bench/multitenant-10000-nosharepools-today.json)).
   The density economics **require** `DATA_PLANE_SHARE_POOLS=1` (scale overlay / m46). The base
   shape does not get the moat for free.
3. **Single box.** All RSS numbers are `docker stats` steady-state on one **20-vCPU / ~31,929 MiB /
   kernel-6.17** machine (`capacity-essential.json` env). A real cost model must re-measure on the
   target instance shape.

---

## 3. Hoster pricing

**Normalized unit prices, as of 2026-06-15.** From `cost-model.json.hosters`. Each cites its
`source_url` + `confidence`. **Hetzner / Fly / AWS are fully worked in [§5](#5-per-tier-worked-examples);**
the other three share the same formula and exist for the cross-hoster spread.

> ⚠️ **Prices drift — re-fetch before publishing.** Cloud pricing changes without notice. Hetzner
> raised prices 2026-04-01; Fly killed its free tier; AWS revises egress. These are **dated
> snapshots**, not contracts. Re-pull each `source_url` and bump `as_of` before any customer-facing
> use. The simulator surfaces `as_of` + a "prices drift, re-fetch" banner for this reason.

| Hoster | Representative plan | RAM·vCPU | $/GB RAM/mo | $/vCPU/mo | $/GB storage/mo | $/GB egress | Flat/mo | Confidence | Source |
|---|---|---|---|---|---|---|---|---|---|
| **Hetzner Cloud** | CX22 (cost-optimized) | 4 GB · 2 | **1.16** | 2.32 | **0** | **0** | 4.63 | published | [bitdoze](https://www.bitdoze.com/hetzner-cloud-cost-optimized-plans/) |
| Hostinger | KVM 2 (promo) | 8 GB · 2 | 1.12* | 4.5 | 0 | 0 | 8.99 | published | [smarthostfinder](https://smarthostfinder.com/hostinger-vps-pricing/) |
| **Fly.io** | shared-cpu-1x 1 GB | 1 GB · 1 | **5** | 2† | **0.15** | **0.02** | 5.92 | published | [fly.io/pricing](https://fly.io/docs/about/pricing/) |
| DigitalOcean | Basic Droplet 4 GB | 4 GB · 2 | 6 | 12 | 0.10 | 0.01‡ | 24 | published | [DO droplets](https://www.digitalocean.com/pricing/droplets) |
| Railway | usage-based units | 1 GB · 1 | 10 | 20 | 0.15 | 0.05 | 30 | published | [Railway pricing](https://docs.railway.com/reference/pricing) |
| **AWS (EC2/RDS ref)** | t3.medium, us-east-1 | 4 GB · 2 | **7.59** | 15.18 | **0.08** | **0.09** | 30.37 | published | [economize t3.medium](https://www.economize.cloud/resources/aws/pricing/ec2/t3.medium/) |

**Footnotes that change the arithmetic:**

- **Hetzner** `$/GB RAM` and `$/vCPU` are **flat-plan allocations** (no separate RAM/CPU SKU). CX22 =
  2 vCPU / 4 GB / 40 GB NVMe / 20 TB traffic @ €3.99 ≈ $4.63 flat. **storage + egress = 0** because
  bundled (40 GB disk + 20 TB; overage ~€1/TB). Larger CX nodes (8/16/32 GB) used for `max` are
  **DERIVED-linear** from this $/GB and flagged **estimated** in the worked examples.
- **Fly** RAM is a **true per-GB add-on** (~$5/GB/30d): 256 MB $2.02, 512 MB $3.32, 1 GB $5.92,
  2 GB $11.11. **†** `$/vCPU=$2` is **ESTIMATED** (Fly doesn't price shared vCPU separately).
  Volume $0.15/GB/mo + egress $0.02/GB NA-EU (no free allowance post-2025; $0.04 APAC/SA, $0.12
  Africa/India). For Fly, `node_monthly` is computed **per-GB** (`ram_gb*5 + vcpu*2`), not from the
  flat plan.
- **AWS** allocations are whole-instance. EBS gp3 $0.08/GB/mo; egress $0.09/GB first 10 TB (100 GB/mo
  free). Larger t3 nodes are **DERIVED-linear** and flagged estimated. Separate managed-DB
  comparator: **RDS db.t3.medium PostgreSQL single-AZ = $52.56/mo** (~1.7× raw EC2) — the honest
  "expensive managed Postgres" reference (open Q6).
- **\*Hostinger** $1.12/GB is the **PROMOTIONAL** (≤48-mo-commit) rate; renewal runs ~2× (~$2.2/GB,
  ESTIMATED). **‡DigitalOcean** egress $0.01/GiB is **overage only** after a pooled free allowance
  (≥1,000 GiB) — effective ≈ $0 for small workloads.

---

## 4. The formulas

Copied verbatim from `cost-model.json.formulas`, then a plain-English walk-through.

```text
node_ram_needed(N, tier) = component_ram_sum_mib(tier) + N * density.per_tenant_marginal_mib   // AT REST
  // Under concurrent load substitute per_tenant_underload_mib for the active fraction:
  //   component_ram_sum + (N * concurrency_peak_fraction) * per_tenant_underload_mib

tenants_per_node_ram(tier, hoster) =
  floor( (hoster.ram_gb*1024*(1-headroom_pct) - edition_ram_idle_mib) / per_tenant_marginal_mib )
  // the AT-REST moat ceiling — astronomically large (millions); NOT the realistic cap.

tenants_per_node_rps(tier) =
  floor( (rps_single_pool_ceiling / tier.rps) / concurrency_peak_fraction )
  // realistic cap from the measured 400-rps single-pool ceiling and a 10%-peak assumption.

tenants_per_node(tier, hoster) =
  min( tenants_per_node_rps(tier), tenants_per_node_ram(tier, hoster) )
  // then for `max` CAP at the PROVEN 10,000 (multitenant-10000.json / m46), not the RAM millions.
  // Single-tenant tiers (nano/basic/essential): dedicated model = 1; amortized uses this value.

node_monthly(hoster, ram_gb, vcpu) =
  flat_monthly_usd  if the representative flat plan fits the needed ram_gb,
  ELSE (ram_gb*usd_per_gb_ram_month + vcpu*usd_per_vcpu_month).
  // Fly is ALWAYS per-GB (ram_gb*5 + vcpu*2). Hetzner/AWS nodes larger than the representative
  // plan are DERIVED-linear from the representative $/GB and flagged estimated.

infra_cost_dedicated(tier, hoster) =
  node_monthly(node_ram_gb, vcpu)
  + storage_gb_per_tenant_default[tier]*usd_per_gb_storage_month
  + egress_gb_per_tenant_default[tier]*usd_per_gb_egress          // whole node = one app.

infra_cost_amortized(tier, hoster) =
  node_monthly(...) / tenants_per_node(tier, hoster)
  + storage_gb_per_tenant_default[tier]*usd_per_gb_storage_month
  + egress_gb_per_tenant_default[tier]*usd_per_gb_egress          // node split across tenants.

suggested_price(cost) = cost / (1 - default_margin_pct)   // 0.60 → price = cost*2.5
  // margin_pct = (price - cost)/price = 0.60.  Constraint: price > cost ALWAYS.
  // nano is the deliberate exception (free tier, margin 0).

// NON-INFRA: support/on-call/SRE is a SEPARATE operational line per tier, NEVER inside
// infra_cost_* or the per-tenant RAM math (no artifact backs it; it is a business input).
```

**Plain English:**

1. **How much RAM does a node need?** Start with the edition's measured idle floor, then add a tiny
   slice per tenant. *At rest* that slice is the 0.000117 MiB moat — negligible. *Under load* use the
   bigger 0.003 MiB working-set figure, but only for the fraction of tenants peaking at once
   (`concurrency_peak_fraction`).
2. **How many tenants fit on a node?** Two ceilings: a **RAM ceiling** (so high — millions — it never
   binds) and an **rps ceiling** (the real limit). The rps ceiling = how many tenants could
   *simultaneously* saturate the measured 400-rps single-pool wall (`400 / tier.rps`), scaled up by
   `1 / concurrency_peak_fraction` because not all tenants peak together. Take the **smaller**; for
   `max`, cap at the **proven 10,000** rather than the theoretical RAM millions.
3. **What does the node cost?** A flat plan if it fits, else `RAM×$/GB + vCPU×$/vCPU`. **Fly is
   always per-GB** because RAM is a real add-on there.
4. **What does a tenant cost?** *Dedicated* = the whole node is one app's bill (+ that tier's
   storage/egress). *Amortized* = the node cost split across the tenants packed on it (+ storage/egress).
5. **What do we charge?** `cost ÷ (1 − tier_margin)`, where margins are **tiered** (locked in
   2026-06-16): nano 0 (free) · basic 60% · essential 70% · pro 80% · max 85% (entry-low → premium-high,
   land-and-expand). **Price is always > cost** by construction — except nano, the deliberate free tier
   (margin 0). Headline per-tier dedicated cost-floor prices: basic **$2.90** · essential **$7.70** ·
   pro **$11.55** · max **$46.67** (Hetzner; real retail is value-based *above* this floor).
6. **Support/on-call is separate.** It is never in any of the above ([§6](#6-honesty-cost-vs-price-vs-margin)).

**The single biggest tunable is `concurrency_peak_fraction = 0.10`** (ESTIMATED — no artifact). It
linearly sets packing density (and thus every amortized cost): at 5% peak, `tenants_per_node` halves
and amortized cost doubles. A real value should come from production telemetry once the managed cloud
has traffic (open Q2).

---

## 5. Per-tier worked examples

The arithmetic from `cost-model.json.worked_examples`, on **Fly.io / Hetzner / AWS**. Defaults:
`headroom_pct=0.30`, `concurrency_peak_fraction=0.10`, `rps_single_pool_ceiling=400`. **Margins are
tiered** (locked in 2026-06-16): nano 0 · basic 60% · essential 70% · pro 80% · max 85% — the price
column below is `cost ÷ (1 − tier_margin)`. Per-tier storage/egress GB defaults are **ESTIMATED**
(`factors`): storage nano 0.1 → max 20 GB; egress nano 0.5 → max 50 GB.

`tenants_per_node_rps` per tier (= `(400 / rps) / 0.10`): **nano 80, basic 40, essential 20, pro 10**;
**max capped at the proven 10,000**.

### basic — single-tenant, idle floor 309.8 MiB, rps 100

| Model | Hoster | Arithmetic | Infra cost | Suggested price | Margin |
|---|---|---|---|---|---|
| **dedicated** | Hetzner | `node_ram_needed(1)=309.8` fits a 1 GB node (716.8 avail after 30% headroom). node $1.16; storage 0.5×$0 + egress 1.0×$0 = $0 (bundled). | **$1.16** | `1.16/0.40` = **$2.90** | 60% |
| **amortized(÷40)** | Fly.io | node(1 GB,1 vcpu) = `1*5+1*2` = $7.00; per-tenant share `7.00/40` = $0.175; + storage 0.5×$0.15 ($0.075) + egress 1.0×$0.02 ($0.02). | **$0.27** | `0.27/0.40` = **$0.68** | 60% |

### essential — single-tenant, idle floor 821.7 MiB, rps 200

| Model | Hoster | Arithmetic | Infra cost | Suggested price | Margin |
|---|---|---|---|---|---|
| **dedicated** | Hetzner | 821.7 MiB does **not** fit 1 GB (Fly 1 GB only 716.8 avail) → **2 GB** node. node $2.31 (derived-linear from $1.16/GB-equiv); storage/egress bundled = $0. | **$2.31** | `2.31/0.30` = **$7.70** | 70% |
| **amortized(÷20)** | AWS | node(2 GB t3-class) $15.19 (derived from t3.medium $30.37/4 GB); per-tenant share `15.19/20` = $0.760; + storage 1.0×$0.08 ($0.08) + egress 2.0×$0.09 ($0.18). | **$1.02** | `1.02/0.30` = **$3.40** | 70% |

### pro — amortizable SaaS, idle floor 1188.4 MiB, rps 400

| Model | Hoster | Arithmetic | Infra cost | Suggested price | Margin |
|---|---|---|---|---|---|
| **amortized(÷10)** | Hetzner | `tenants_per_node_rps = (400/400)/0.10 = 10`. floor 1188.4 → 2 GB node $2.31; per-tenant share `2.31/10` = $0.231; storage 5.0×$0 + egress 10.0×$0 = $0 (bundled). | **$0.231** | `0.231/0.20` = **$1.16** | 80% |
| **amortized(÷10)** | Fly.io | node(2 GB,1 vcpu) `2*5+1*2` = $12.00; per-tenant share `12.00/10` = $1.20; + storage 5.0×$0.15 ($0.75) + egress 10.0×$0.02 ($0.20). | **$2.15** | `2.15/0.20` = **$10.75** | 80% |

> **The pro `<$1/tenant` claim is hoster-dependent.** It holds on Hetzner ($0.231) but **flips on
> Fly ($2.15)** — and on AWS ($7.05) — because metered storage + egress dominate once RAM is nearly
> free. The simulator must surface this; do not advertise `<$1/tenant` without the hoster qualifier.

### max — multi-tenant platform, idle floor 3634 MiB, rps 800, **÷10,000 proven**

| Model | Hoster | Arithmetic | Infra cost / tenant | Suggested price | Margin |
|---|---|---|---|---|---|
| **multi-tenant(÷10000)** | Hetzner | floor 3634 → 8 GB node (5734.4 avail). PROVEN cap 10,000 (`multitenant-10000.json`, `server_errors=0`, SHARE_POOLS ON). node $7.00 (derived, **estimated**); per-tenant `7.00/10000` = $0.0007; storage 20×$0 + egress 50×$0 = $0 (bundled 20 TB). | **$0.0007** | (set by published tier rate) | enormous |
| **multi-tenant(÷10000)** | AWS | node(8 GB t3-class) $60.74 (derived-linear); per-tenant compute `60.74/10000` = $0.006; **+ storage 20×$0.08 ($1.60) + egress 50×$0.09 ($4.50)**. | **$6.106** | `6.106/0.15` = **$40.71** | 85% |
| **dedicated** (private max) | Fly.io | A customer renting a private stack: node(8 GB,4 vcpu) `8*5+4*2` = $48.00; + storage 20×$0.15 ($3.00) + egress 50×$0.02 ($1.00). | **$52.00** | `52.00/0.15` = **$346.67** | 85% |

> **The honest lesson at moat density.** On AWS the per-tenant compute is $0.006 but the floor is
> **$6.106 — dominated by egress ($4.50) + storage ($1.60), not RAM.** Contrast Hetzner's ~$0.0007
> (egress bundled). At the density the moat enables, *the cloud's egress/storage rates set the
> floor, not the RAM that makes us competitive.* These GB figures are ESTIMATED (open Q3) — they are
> load-bearing and need real per-tenant storage/egress measurement.

**Margin holds strictly positive on every tier × hoster row above** (the `price > cost` constraint),
with nano as the single intentional exception.

---

## 6. Honesty: cost vs price vs margin

**The legend, in order:**

- **Infra COST** = what a node consumes: `edition_ram_idle` (measured) + density (measured) + storage
  + egress (priced; per-tenant GB **estimated**). Dimensions 1–12 of [§1](#1-the-cost-basis--every-dimension).
- **PRICE** = what we charge = `cost / (1 − tier_margin)`.
- **MARGIN** = `(price − cost) / price`, **tiered** (locked in 2026-06-16): nano 0 · basic 60% ·
  essential 70% · pro 80% · max 85%. Real retail is value-based *above* this cost-justified floor.
- **NON-INFRA human / support / on-call / SRE** = dimension 14. **It is never in infra cost and
  never in the per-tenant RAM math.** No artifact backs it; it is a business input billed as a
  separate operational line (support tier / SLA / on-call rotation). If you see it folded into a
  per-tenant compute number anywhere, that is a bug.

**Dedicated vs amortized:**

- **Dedicated** = the whole node is attributed to one app. This is the realistic shape for the
  **single-tenant** tiers (nano / basic / essential), and for a customer renting a **private max**
  platform. `tenants_per_node` for these is **1**.
- **Amortized (multi-tenant)** = the node cost is split across the tenants packed on it. This is the
  real SaaS economics for **pro** and the headline for **max** (÷10,000 proven). The dedicated table
  is the **worst case** (one tenant carrying a whole stack); the margin lives in amortization.

### Reconcile with `packages.json` + `pricing-honesty-audit.md`

The cost model and the offer audit are consistent **except for one disclosed gap**, which this doc
does **not** paper over:

| Reconciliation point | Status |
|---|---|
| **nano = free tier** | **Consistent.** `packages.json` nano `_comment` = "the free-tier shape"; cost-model encodes price 0 / margin 0 by design. Amortized infra cost is $0.04–0.37/tenant/mo, treated as CAC (open Q8). |
| **pro `<$1/tenant`** | **Consistent but hoster-qualified.** True on Hetzner ($0.231); **false on Fly ($2.15) / AWS ($7.05)**. The cost model surfaces the flip; do not quote the claim unqualified ([§5](#5-per-tier-worked-examples)). |
| **max density / 10K tenants** | **Consistent — and conditional.** The ÷10,000 economics **require `DATA_PLANE_SHARE_POOLS=1`** (overlay, m46), which `pricing-honesty-audit.md` §5 confirms via m46 + `footprint-live-24887.json`. Base compose does **not** get the moat — 10K-zipf → 12.4% 5xx. |
| **max `rps: 800`** | **⚠️ GAP — disclosed, not papered over.** `pricing-honesty-audit.md` §3/§6 flags `max`'s **800 rps as PENDING** — *no measuring artifact*; `capacity-essential.json` tops out at **400**, and the 800 figure needs the B4 supavisor lift (parity-proven by m98, **not** capacity-proven). The cost model uses `rps_single_pool_ceiling = 400` (the measured ceiling) for **all** packing math, so **no cost number here depends on the unproven 800.** The 800 is a *tier advertisement* projection, not a cost input. Fix = run a pooler-overlay capacity bench → `artifacts/bench/capacity-max.json` with `max_sustained_rps ≥ 800` (audit FIX 1). |
| **max has no `quota` (unlimited)** | **Consistent.** Absent-quota = unlimited is a documented convention; abuse/spend handled by the spend-cap + abuse-guard layer (m89/m90/m120), not a quota. A hosted-product positioning note, not a false claim. |

**The older [`cost-analysis.md`](./cost-analysis.md)** (Fly-only, dated 2026-06-11) used a slightly
different decomposition (`$0.77/vCPU + $5/GB` and pre-Go-consolidation RAM like essential ~949 MiB).
That doc is **superseded by §5 here** for worked arithmetic — the canonical figures are the
2026-06-15 `footprint-live-24888` / package footprints encoded in `cost-model.json`. It is kept for
the cut-down history (R1–R5 reduction roadmap) and now carries a pointer here.

**Open questions ride on top of these numbers** (`cost-model.json`). **RESOLVED 2026-06-16 (this
lock-in):** **(Q1)** margins are now **tiered** — nano 0 · basic 60 · essential 70 · pro 80 · max 85
(`factors.margin_pct_by_tier`); **(Q2)** `concurrency_peak_fraction = 0.10` **adopted** as the
planning default (band 0.05–0.20; still the single biggest lever — revisit with production telemetry);
**(Q3)** per-tenant storage/egress GB defaults **adopted** (reasoned from `quota_rows`/`quota.requests`
at ~2–4 KB/row+response; still ESTIMATED — revisit per real workload). **Still open (need
infra/business input):** (Q4) ship `SHARE_POOLS` ON by default for hosted max? (Q5) re-fetch real
Hetzner/AWS larger-node SKUs (8 GB derived). (Q6) HA-Postgres premium not yet modeled. (Q7) Hostinger
promo vs renewal. (Q8) keep nano free (CAC).

---

## 7. How to reproduce

Every measured number comes from a `make bench-*` target run from `mini-baas-infra/`:

```bash
# Per-component + per-edition RAM (writes artifacts/footprint-<tier>.json) — §2.1, §2.2
make bench-footprint PACKAGE=basic
make bench-footprint PACKAGE=essential
make bench-footprint PACKAGE=pro
make bench-footprint PACKAGE=max
make bench-footprint EDITION=pro            # realtime under pro load

# The nano single-binary floor — §2.2 (nano-vs-pocketbase.json)
make nano-build                              # then footprint the static musl binary

# The rps ceiling behind every packing calc (400, not 800) — §3, §4
make bench-capacity PACKAGE=essential        # writes artifacts/bench/capacity-essential.json
make bench-load PACKAGE=essential WORKLOAD=crud

# The density moat (at-rest + under-load) — §2.3
#   at-rest: footprint-live-24888-today.json   (24,888 tenants @ 2.918 MiB, pools_open=0)
#   under-load: multitenant-10000.json (m46, SHARE_POOLS=1, server_errors=0)
docker exec mini-baas-postgres psql -tAc 'select count(*) from public.tenants'
docker stats --no-stream data-plane-router
curl 127.0.0.1:4011/metrics | grep pool

# RSS drift under sustained load / cold-start time (supporting)
make bench-mem PACKAGE=pro DURATION=30m
make bench-startup
```

**The cost-model gate (m145).** The cost model is validated by the milestone gate
`mini-baas-infra/scripts/verify/m145-*.sh` — it parses `config/cost-model.json` and asserts every
`mem_basis_mib` / `edition_ram_idle_mib` / density figure matches the cited artifact file (so a stale
number fails the gate rather than silently drifting), that every price carries a `source_url` +
`confidence`, and that `price > cost` on every non-free tier×hoster row. Run it directly, or via the
root wrapper:

```bash
bash mini-baas-infra/scripts/verify/m145-*.sh          # one gate, direct
make -C ../.. baas-verify-m145                          # via root Makefile
```

**To change the model:** edit
[`config/cost-model.json`](../mini-baas-infra/config/cost-model.json) (the single source — update a
price snapshot with its `source_url` + new `as_of`, or re-measure a footprint and update the
`mem_basis_mib` with the artifact path), then **re-run the m145 gate** to prove the JSON still
reconciles with its artifacts. The wiki, the site cost simulator, and the gate all read that one
file — never hand-edit dollar figures into this prose.

---

*Discipline: every dollar above traces to either a measured artifact (`artifacts/**`, reproduced by
a `make bench-*` target) or a dated, sourced price snapshot. Where a number is not measured
(per-tenant storage/egress GB, concurrency-peak fraction, larger-node SKUs, HA premium, support
line) it is explicitly flagged **ESTIMATED** / **note** — not asserted as fact. The single disclosed
offer gap (max 800 rps) is reconciled in [§6](#6-honesty-cost-vs-price-vs-margin), and no cost number
here depends on it. As of 2026-06-15 — prices drift; re-fetch and re-run the gate before publishing.*
