# Grobase vs Supabase — the service-for-service offer

> Source: measured 2026-06-13 on one box (20 vCPU / 31.9 GiB), identical probe — `mini-baas-infra/scripts/bench/grobase-vs-supabase.sh` (Supabase pinned `v1.24.09`, booted on the big data disk with remapped ports so it runs alongside our stack). Companion: [competitive-matrix.md](./competitive-matrix.md), [marketability-readiness.md](../go-to-market/marketability-readiness.md).

**Thesis.** Self-hosted Supabase is a bundle of ~13 services — and most are the *same* OSS parts Grobase vendors (GoTrue, PostgREST, Studio, Kong, postgres-meta). Grobase delivers **the same feature surface on a leaner core** (Rust realtime + Rust data plane + Go control plane instead of Elixir/Node), **benchmarked lighter at read-latency parity** — and adds two things Supabase does not offer at all: **multi-engine** (bring-your-own-DB) and **dense multi-tenancy** (thousands of tenants per instance).

This doc keeps the comparison **like-for-like**: Supabase's full stack vs the Grobase services that deliver the same features — not vs our minimal `essential` tier.

---

## 1. Service-for-service map (measured RSS, same box, 2026-06-13)

| Supabase service | Supabase RSS | What it does | Grobase equivalent | Grobase RSS | Verdict |
|---|---:|---|---|---:|---|
| `supabase-db` | 214.5 | Postgres | `postgres` (same) | 103.9 | parity (ours leaner-tuned) |
| `supabase-auth` (GoTrue) | 8.3 | auth / JWT | `gotrue` (same OSS) | 7.8 | parity |
| `supabase-rest` (PostgREST) | 28.9 | auto REST | `postgrest` (same OSS) | 33.1 | parity |
| `supabase-realtime` (Elixir) | **268.7** | WS DB-change + broadcast | `realtime` (**Rust**) | **20.1** | **~13× lighter** |
| `supabase-storage` | 94.0 | object storage | `storage-router` (+`minio` 81.7) | 59.8 | parity — A1 added upload/download/list/buckets; **gap:** image transforms |
| `supabase-kong` | **1526** | API gateway | `kong` (same OSS) | **124.3** | **~12× lighter** (Supabase's kong is untuned/uncapped) |
| `supabase-meta` | 89.8 | schema introspection | `pg-meta` (same OSS) | ~90¹ | parity (same image) |
| `supabase-studio` | 66.5 | dashboard | `studio` (**vendored `supabase/studio`**) | ~66¹ | parity (literally the same image) |
| `supabase-edge-functions` (Deno) | 19.0 | serverless functions | `functions` (Deno) | 17.0 | parity (MVP; triggers/cron/secrets = roadmap A2) |
| `supabase-imgproxy` | 16.4 | on-the-fly image transforms | — | — | **gap** (planned) |
| `supabase-analytics` (Logflare/Elixir) | 274.2 | log analytics | `grafana`+`loki` (opt-in) | — | different/lighter approach; not in the parity shape |
| `supabase-vector` | 41.1 | log shipper | `promtail`/`otel-collector` (opt-in) | — | parity |
| `supabase-pooler` (Supavisor) | 202.2 | connection pooler | `supavisor` (same) **or share-pools** | — | share-pools makes a separate pooler optional |
| — | — | — | **+ `data-plane-router` (Rust)** | 2.5 | **multi-engine** — Supabase has none |
| — | — | — | **+ `tenant-control`+`adapter-registry` (Go)** | 9.4 | **dense multi-tenancy** — Supabase has none |
| **Total (full stack)** | **2884 MiB** | | **core parity shape** | **~448 MiB** | **~6.4× lighter** |

¹ pg-meta + studio are the **same OSS images** Supabase ships (not running in the lean shape above; counted at Supabase's own measured size since it's literally the same container).

**Where the weight is:** Supabase's footprint is dominated by **kong (1.5 GiB, untuned)**, **analytics/Logflare (274)**, **realtime/Elixir (269)**, and **pooler/Supavisor (202)** — i.e. ~2.27 GiB in four services. Grobase's parity shape replaces those with a **mem-tuned kong (124)**, **Rust realtime (20)**, **no Logflare by default** (grafana/loki opt-in), and **share-pools** (no separate pooler) — which is the whole ~6× difference.

---

## 2. Footprint — like-for-like

- **Grobase core functional parity** (`postgres + gotrue + postgrest + realtime + storage-router + minio + kong + functions`) = **~448 MiB**.
- **+ dashboard** (`studio + pg-meta`, the *same images* Supabase runs ≈ +156 MiB) ≈ **~600 MiB** for the complete Supabase feature surface incl. the console.
- **Self-hosted Supabase (full stack)** = **2884 MiB / 13 containers** (measured).
- → **Grobase is ~5–6× lighter for the same features.**
- **Grobase-only extras** (multi-engine data plane + multi-tenancy control plane) add only **~+12 MiB** — for capabilities Supabase cannot offer at any size.

---

## 3. Latency — parity (same PostgREST)

Identical N=60 curl probe, 500-row seeded `bench_items`, same box, both through Kong → PostgREST (two runs):

| | read p50 | read p95 |
|---|---:|---:|
| **Grobase** | 1.45–1.63 ms | 2.20–2.40 ms |
| Supabase | 1.51–1.58 ms | 2.57–2.66 ms |

Both run the **same PostgREST**, so this is — correctly — **parity** (they trade ±0.1–0.4 ms across runs, i.e. noise). We do **not** claim a latency win; the edge is footprint + multi-engine + multi-tenancy, not raw single-table read speed.

---

## 4. How to run the Supabase-parity shape

The Postgres-only, Supabase-equivalent shape is the existing **`pro`** package plus the functions + studio add-ons, **without** the multi-engine `engines` add-on:

```bash
make up PACKAGE=pro ADDONS="functions studio"
```

`pro` = `go rust adapter background data storage realtime` (Postgres + auth + REST + realtime + storage + the Go control plane + Rust data plane). The default `full` edition additionally starts 7 engines + analytics + Trino, which Supabase does **not** have — so compare against `pro`, not `full`.

---

## 5. Honest gaps to close for full parity

| Gap | Status | Roadmap |
|---|---|---|
| Image transforms (imgproxy equiv) | missing | storage follow-up |
| GraphQL (`pg_graphql`) | missing | A5 |
| Functions triggers / cron / secrets / CLI | MVP (HTTP invoke only) | A2 |
| Per-customer dashboard + logs (Logflare-style) | global-only obs | Track B (per-tenant obs) |

---

## 6. What Supabase does NOT offer (Grobase's edge)

- **Multi-engine / bring-your-own-DB** — MySQL, MongoDB, MSSQL, SQLite, Redis, HTTP (Supabase is Postgres-only).
- **Thousands of tenants on shared infra** — 10K tenants → 1 pool proven (gate m46); Supabase is one-project-per-backend.
- **In-stack OWASP WAF** (ModSecurity + CRS).
- **Single-binary editions** — nano 5.16 MB / binocle-one 6.41 MB.

---

## 7. Verdict

Grobase is a **drop-in-shaped, ~5–6× lighter** self-host alternative to Supabase at **read-latency parity**, built largely from the same OSS parts on a leaner Rust/Go core — the savings come from a tuned gateway, a Rust realtime engine (~13× lighter than Supabase's Elixir one), and not shipping a heavy analytics/pooler stack by default — **plus multi-engine + dense multi-tenancy on top**. Remaining parity gaps (image transforms, GraphQL, functions DX) are small and scoped in roadmap Track A.
