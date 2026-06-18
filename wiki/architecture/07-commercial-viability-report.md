# 07 — Capability & Commercial Viability Report

> An independent analysis of the **mini-baas** platform: what it can do today, whether
> the "agnostic BaaS that scales its power up or down with resources" vision is real,
> whether it is a viable commercial product, and what is missing to make a genuine
> difference in the market.
>
> Scope reviewed: `mini-baas-infra/` (TypeScript app plane, Go control plane, Rust data
> plane), the `sdk/`, the compose/edition orchestration, the security tooling, and the
> `wiki/` planning corpus (docs 00–06, product-plan 01–08).

---

## 0. Executive summary

**What it is:** a self-hosted, Docker-Compose-first *backend factory*. A frontend or
service treats it as a complete backend — auth, relational + document data, realtime,
object storage, email, a multi-tenant query plane, ABAC/RBAC, edge functions, webhooks —
over plain HTTP, with **no per-project server code**. It is built as three planes in three
languages chosen for their strengths: **TypeScript/NestJS** (business glue), **Go** (always-on
control daemons), **Rust** (hot-path engine pools).

**The headline judgement:**

> This is an **exceptional architecture and an impressive engineering demonstrator**, but it
> is **not yet a commercial product**. The single most important fact: almost every gap is a
> *missing implementation on a correct foundation*, not a design dead-end. The chassis is
> world-class; the engine is half-built.

**The "adaptive power" vision** — more power with more resources, an essential tier with
fewer resources, still secure — is **~40% real**:

- The **deployment-shape half works today.** Editions/planes let you stand up a lean stack
  (auth + relational REST only) or a full stack (federation, lakehouse, realtime,
  observability), with genuinely different resource footprints, and add/drop layers live.
- The **runtime-intelligence half does not exist yet.** "Power" is a deploy-time operator
  choice, not a per-tenant / per-project / per-query runtime context. There is no
  cost-driven router that sends a heavy analytical join to Trino and a point-read to the
  engine pool. That is the part that would make it *feel* like one adaptive product instead
  of two stacks behind one gateway.

**Commercial verdict:** viable as a **self-hosted / open-core** product on a 9–15 month
runway with a focused team, **not** viable as a managed SaaS today (no quotas, billing,
metering, HA, or horizontal scale). The differentiator that could "make a real difference"
is the **unified, cost-routed OLAP+OLTP query plane** — nobody mainstream ships that cleanly,
and the foundation here is already correctly shaped for it.

---

## 1. What the platform actually is (capability inventory)

### 1.1 The three-plane design

| Plane | Language | Owns | Why this language |
|---|---|---|---|
| **Application / business** | TypeScript (NestJS monorepo) | `query-router`, `mongo-api`, `storage-router`, `permission-engine`, `schema-service`, `outbox-relay`, `email`, `analytics`, `gdpr`, `newsletter`, `ai`, `log`, `session` | Velocity, expressive DTO/guard/interceptor model for fast-changing business rules |
| **Control** | Go | `adapter-registry` (AES-256-GCM credential vault), `tenant-control` (tenants, API keys, JWT bootstrap), `webhook-dispatcher` (Redis stream → HMAC delivery) | Tiny static binaries, fast cold start, fearless concurrency for always-up daemons |
| **Data** | Rust | `data-plane-router` (per-mount pools, query execution, transactions, ABAC), `realtime-agnostic` (WS fan-out) | Predictable latency, memory safety, long-lived pools the per-call TS adapters can't match |

The shared currency between planes is the **JWT secret** (HS256, GoTrue-issued, verified
everywhere) and **stable HTTP envelopes**. No plane reaches into another's database directly.
This is a clean, defensible boundary design and is rare in hobby/student projects.

### 1.2 The universal query lifecycle (the core value path)

```
Client → WAF (ModSecurity/OWASP CRS) → Kong (key-auth, CORS, rate-limit, correlation-id)
       → query-router (verify identity)
       → permission-engine (ABAC/RBAC decision, cached + circuit-broken)
       → adapter-registry (decrypt AES-256-GCM DSN, cached)
       → Rust data-plane-router (select engine adapter, reuse pool, parameterised op)
       → outbox event → Redis Streams → realtime publish + webhook (HMAC)
```

This path is wired and live. It is the right shape for an engine-agnostic BaaS.

### 1.3 Capability-driven engine abstraction (the best idea in the codebase)

Every engine advertises an `EngineCapabilities` descriptor (read/write/upsert/stream/ddl/
transactions/savepoints/isolation levels/2PC/idempotency/max-batch + a `cost` model:
`latency_class`, `pattern_search`, `joins`). Adding an engine is **one registration line**
(`AppState::new`) plus a pool impl — no call-site changes (Strategy pattern). The SDK is
**capability-typed**: `client.engine('redis').subscribe()` is a *compile-time* error because
Redis advertises `stream: false`.

This is genuinely strong architecture and is the correct foundation for both "agnostic" and
"OLAP/OLTP routing."

### 1.4 Layers = editions/planes (the adaptive-footprint mechanism)

| Edition | Planes | Footprint |
|---|---|---|
| `lean` | core | Auth + relational REST only — the smallest useful BaaS |
| `query` | core + data + go + rust + adapter + background | The flagship multi-tenant universal query product |
| `realtime` | `query` + realtime + storage | Adds WS fan-out and object storage |
| `analytics` | core + data + storage + analytics | Trino + Iceberg lakehouse federation |
| `prod` | `query` + storage + realtime + observability + ops | Production default |
| `full` | every plane | Demos / CI |

`make up EDITION=lean`, `make up-analytics`, `make down-analytics` — layers can be added and
dropped against a running core. **This is the part of the "adaptive power" vision that is real.**

---

## 2. Honest capability assessment (the hard evidence)

The project's own `06-product-assessment.md` is admirably candid; this report confirms and
sharpens it.

### 2.1 It is not yet full CRUD — and Postgres is the weakest

Actual operation dispatch in the Rust adapters:

| Engine | list | get | insert | update | delete | upsert | batch | aggregate/join |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| **postgresql** | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| mongodb | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| mysql | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| redis | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| http | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |

- **The flagship OLTP engine (Postgres) cannot UPDATE or DELETE** through the unified plane.
  This is a showstopper for a commercial release.
- **The capability descriptors over-promise.** Postgres advertises `write/upsert/transactions:
  true`; none of update/delete/upsert are implemented. The planner validates against the
  *advertised* caps, so it lets an `update` through to an adapter that then 501s. *Advertised ≠
  implemented* is a trust problem — and trust is the entire selling point of a backend.

### 2.2 "All operations, not just CRUD" — mostly aspirational

Present: `POST /v1/admin/raw` (admin-only native statements), `/v1/admin/migrate` (DDL),
`/v1/transactions*` (Postgres only, 30s TTL, no reaper). **Absent as first-class tenant ops:**
aggregations (count/sum/avg/group-by), joins/relationships, window functions, full-text/pattern
search, multi-column sort, cursor pagination, bulk ops, RPC/stored procedures. The rich `cost`
model that *should* power "beyond CRUD" routing is **defined and unused**.

For comparison: DreamFactory exposes filtering, relationships, aggregation, stored procedures,
and scriptable endpoints across 20+ connectors; Hasura/Supabase give relationships, aggregates,
RPC, realtime. This platform, at the *unified* API level, gives **partial single-table CRUD on
5 engines**.

### 2.3 OLAP/OLTP layer-switching — ~30% realized

- **Real (deploy-time):** the `query`/`prod` editions give a light, low-latency OLTP-leaning
  stack; the `analytics` edition gives a heavy Trino+Iceberg OLAP-leaning stack. Footprints
  genuinely differ; layers can be toggled live.
- **Missing (product-level):** no first-class "workload mode" context; Trino is a *separate*
  Kong `/sql` route, not folded into `/query/v1` or the SDK (the client must know which to
  call); no cost-driven routing; no automatic columnar/lakehouse tiering.

---

## 3. Security posture (the "still secure" requirement)

This is a relative strength and materially above hobby-grade.

**Strong:**
- Defense-in-depth edge: **WAF (nginx + ModSecurity + OWASP CRS)** in front of Kong (key-auth,
  CORS, rate-limit, correlation-id, security headers).
- **Auth depth:** GoTrue (JWT, MFA, OAuth), API keys with scopes, HMAC-signed identity envelopes
  (strict mode), Postgres **RLS**, ABAC + field masks.
- **Secrets:** HashiCorp Vault, AES-256-GCM credential vault in the Go adapter-registry, JWT
  rotation drill, secret-scanning artifacts (gitleaks, trufflehog, semgrep, trivy, ZAP baseline).
- **Supply chain:** pinned digests, `minimum-release-age` npm policy, image hardening with a
  scoped `.trivyignore`.

**Gaps that block "secure enough to sell as managed":**
- **Tenant isolation is hard-coded to shared-schema + RLS** (Postgres) / `owner_id` (Mongo).
  `schema_per_tenant` exists as a strategy but `db_per_tenant` (the one regulated customers
  demand) is not selectable per tenant. Isolation choice is the #1 enterprise procurement
  question.
- **No per-tenant rate limiting** (Kong limits per-IP), so one tenant can starve others.
- **No tenant-DSN credential-rotation drill** end-to-end (JWT rotates; tenant DB creds don't).
- **Secrets materialize to local `.env`** for dev convenience; the path to "Vault is the only
  source of truth" is documented but not enforced.
- ~~**A live `ANON_KEY` JWT is committed** in `.env` / `.env.local`.~~ **[Corrected 2026-06-13:**
  verified that `.env` / `.env.local` are gitignored and were **never git-tracked** (`git ls-files`
  empty; `git log --all -- '**/.env'` empty), and `ANON_KEY` is **runtime-generated** (HS256 from
  `JWT_SECRET` in `scripts/generate-env.sh`) — there is **no committed secret**. The real items are
  per-deployment keys + the RS256 issuer flip (see [roadmap-to-market.md](../go-to-market/roadmap-to-market.md) A6)
  and a blocking secret-scan CI gate so none is ever committed.**]**

**Net:** the security *architecture* is genuinely good. The *operational* security needed for
multi-tenant SaaS (isolation selection, per-tenant limits, rotation, zero committed secrets) is
not finished.

---

## 4. The "adaptive power" vision, scored precisely

> *"A BaaS agnostic that can adapt according to need — more power with more resources, the
> essential offer with less resources, still secure."*

| Dimension of the vision | Status | Evidence |
|---|---|---|
| Essential tier with small footprint | ✅ done | `lean` edition = core only |
| High-power tier with more resources | ✅ done (deploy-time) | `analytics`/`full` editions add Trino, Iceberg, MySQL |
| Add/remove layers live | ✅ done | `make up-analytics` / `make down-analytics` |
| Engine-agnostic data access | 🟡 partial | 5 engines, clean trait, **partial CRUD only** |
| Power as a **runtime** (per-tenant/query) choice | ❌ missing | OLAP/OLTP is a deploy choice, no workload context |
| Cost-driven routing (heavy→federation, light→pool) | ❌ missing | `cost` model defined but unused at routing time |
| Still secure across tiers | 🟡 partial | strong auth/WAF; isolation + per-tenant limits incomplete |

**Score: ~40% of the vision is real.** The hard, novel half (deployment-shape adaptivity) is
done; the product-feel half (runtime adaptivity) is the biggest net-new work — but it is
*buildable on the existing foundation without redesign*, because the capability/cost model and
pluggable planes are exactly the right primitives.

---

## 5. Commercial viability

### 5.1 Where it could win

- **Self-hosted / open-core** ("the engine-agnostic, multi-DB Supabase you run yourself").
  Self-hosting is a real, paying segment (data-residency, regulated industries, cost control).
- **The unique wedge:** a **single, cost-routed OLAP+OLTP query plane**. Supabase = Postgres-only;
  Hasura = GraphQL over a few SQL DBs; DreamFactory = broad connectors but no unified OLAP/OLTP
  intelligence. A clean "one API, point-reads hit the engine, analytics hit the lakehouse,
  automatically" is a story nobody mainstream tells well. **This is the differentiator worth
  betting the company on.**
- **The 3-language plane discipline** is a credible engineering-trust signal for enterprise buyers.

### 5.2 Where it cannot win yet

- **Not a managed SaaS.** No quotas, no usage metering, no billing hooks, `plan` is stored but
  unenforced, no per-tenant rate limits → you cannot safely run untrusted tenants or charge by usage.
- **No HA / horizontal scale.** Single-node Compose; no multi-node story, no per-tenant pool
  ceilings, no Helm/K8s (named as future work). Enterprises will not deploy a single-node backend.
- **Breadth is thin vs incumbents.** 5 engines (DreamFactory: 20+); no GraphQL (Hasura's whole
  pitch); admin UI is Postgres-only (Studio).
- **Trust/quality risk.** The project's own assessment notes the *entire gateway query path was
  404-broken* and the monorepo `tsc` was red until recently. A flagship path silently broken
  signals missing integration/e2e coverage and CI teeth — fatal for a "backend you rely on."

### 5.3 Market positioning

| Competitor | Their strength | This platform's relative position |
|---|---|---|
| **Supabase** | Postgres DX, realtime, studio, huge community | Behind on DX/polish; ahead on multi-engine intent |
| **Hasura** | Instant GraphQL, relationships, permissions | Behind (no GraphQL); different axis (REST + multi-engine) |
| **DreamFactory** | 20+ connectors, RBAC, scriptable endpoints | Behind on breadth/operations; ahead on plane architecture + OLAP intent |
| **Appwrite/Nhost/PocketBase** | Batteries-included, easy self-host | Behind on completeness/UX; ahead on architecture ambition |

The platform is **architecturally more ambitious** than most of these and **functionally behind
all of them**. That is the classic "great chassis, unfinished engine" position — promising, but
only if the operations gap is closed before the architecture novelty stops impressing buyers.

---

## 6. What it is lacking to "make a real difference" (prioritized)

### Tier 1 — without these it is not a product
1. **Finish the operations.** Full CRUD on every advertised engine (**Postgres update/delete/
   upsert first**), then aggregations, joins/relationships, search, multi-column sort, cursor
   pagination, bulk ops — wired to the `cost` model. *This is the product.*
2. **Make capabilities honest.** `/v1/capabilities` must report *implemented* ops; the planner
   must reflect reality so the SDK's compile-time typing is true. (Trust.)
3. **Real test pyramid + CI gates.** E2E through the gateway for every engine × operation; block
   merges on red. The 404/red-`tsc` incidents must become impossible.

### Tier 2 — the differentiator that "makes a real difference"
4. **Unified OLAP/OLTP query plane.** Fold Trino into `/query/v1` + the SDK; route by `cost`
   (joins/scans → federation, point ops → pools); make **OLAP vs OLTP a first-class, switchable
   runtime context** per tenant/project/query, not a deploy-time edition. Tier OLTP→Iceberg
   automatically. *This is the unique wedge — prioritize it the moment Tier 1 is stable.*

### Tier 3 — required to become a SaaS / enterprise product
5. **Tenant SaaS layer:** quotas, per-tenant rate limits, usage metering, plan enforcement,
   billing hooks.
6. **Selectable isolation per tenant:** `shared_rls` / `schema_per_tenant` / `db_per_tenant`.
7. **HA + scale:** Helm/K8s generated from the edition manifest, horizontal scaling, per-tenant
   pool ceilings, tenant-DB lifecycle (backups + credential rotation for *registered* DBs).

### Tier 4 — to compete on DX
8. **Complete the SDK** (functions, webhooks, transactions, admin/provision, the OLAP surface).
9. **Schema introspection / typed API** per registered DB.
10. **Optional GraphQL** (a direct differentiator vs Hasura).
11. **Admin UI** for the custom services (today Studio is Postgres-only). *Note: rather than
    build a dashboard builder from scratch, Appwrite/Budibase-style — Appsmith
    (`appsmith/appsmith-ce`) and Budibase (`budibase/budibase`) are themselves Docker images and
    could be composed in as the admin surface, with BaaS-specific widgets layered on top.*

---

## 7. Recommended sequencing (de-risked path to a sellable product)

```
Phase 1 (months 0–4) — "Make it true"
  • Postgres U/D/upsert + full CRUD parity on all engines
  • Capabilities report only implemented ops
  • E2E gateway tests per engine×op; CI blocks on red
  → Outcome: an honest, complete single-table multi-engine BaaS. Self-host alpha.

Phase 2 (months 4–9) — "Make it different"
  • Aggregations, joins, search, cursor pagination via the cost model
  • Unified OLAP/OLTP plane: Trino folded into /query/v1 + SDK, cost-routed
  • OLAP/OLTP as a runtime context
  → Outcome: the differentiator nobody else ships cleanly. Self-host GA / open-core launch.

Phase 3 (months 9–15) — "Make it a business"
  • Quotas, metering, per-tenant rate limits, billing hooks, plan enforcement
  • Selectable isolation (incl. db_per_tenant), tenant-DB lifecycle + rotation
  • Helm/K8s from the edition manifest, horizontal scale, pool ceilings
  → Outcome: managed-SaaS-ready. Enterprise/regulated segment reachable.
```

The ordering is deliberate: **honesty before novelty before monetization.** Shipping the
differentiator (Phase 2) on top of dishonest capabilities (Phase 1 unfinished) would burn the
exact trust the product needs.

---

## 8. Final verdict

- **As an architecture / platform skeleton:** genuinely strong, thoughtfully layered, and —
  uniquely — its layer/edition model already delivers the *deployment-shape* half of the
  adaptive OLAP/OLTP vision. This is well above "toy" and above most student/hobby work.
- **As a product a customer could rely on today:** **not yet.** The core promise — "any engine,
  all operations, OLAP *or* OLTP, still secure" — is only partially true: partial CRUD on 5
  engines, Postgres can't update/delete, "beyond CRUD" is an admin escape hatch, OLAP is a
  bolted-on endpoint, and the multi-tenant security operations are unfinished.
- **Commercial path:** **viable as self-hosted/open-core within ~9–15 months**; not viable as a
  managed SaaS until the Tier 3 work lands. The distance is **medium-large but on the right
  foundation** — implementation and integration, not redesign.

> **One-liner:** *A beautifully engineered chassis with the engine half-built. Finish the
> operations, make the capabilities honest, and turn OLAP/OLTP into a real runtime choice — and
> it becomes the genuinely differentiated, adaptive, agnostic BaaS the vision describes.*
