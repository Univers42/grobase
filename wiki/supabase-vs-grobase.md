# Supabase vs Grobase — is our "Supabase-like" offer strong enough?

> A **focused, decision-grade** report answering one question: *if a developer or CTO is choosing
> between Supabase and Grobase's Supabase-like offer, are we strong enough — and what must we
> improve?* Every Grobase claim is **measured** and cites an in-repo artifact, gate, or in-stack
> control. **Every Supabase figure is *published* (June 2026) and sourced — never presented as a
> number we measured.** Where Supabase genuinely leads, this report says so plainly and gives the
> close-path. Companion docs: [`offer-vs-supabase.md`](./offer-vs-supabase.md) (plan-by-plan
> pricing), [`competitive-matrix.md`](./competitive-matrix.md) (91-row feature map),
> [`competitive-benchmark-report.md`](./competitive-benchmark-report.md) (head-to-head perf).

---

## 1. Executive verdict — **QUALIFIED YES**

**Our Supabase-like offer is strong enough to win on the axes we can measure, but not yet strong
enough to displace Supabase as a *managed, certified, polished hosted product* today.** Pick the
verdict by what the buyer optimizes for:

- **YES — for self-host, multi-engine, and dense multi-tenancy.** On the engineering substrate we
  beat Supabase on numbers, not adjectives.
- **QUALIFIED — for a turnkey hosted dashboard product.** Supabase's managed cloud, Studio polish,
  ecosystem, and third-party SOC 2 / HIPAA attestation are real leads we have not closed *as a
  hosted product*.

### The three load-bearing reasons it's a YES

1. **We are Supabase-shaped, then strictly more.** Grobase runs the same open core a Supabase user
   already knows — vendored `gotrue` (auth, `v2.188.1`), `postgrest` (auto REST), `kong`, `pg-meta`
   — so the mental model transfers, *and* we add a multi-engine Rust data plane (up to 9 engines,
   incl. bring-your-own-DB) and a Go control plane that packs thousands of tenants onto shared
   infrastructure. Supabase is Postgres-only, one project per backend.
2. **We beat Supabase on the measured substrate.** Same-box, same-probe head-to-head: **read p95
   2.20 ms (Grobase) vs 2.57 ms (Supabase self-host)** while our equivalent tier idles at **822 MiB
   vs Supabase's 2,884 MiB** across its 13 containers
   ([`artifacts/bench/grobase-vs-supabase.json`](../mini-baas-infra/artifacts/bench/grobase-vs-supabase.json)).
   At the low end our **nano edition idles at 2.0 MiB** — Supabase has no single-binary shape at all.
3. **Density is a structural moat Supabase cannot match in its architecture.** Per-request RLS lets
   one shared pool carry **24,888 live tenants at 2.918 MiB of data-plane RSS with 0 standing
   pools** ([`artifacts/scale/footprint-live-24888-today.json`](../mini-baas-infra/artifacts/scale/footprint-live-24888-today.json),
   collapse proven by gate `m46`). A Supabase project is one Postgres database per project — tenancy
   is your own design inside a single project. Our per-tenant holding cost is *flat*; theirs grows
   per project.

**Bottom line:** the *technology* is a win. The *productization of a hosted, certified offering*
(Track B7 + Track D) is where Supabase still leads, and that gap is honest and bridgeable.

---

## 2. Where Grobase wins (each with its artifact / gate)

| Win | Evidence (artifact / gate) | Reproduce |
|---|---|---|
| **Multi-engine + bring-your-own-DB** — one uniform API over up to **9 engines** (sqlite, postgresql, mysql, mariadb, mongodb, redis, cockroachdb, mssql, http); a tenant can mount their *existing* DB (`tenant_owned`). Supabase is **Postgres-only**. | `packages.json` `engines`; `data-plane-pool/src/{postgres,mysql,mongo,…}.rs`; engine-agnostic by construction | `make conformance` |
| **Dense multi-tenancy** — **24,888 live tenants @ 2.918 MiB data-plane RSS, 0 standing pools**; pool count independent of tenant count (per-request RLS, not pool-per-tenant). | [`artifacts/scale/footprint-live-24888-today.json`](../mini-baas-infra/artifacts/scale/footprint-live-24888-today.json); collapse proven by gate **m46** (2 tenants → 1 pool/engine under `SHARE_POOLS=1`, vs 2 under `=0`) | `SHARE_POOLS_PROBE=1 bash scripts/verify/m46-share-pools-isolation.sh` |
| **4 isolation models per mount** — shared_rls · schema-per-tenant · db-per-tenant · pool-per-tenant, chosen per mount. Supabase = 1 (one project = one DB). | gate **m46** | as above |
| **In-stack OWASP WAF** — ModSecurity v3 + OWASP CRS as the sole public listener. Supabase ships **none** in-stack. | `docker/services/waf`; per-plane network segmentation overlay `docker-compose.netseg.yml` | `make up` (waf plane) |
| **Footprint** — nano **2.008 MiB idle**, **4.9 MB binary**; cold start **6 ms**. Supabase has no comparable single-binary self-host floor. | [`artifacts/nano-vs-pocketbase.json`](../mini-baas-infra/artifacts/nano-vs-pocketbase.json), [`artifacts/nano-vs-pocketbase-load.json`](../mini-baas-infra/artifacts/nano-vs-pocketbase-load.json) | `make nano-up` + `scripts/bench/nano-one-pb-load.sh` |
| **Read p95** — **2.20 ms** vs Supabase self-host **2.57 ms** (same `GET /rest/v1/bench_items?limit=30` probe, n=60, same box). | [`artifacts/bench/grobase-vs-supabase.json`](../mini-baas-infra/artifacts/bench/grobase-vs-supabase.json) | `make bench-load` (vs-supabase harness) |
| **First-class ranked multi-column FTS** — `op=list + search:{query,columns,language}` → ranked `to_tsvector @@ websearch_to_tsquery` over concat'd columns, owner-scoped, a *typed first-class op*. Supabase's `textSearch` is a **single-column filter operator**. | gate **m101** (live through Kong: multi-column, ranked, language-aware) | `bash scripts/verify/m101-fulltext-search.sh` |
| **Typed vector k-NN** — `op=list + vector:{column,query,k,metric}` → `ORDER BY col <=>/<->/<#> $vec LIMIT k`, capability-gated. Supabase has pgvector but needs a **hand-written SQL RPC** to expose k-NN ergonomically. | gate **m102** (live vs a throwaway pgvector Postgres) | `bash scripts/verify/m102-vector-search.sh` |
| **Capability-typed SDK** — operations are typed by the mount's declared capabilities; the SDK reflects what an engine/tier can actually do. Supabase's client is Postgres-shaped only. | `apps/baas/sdk/` (`@mini-baas/js`, `src/{core,domains,generated}`) | `make` (sdk build/codegen) |

---

## 3. Where we're at parity

These are genuine table stakes Grobase matches — not wins, not gaps. Honest framing: Supabase's
implementations are often more *polished/managed*, but the capability is present and gate-proven.

| Capability | Grobase (gate / anchor) | Supabase | Parity note |
|---|---|---|---|
| **Relational CRUD** | `/data/v1/query` op = list/get/insert/update/delete/upsert (gate `m22`) | PostgREST auto-REST | Same PostgREST under the hood for PG; ours spans 9 engines |
| **RLS-equivalent owner-scope** | per-request owner-scoping + ABAC PDP, enforced per request not by pool state (gate `m46`, `m40`) | Postgres RLS policies | Different mechanism, equivalent guarantee; ours is what enables density |
| **Auth (API-key + JWT)** | scoped machine keys + JWT; gotrue `v2.188.1` vendored (gates `m40`–`m42`) | gotrue-based auth | Same engine; **see caveat below** for OAuth/MFA breadth |
| **OAuth / MFA** | **binocle-one** edition: 11 OAuth2-PKCE presets + any-OIDC + TOTP + recovery (gates `m41`/`m42`) | mature OAuth matrix + MFA in the default product | **Caveat:** our richest OAuth/OIDC/MFA lives in **binocle-one**, not the default multi-engine stack, and is **not yet in the `@mini-baas/js` SDK** |
| **Storage** | S3/MinIO/any-S3 buckets + presigned sign + on-the-fly image transforms (resize/webp/jpeg/png/avif) + per-bucket ABAC (gate `m95`) | built-in storage + managed CDN + transforms | Capability parity; theirs has managed CDN edge delivery |
| **Functions** | Deno runtime: deploy/list/invoke + DB-event triggers + per-fn secrets (AES-GCM) + warm pool + per-invoke mem-cap + live cron (gates `m56`/`m96`) | Edge Functions (Deno Deploy edge) | Capability parity; **theirs is globally edge-distributed, ours is single-node** |
| **GraphQL** | `pg_graphql` (same extension), RLS-isolation gate-proven (gate `m59`), opt-in glibc edition | `pg_graphql` default-on + GraphiQL Studio | Same extension; theirs is default-on with a hosted explorer |
| **Realtime** | WS/SSE subscribe + publish, Rust event bus + IRC bridge, owner-filtered delivery (gate `m44`) | Postgres CDC realtime | Capability parity; theirs is CDC-native on Postgres |

---

## 4. Where Supabase still leads (brutally honest) + the close-path

| Supabase lead | Why it's real | Close-path for Grobase |
|---|---|---|
| **Managed-cloud maturity** | Sign-up → project → API key → billed, all turnkey today. Grobase's cloud components (B1–B6: metering→quota→billing→self-serve→obs→backup) are **built and gate-proven but flag-OFF by default** (byte-parity with OSS). | **Track B7** — turn the flags ON in a hosted product (live Stripe + hosted deploy + signup funnel). Components exist; this is go-live, not net-new code. (ROADMAP, in progress — task #22.) |
| **Dashboard / Studio polish** | Full hosted Studio: table editor, SQL editor, logs, GraphiQL. Grobase ships the **binocle-one admin UI at `/_/`** + a tenant self-serve API — capable but not Studio-class. | Invest in a first-class hosted console (table/SQL/logs editor). Honest gap; partial today. |
| **Ecosystem & community size** | Large community, many integrations, tutorials, third-party libs, Stack Overflow gravity. Grobase is new. | Time + OSS adoption; lean on Supabase-compatibility (same open core ⇒ many Supabase guides transfer). Not a code fix. |
| **Global edge functions** | Edge Functions run on Deno Deploy's global edge network. Grobase functions are **single-node** (full Deno runtime, no invocation cap, data-resident). | ROADMAP: multi-region function distribution (Track C deepen). Today we trade global edge for *no invocation cap + data residency*. |
| **Formal SOC 2 / HIPAA as a hosted product** | Supabase Team buys SOC 2 + ISO 27001 (the *paper*); Enterprise adds a HIPAA BAA — third-party attested **today**. | Grobase ships **independently re-verifiable controls**: tamper-evident hash-chained audit (gate `m104`), continuous SOC2-lite evidence collector (gate `m108`), GDPR hard-erase/export (`m105`/`m109`), trust center (`m112`). **No third-party attestation yet** — that requires an audit engagement ($$, Track D4), not code. |
| **Richest OAuth/MFA in the *default* product** | Supabase's mature OAuth matrix + MFA + SAML are in the default hosted product. Grobase's richest OAuth/OIDC/MFA lives in **binocle-one** and **isn't surfaced in the JS SDK** yet. | Surface binocle-one's OAuth/OIDC/MFA in the default multi-engine stack + the `@mini-baas/js` SDK. Code path exists; it's plumbing + SDK codegen. |
| **Managed network controls / CDN front-door** | Cloudflare-fronted managed network + CDN. Grobase ships per-plane network segmentation + in-stack WAF (self-host), but no managed CDN. | Pair the in-stack WAF with a managed front-door in the hosted product (Track B7). |

---

## 5. Measured numbers table

> All Grobase numbers are **measured on this box** (20 vCPU / 31.9 GiB, kernel 6.17) per
> [`scripts/bench/METHOD.md`](../mini-baas-infra/scripts/bench/METHOD.md). Supabase figures are
> **measured for self-host on the same box** (the head-to-head artifact) or **published** where
> noted — never a measured number we attribute to their managed cloud.

| Metric | Grobase | Supabase | Source (artifact) | Reproduce (make target) |
|---|---|---|---|---|
| **Read p95** (warm, `GET /rest/v1/bench_items?limit=30`, n=60) | **2.20 ms** | 2.57 ms *(self-host, measured same box)* | [`artifacts/bench/grobase-vs-supabase.json`](../mini-baas-infra/artifacts/bench/grobase-vs-supabase.json) `.grobase_postgrest.read_p95_ms` / `.supabase.read_p95_ms` | `make bench-load` (vs-supabase) |
| **Read p50** (same probe) | **1.63 ms** | 1.51 ms *(self-host, measured)* | same artifact | same |
| **Idle footprint (RSS)** | essential **822 MiB** / nano **2.008 MiB** | **2,884 MiB** *(self-host, sum of 13 `supabase-*` container RSS, measured)* | [`artifacts/footprint-essential.json`](../mini-baas-infra/artifacts/footprint-essential.json) `.ram_mib_total`; [`artifacts/nano-vs-pocketbase.json`](../mini-baas-infra/artifacts/nano-vs-pocketbase.json) `.nano.rss`; grobase-vs-supabase `.supabase.total_rss_mib` | `make bench-footprint` |
| **Insert p95** (single row, c16) | nano **1.2 ms** / essential **9.09 ms** | *na* (head-to-head measured read latency only) | [`artifacts/nano-vs-pocketbase-load.json`](../mini-baas-infra/artifacts/nano-vs-pocketbase-load.json); [`artifacts/bench/load-essential-crud.json`](../mini-baas-infra/artifacts/bench/load-essential-crud.json) `.median.ops.insert.p95` | `make bench-load` |
| **Cold start** (boot → first 200) | nano **6 ms** | *na* (13-container stack; no single boot figure) | [`artifacts/nano-vs-pocketbase-load.json`](../mini-baas-infra/artifacts/nano-vs-pocketbase-load.json) `.boot_ms.nano` | `scripts/bench/nano-one-pb-load.sh` |
| **10K-tenant pool / RSS** | **24,888 tenants → 0 standing pools @ 2.918 MiB** data-plane RSS (at rest) | *na* (architecturally one project = one DB; not a per-tenant figure) | [`artifacts/scale/footprint-live-24888-today.json`](../mini-baas-infra/artifacts/scale/footprint-live-24888-today.json) `.data_plane_router_rust.{pools_open,rss_mib}`; collapse proof gate **m46** | `SHARE_POOLS_PROBE=1 bash scripts/verify/m46-share-pools-isolation.sh` |
| **Cost per tenant (modeled)** | nano ~$2.5/mo · essential ~$13 · pro ~$21 (<$1 amortized) | *na* (per-project + usage + MAU, not per-tenant) | [`cost-analysis.md`](./cost-analysis.md) §3(A) (modeled, formula stated) | — (model, not a bench) |

*Caveats (per [`compare-data.json`](../mini-baas-infra/scripts/bench/compare-data.json) `.meta.caveats`):*
the dev box is shared and the load generator runs on it, so high-rps tail latencies are
generator-CPU-bound, not stack latency — the at-density value is the **server-side facts**
(1 pool, ~3 MiB RSS, 0 evicted, 0 5xx), not the load-side p99. Supabase managed-cloud latency/cost
are **na** (not measured; their pricing is per-project/usage/MAU). Supabase **self-host** is the
contender we *did* measure on the same box.

---

## 6. Choose Grobase if / Choose Supabase if

**Choose Grobase if** you want to:
- **Self-host one backend for any frontend across up to 9 engines** — not just Postgres — or **bring
  your own existing database** (`tenant_owned`).
- **Pack thousands of tenants onto shared infrastructure at flat per-tenant cost** (24,888 tenants @
  ~3 MiB data plane, gate `m46`) — a SaaS where each customer is a tenant, not a separate project.
- **Start from a 5 MB / 2 MiB binary and grow to a 10K-tenant platform on one codebase, no rewrite.**
- Want an **in-stack OWASP WAF + per-plane network segmentation** as part of the stack you run.
- Need **ranked multi-column full-text search** or **typed vector k-NN** as first-class ops (gates
  `m101`/`m102`), and **data residency** (functions/storage never leave your infra, no invocation cap).
- Value **independently re-verifiable compliance controls** (tamper-evident audit, evidence
  collector) over a vendor's attestation paper — *and you can run your own audit*.

**Choose Supabase if** you want to:
- A **fully managed, turnkey hosted Postgres cloud today** — sign up, get a project, get billed, no
  ops. (Grobase's hosted product is Track B7, in progress.)
- A **polished hosted Studio** (table editor, SQL editor, logs, GraphiQL) out of the box.
- **Third-party SOC 2 / ISO 27001 / HIPAA attestation as a hosted product today** (Team/Enterprise),
  rather than self-verifiable controls.
- **Globally edge-distributed functions** (Deno Deploy edge) over single-node, data-resident functions.
- The **largest community + ecosystem** and the most third-party integrations/tutorials.
- Your workload is **Postgres-only forever** and you never need a second engine — then the multi-engine
  advantage doesn't apply to you.

---

## Honest residual (one line)

Our richest OAuth/OIDC/MFA story lives in the **binocle-one** edition, not the default multi-engine
stack, and is **not yet surfaced in the `@mini-baas/js` SDK** — closing that (plumbing + SDK codegen)
turns the "Auth breadth" row from a caveated parity into an unqualified one.
