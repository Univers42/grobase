# Grobase vs MongoDB Atlas — the honest offer comparison (2026)

> Companion docs: [offer-vs-supabase.md](./offer-vs-supabase.md) ·
> [grobase-vs-supabase-offer.md](./grobase-vs-supabase-offer.md) (footprint angle) ·
> [competitive-matrix.md](./competitive-matrix.md) · [reports/index.html](../reports/index.html) (HTML portal).
> Grobase numbers cite
> `config/packages/packages.json` or a `mini-baas-infra/artifacts/` benchmark.
> **Every Atlas number below is *published* (June 2026), not measured by us** —
> sources are listed at the bottom and never presented as a Grobase measurement.

## TL;DR

The honest frame first: **MongoDB Atlas used to be a Firebase-style BaaS.** Its
app-backend layer — *Atlas App Services* (formerly Realm): Data API, GraphQL API,
Device Sync, serverless Functions, Authentication/users, Static Hosting, Custom
HTTPS Endpoints, Edge Server — was **shut down. End of life: September 30, 2025.**
What survives is a managed *database*: MongoDB clusters plus Atlas Search
(full-text + vector), Atlas Charts, Stream Processing, and Database Triggers.

So a 2026 "BaaS vs Atlas" comparison is not BaaS vs BaaS — **it is Grobase
providing the app-backend layer Atlas retired.** And Grobase does it while
*speaking Mongo natively* (the `mongo` engine ships on the `pro` and `max` tiers)
and can wrap a customer's **existing Atlas cluster** as a `tenant_owned` BYO-DB
mount. You keep your Atlas database; Grobase puts the App-Services-shaped layer
(auth + functions + data API + realtime) back on top of it.

---

## The BaaS layer Atlas retired

Atlas App Services / Realm was the Firebase-equivalent application backend. It is
gone. Here is what each retired capability maps to in Grobase today:

| Capability | Atlas App Services | Grobase — how we provide it today |
|---|---|---|
| REST / Data API | **EOL 2025-09-30** (Data API deprecated) | Engine-agnostic data plane: `POST /data/v1/query` (op = list/get/insert/update/delete/upsert/aggregate), `POST /data/v1/txn`; PostgREST-shaped `/rest/v1` on the gotrue-compatible surface |
| GraphQL API | **EOL 2025-09-30** | GraphQL edition (A5, `docker-compose.graphql.yml`) — RLS-enforced; gate m59 |
| Auth / user management | **EOL 2025-09-30** | gotrue auth surface: `/auth/v1/signup`, `/token`, `/user`, MFA `/auth/v1/factors`; `binocle-one` edition adds OAuth2 matrix + admin UI at `/_/` |
| Serverless Functions | **EOL 2025-09-30** | Functions plane: `/functions/v1` deploy/list + `POST /functions/v1/{name}/invoke` (Deno runtime); `max` addon |
| Offline Device Sync (Realm SDKs) | **EOL 2025-09-30** | **Honest gap** — Grobase has no offline/conflict-merge mobile sync. We offer realtime push (below), not on-device replication. (See "Where Atlas wins".) |
| Realtime / change streams | partial (Triggers survive) | Realtime plane: `GET /realtime/v1/ws` (WS/SSE subscribe, topic filter), `POST /realtime/v1/publish`; Rust event bus + IRC bridge |
| Database Triggers | **survives** (the only piece left) | Functions + outbox/CDC relay + control-plane webhooks/scheduler |

Source for the EOL facts: the MongoDB Data API deprecation docs (see Sources).

> **Net:** of the App Services surface, MongoDB kept only Database Triggers. The
> Firebase-style app backend — Data API, GraphQL, Auth, Functions, Device Sync,
> Hosting — is retired. Grobase ships all of it except offline Device Sync.

---

## Database / offer ladder

Atlas now sells a **database**, priced by storage + compute/ops. Grobase sells a
**BaaS** priced by rps + capabilities + engines. They are not the same product,
so this table aligns on the closest comparable rung (price · storage · throughput
proxy). Atlas figures are *published* June 2026; Grobase figures cite
`packages.json` / `artifacts/`.

| Tier | Price (published / retail) | Storage | Throughput proxy | Notes |
|---|---|---|---|---|
| **Atlas M0** | **$0** | 512 MB shared | ~100 ops/sec | Free shared cluster, 32 MB sort memory |
| **Atlas Flex** | **$8–$30/mo** (base $8 + usage, capped $30) | 5 GB | 100 ops/sec → scales to 500 | GA Feb 2025; replaced Serverless + Shared |
| **Atlas M10** | **~$57/mo** | reserved | dedicated vCPU+RAM | Smallest dedicated; per-hour billed |
| **Atlas M30** | **~$400/mo** | reserved | dedicated | Mid dedicated |
| **Atlas M60** | **$1,500+/mo** | reserved | dedicated | Large dedicated |
| **Grobase nano** | Free / **$5** | SQLite, max_rows 1000, 100k q/mo | rps 50, burst 100 | 1 engine (sqlite), ~2.1 MiB RSS / 5.16 MB image |
| **Grobase essential** | **$25–39** | 2 mounts, max_rows 20000, 2M q/mo | rps 200, burst 400 | postgresql+sqlite; adds aggregate; ~822–949 MiB |
| **Grobase pro** | **$59–99** | 10 mounts, max_rows 50000, 10M q/mo | rps 400, burst 800 | **7 engines incl. mongodb**; batch+transactions+DDL; realtime+analytics; ~1.36 GiB |
| **Grobase max** | **$149–299** | 50 mounts, unlimited quota | rps 800, burst 1600 | 9 engines; every capability; +observability+functions+storage; ~3.1 GiB |

Atlas `ops/sec` and Grobase `rps` are *not* the same unit (a Mongo op vs an
engine-agnostic data-plane request) — read the table as ladder shape, not a
head-to-head throughput claim. Grobase rps is derived measured:
`floor(measured_ceiling × fair_share × 0.5)` from
`artifacts/bench/capacity-essential.json` (~400 rps single-pool read ceiling).

---

## Where Grobase wins

- **It is a BaaS in 2026.** Atlas App Services is EOL; Grobase *is* the app-backend
  layer (auth, functions, data API, GraphQL, realtime). That is the headline.
- **Multi-engine, not Mongo-only.** `pro`/`max` speak postgresql, sqlite, mysql,
  mariadb, **mongodb**, redis, cockroachdb (+ mssql, http on `max`) behind one API.
  Atlas is MongoDB, full stop.
- **Dense multi-tenancy.** Per-request RLS lets `SHARE_POOLS` collapse 10K+ tenants
  onto one pool — measured **24,887 tenants at 2.9 MiB data-plane RSS, 0 standing
  pools** (gate `m46-share-pools-isolation.sh`,
  `artifacts/scale/footprint-live-24888-today.json`). Atlas is one cluster per
  workload; isolation is per-cluster, billed per-cluster.
- **Single-binary floor.** `binocle-nano` is ~2.1 MiB idle / 5.16 MB image; the
  whole BaaS runs on a Pi or a $5 VPS. Atlas M0 is a shared *remote* cluster — no
  self-host, no single-binary story.
- **In-stack WAF / security by default.** ABAC PDP + RLS/owner-scope enforced per
  request, Vault-managed secrets, `security_mode: max` on the top tier.
- **BYO-DB wraps your Atlas cluster.** A `tenant_owned` mount points Grobase at an
  *existing* MongoDB/Atlas connection string. You keep Atlas as the database and
  regain the App-Services-shaped backend on top — no data migration required.

## Where Atlas wins (honest)

- **Best-in-class managed MongoDB at scale.** Sharding, global/multi-region
  clusters, automated failover, zone sharding — operational depth Grobase does not
  match for raw Mongo cluster management.
- **Atlas Vector Search maturity.** Production vector + full-text search is a first-
  class, mature Atlas product. Grobase has no equivalent managed vector tier.
- **Atlas Charts + Stream Processing.** Native dashboarding and streaming over Mongo
  data; Grobase analytics (Trino/Iceberg, opt-in) is a different, less Mongo-native
  approach.
- **The MongoDB ecosystem.** Drivers, Compass, Atlas CLI, decades of tooling,
  enterprise support contracts, and a vast hiring pool.
- **Deep operational maturity.** Atlas is a battle-tested global SaaS; Grobase's
  managed cloud (Track-B) is newer and self-host-first.
- **Offline Device Sync is genuinely gone *and* unmatched by us.** If you needed
  Realm's offline-first mobile sync, neither Atlas (retired it) nor Grobase offers
  it — that workload now needs a third-party sync layer regardless of vendor.

---

## Choose Atlas if … / Choose Grobase if …

**Choose MongoDB Atlas if:**
- You need a *managed MongoDB database* at serious scale (sharding, global
  clusters, automated ops) and you are fine wiring your own app backend.
- You depend on **Atlas Vector Search** or **Atlas Charts/Stream Processing**.
- You are deep in the MongoDB ecosystem and want first-party support.

**Choose Grobase if:**
- You actually wanted the **Firebase-style BaaS** Atlas App Services used to be —
  auth + data API + GraphQL + functions + realtime — which MongoDB **retired**.
- You want **more than Mongo**: one API over postgres/mysql/mongo/redis/+ engines.
- You want **dense multi-tenancy** (thousands of tenants per instance) or a
  **single-binary self-host** floor (nano on a $5 VPS).
- You want to **keep your Atlas cluster** but put a modern app backend back on it
  via a `tenant_owned` BYO-DB mount.

---

## Migrating off Atlas App Services / Realm

If your app was built on Atlas App Services (Data API, GraphQL, Auth, Functions)
and is now stranded by the 2025-09-30 EOL, Grobase is a direct landing spot:

- **Auth** → gotrue surface (`/auth/v1/*`, MFA) replaces App Services
  Authentication/user management.
- **Functions** → `/functions/v1` (Deno) replaces App Services Functions.
- **Data API / GraphQL** → `/data/v1/query` + `/data/v1/txn` and the GraphQL
  edition replace the retired Data API and GraphQL API.
- **Realtime** → `/realtime/v1/ws` + `/publish` replaces change-stream push
  (offline Device Sync remains a gap — see above).
- **Your data stays in Mongo** → register the existing Atlas cluster as a
  `tenant_owned` mongodb mount (`pro`/`max` tier). No re-platforming of the
  database; only the backend layer moves.

The one honest caveat: there is **no drop-in Device Sync replacement**. Apps that
relied on Realm's offline-first sync will need a separate sync strategy with any
2026 vendor.

---

## Sources

All competitor figures and EOL facts are **published as of June 2026**:

- Atlas App Services / Data API end-of-life (2025-09-30):
  <https://www.mongodb.com/docs/atlas/app-services/data-api/data-api-deprecation/>
- MongoDB Atlas pricing: <https://www.mongodb.com/pricing>
- Atlas Flex tier (GA Feb 2025, replaced Serverless + Shared):
  <https://www.mongodb.com/company/blog/product-release-announcements/dynamic-workloads-predictable-costs-mongodb-atlas-flex-tier>
- MongoDB pricing breakdown (M10/M30/M60, Flex caps):
  <https://www.cloudzero.com/blog/mongodb-pricing/>

Grobase figures: `config/packages/packages.json` (tier source of truth),
`mini-baas-infra/artifacts/scale/footprint-live-24888-today.json` (24,887-tenant
density), `artifacts/bench/capacity-essential.json` (rps derivation),
`artifacts/nano-vs-pocketbase.json` (nano footprint). See
[competitive-matrix.md](./competitive-matrix.md) and
[grobase-vs-supabase-offer.md](./grobase-vs-supabase-offer.md).
