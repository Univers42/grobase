# Service Tiers & Resource Footprint

Pick the **right amount of back-end**, not the most expensive one. Every tier
below is a real, repeatable shape (`make up PACKAGE=<tier>`), and every number is
**measured live** (`make bench-footprint`, `docker stats`), not guessed. The
regression gate `make verify-m32` keeps each tier inside its budget.

> **What each tier *costs* (and what we'd charge) → [`cost-model.md`](./cost-model.md):** the
> auditable infra-cost-vs-price-vs-margin model — per-component RAM, the per-tenant density moat,
> hoster pricing, and per-tier worked examples on Fly/Hetzner/AWS, all cited to
> `config/cost-model.json` + bench artifacts (m145 gate).

## The four tiers (measured 2026-06-11)

| Tier | RAM (running) | Images | Services | Engines | Security | Best for |
|---|---|---|---|---|---|---|
| **basic** | **~380 MiB** | ~0.9 GB | 11 (0 Node) | SQLite, PostgreSQL | baseline | A private app on your machine / prototyping — Pi or $5 VPS |
| **essential** | **~660 MiB** | ~3.2 GB | 13 | pg/SQLite OLTP + the Go orchestrator (graph, masks, automations) — **no mongo/mysql containers** (outbox-relay runs mongo-optional) | baseline | A single small product with the full feature set, under 1 GB |
| **pro** | ~1.38 GB | ~5.6 GB | 28 | + MySQL/MariaDB/Mongo/Redis/CockroachDB, realtime, storage | baseline | A multi-engine SaaS with realtime + object storage |
| **max** | ~2.9 GB | ~11 GB | 41 | + MSSQL/HTTP, analytics (Trino/Iceberg), AI, functions, observability | **max** (TLS verify-full, audit, Vault-eligible) | A multi-tenant cloud platform |

Budgets enforced by `m32`: basic ≤512, essential ≤1024, pro ≤1500, max ≤3200 MiB.

`essential` was re-baselined post Node→Go orchestrator cutover (commit `4325a24`):
~950 MiB / 19 svc → **~660 MiB / 13 svc** (the 6 Node services retired for one
~9 MiB Go binary). The m32 budget ceiling is unchanged — essential ≤1024 MiB still holds.

### Why basic is so much smaller

The Rust data plane (`data-plane-router-rust`, ~10 MiB) + the Go control plane
(`adapter-registry` ~5 MiB, `tenant-control` ~8 MiB) are featherweight. `basic`
serves data through the **Rust `/data/v1` bypass** — Kong → Rust → engine — with
**no Node services** in the path (`PACKAGE_basic := go rust`). SQLite runs *inside*
the Rust process (0 MiB of its own). The weight in the higher tiers is the ~13
Node orchestration services (~55–110 MiB each) and the optional heavy engines
(Trino ~490, Debezium ~195) — which only start when a tier actually asks for them.

## The three deployment models

| Model | Tier | Notes |
|---|---|---|
| **Private / single-app (on your computer)** | `basic` | ≤512 MiB / 1 vCPU / ≤2 GB disk. SQLite-first, no cloud. The PocketBase-class shape. |
| **Mono-tenant cloud** | `basic`–`essential` | Add Kong TLS + a managed Postgres; one customer, your control. |
| **Multi-tenant cloud** | `pro`–`max` | Tiering enforcement, per-tenant rate limits, `SECURITY_MODE=max` (TLS verify-full, audit, Vault). |

## À-la-carte add-ons (modularize — don't over-buy)

Start lean, bolt on only what you need: `make up PACKAGE=basic ADDONS="realtime"`.

| Add-on | Plane | What it adds |
|---|---|---|
| `realtime` | realtime | Rust event bus + IRC bridge, WebSocket fan-out |
| `analytics` | analytics | Trino + Iceberg federated/analytical queries |
| `storage` | storage | MinIO/S3 object storage |
| `observability` | observability | Loki / Grafana / Prometheus |
| `functions` | functions | Serverless functions runtime |
| `engines` | engines-extra | MariaDB, CockroachDB, MSSQL |

The source of truth is `config/packages/packages.json` (engines allowlist +
capability mask + rate limits + max_mounts), mirrored into the Go control plane.

## What `basic` intentionally omits (honesty)

`basic` is the **data plane** — CRUD, owner-scoping, rate limits, the api-key scope
gate — served Node-free. It does **not** yet carry the Node-only orchestration
features: **graph queries, ABAC field-masking, server-side automations/webhooks,
realtime publish**. Those live in `essential`+ today; they are being ported to
Rust/Go (a gated, shadow→parity effort) so a future `basic` can opt into them.
Also: a *fresh* SQLite mount needs its table created out-of-band (the bypass
exposes data ops, not DDL — DDL-on-`/data/v1` is on the roadmap).

## How to choose & run

```bash
make packages                       # list tiers + the planes they include
make bench-footprint PACKAGE=basic  # measure a tier's real RAM/CPU/disk
make up PACKAGE=basic               # start the lean shape
make up PACKAGE=pro ADDONS="analytics engines"   # a tier + à-la-carte
make verify-m32                     # assert every tier fits its budget
make verify-m33                     # prove basic is Pi-class + Node-free + scope-gated
```

## Security posture

- **baseline** (basic/essential/pro): channel encryption where the DSN asks for it;
  realtime deny-by-default; api-key scope gate on the data path; constant-time
  internal service-token compare.
- **max** (`SECURITY_MODE=max`): TLS **verify-full** for every engine (MSSQL no
  longer trusts any cert; mongo/redis refuse cert-bypass DSN params), audit
  logging on mutations + denials, Vault-backed credentials eligible. See
  `wiki/SECURITY.md`.
