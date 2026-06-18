# Offer comparison — Grobase vs Supabase (2026)

> An **honest** plan-by-plan comparison for a developer or CTO choosing a backend. Grobase numbers
> are *measured* and cite [`config/packages/packages.json`](../../mini-baas-infra/config/packages/packages.json)
> (the single source of truth for tiers), [`cost-analysis.md`](../cost-and-tiers/cost-analysis.md) (retail), or a
> gate/artifact. **Every Supabase figure is *published* (as of June 2026) and sourced** — none is a
> measurement we ran. See also: [`competitive-matrix.md`](./competitive-matrix.md) (91-row feature
> map), [`competitive-benchmark-report.md`](./competitive-benchmark-report.md) (head-to-head perf),
> and [`offer-vs-mongodb-atlas.md`](./offer-vs-mongodb-atlas.md) (the third contender).

## TL;DR — who wins where

**Supabase** is the safer pick if you want a *managed* Postgres-native cloud with a polished Studio
dashboard, GraphQL on by default, a huge community, and SOC 2 / HIPAA available
**today**. (Vector + full-text search used to belong on this list — Grobase now matches it with typed
first-class ops; see below.) **Grobase** is the pick if you want to **self-host one backend for any frontend** across
**up to 9 engines** (not just Postgres), bring your *own* database (`tenant_owned`), pack **24,888
tenants into ~2.9 MiB of data-plane RAM** (measured — gate `m46`), ship a **5 MB single binary** at
the low end, and pay **< $1/tenant amortized** at the high end — with an **in-stack OWASP WAF** as the
sole public listener that neither rival ships. It also wins on axes Supabase is structurally weaker:
**per-tenant granular backup/restore** (restore one tenant in isolation — gates `m87`/`m99`),
**no-cap data-resident functions + storage** (full Deno runtime with warm pool/cron and S3 storage
*with* image transforms, no invocation/per-GB/egress ceiling — gates `m96`/`m95`), **auth breadth on
the same vendored gotrue engine** (passkeys + OIDC SSO + SCIM that Supabase paywalls — gates
`m107`/`m110`/`m111`), and **cryptographically re-verifiable compliance controls** (tamper-evident
audit + SOC2-lite evidence collector — gates `m104`/`m108`). Supabase is one Postgres project per app;
Grobase is a no-rewrite ladder from a 5 MB binary to a 10K-tenant platform on one codebase.

---

## How the offers line up

Supabase prices **per organization** (a Free org gets 2 projects; paid orgs add projects). Grobase
prices **per tier** (self-host infra cost → suggested retail). The mapping below pairs each Grobase
tier with its nearest Supabase plan by capability, not by exact feature identity.

| Grobase tier | Grobase price (retail¹) | Nearest Supabase plan | Supabase price (published²) | Why they pair |
|---|---|---|---|---|
| **nano** / **one** | Free / $5 (one: $5–9) | (no real equivalent) | — | Single 5 MB binary, embedded SQLite + auth. Supabase has no single-binary / self-host-floor shape. |
| **basic** | Free / $9 | **Supabase Free** | $0 / org | Lean CRUD backend; SQLite-first + Postgres. Maps to the entry experience. |
| **essential** | $25–39 | **Supabase Pro** | $25/mo / org (+$10 compute credit) | One full-feature product; both land at the ~$25 mark. |
| **pro** | $59–99 | **Supabase Pro → Team** | $25 → $599/mo | Multi-engine SaaS + realtime + analytics; spans Supabase's mid-to-team band. |
| **max** | $149–299 | **Supabase Team / Enterprise** | $599/mo → custom | Multi-tenant platform, every engine + capability, max-security, observability. |

¹ Grobase retail from [`cost-analysis.md`](../cost-and-tiers/cost-analysis.md) §"Suggested retail"; infra cost is the
floor (nano ~$2/mo or <$1 idle; essential ~$13; pro ~$21 dedicated / <$1 amortized; max ~$41 /
<$1 amortized). ² Supabase prices **published June 2026** — see [Sources](#sources).

---

## What you get per dollar

Grobase column cites `packages.json` / a gate / an artifact. Supabase column is **published June 2026**.

| Dimension | Grobase (measured / packages.json) | Supabase (published June 2026²) |
|---|---|---|
| **Entry price** | nano **Free / $5**; basic **Free / $9** | Free **$0/org** (2 projects, pauses ~1wk idle) |
| **Mid price** | essential **$25–39**; pro **$59–99** | Pro **$25/mo/org** (incl. $10 compute credit) |
| **Top price** | max **$149–299** | Team **$599/mo**; Enterprise **custom** |
| **Database engines** | **1 → 9**: sqlite, postgresql, mysql, mariadb, mongodb, redis, cockroachdb, mssql, http (`packages.json` `engines`) | **Postgres only** (1 engine per project) |
| **Storage included** | self-host: your disk; Fly volume $0.15/GB (`cost-analysis.md`) | Free 1 GB; Pro 100 GB |
| **Auth / MAU** | **same engine** (gotrue `v2.188.1` vendored) + passkeys/WebAuthn (gate `m107`), per-tenant OIDC SSO (`m110`), SCIM 2.0 (`m111`), OAuth2/PKCE+TOTP+recovery (`m41`/`m42`); unlimited self-host, **no MAU meter** | Free 50,000 MAU; Pro 100,000 MAU; **SSO/SCIM gated behind Team ($599)+**, no first-class passkeys |
| **Multi-tenancy** | **per-request RLS → SHARE_POOLS** packs 24,888 tenants @ 2.9 MiB / **0 standing pools** (gate `m46`, artifact below) | RLS *inside one Postgres project*; multi-tenant = your own design |
| **rps (per tenant)** | nano 50 · basic 100 · essential 200 · pro 400 · max 800 (`packages.json` `limits.rps`, derived from `bench-capacity`) | not a published per-plan rps; gated by compute size |
| **Isolation models** | **4 per mount** (shared_rls · schema-per-tenant · db-per-tenant · pool-per-tenant — gate `m46`) | 1 (one project = one DB) |
| **Realtime** | addon on pro/max (`packages.json` addons) — Rust event bus + IRC bridge | Free 200 concurrent / 2M msgs/mo; Pro scales up |
| **Functions** | full Deno runtime: deploy/invoke + DB-event triggers + secrets + **warm pool + per-invoke mem-cap + live cron** (gates `m56`/`m96`); self-host = **no invocation cap** | Free 500k edge-fn invocations/mo (**billing cap**); globally edge-distributed (Grobase is single-node) |
| **Object storage** | S3/MinIO/any-S3 + **on-the-fly image transforms** (resize/webp/jpeg/png/avif) + per-bucket ABAC (gate `m95`); self-host = **no per-GB / egress / storage cap** | Free 1 GB / Pro 100 GB built-in (**hard quota**); managed CDN edge delivery |
| **Backups / PITR** | **per-tenant** granular backup/restore (atomic Go-native COPY, restore one tenant in isolation — gate `m87`) + PITR restore-to-timestamp + tiered retention (gate `m99`); backups stay in your bucket | Pro daily backups + 7-day PITR; Team 14-day retention — **turnkey managed SLA, but whole-project only (no per-tenant restore)** |
| **Quota / metering** | per-tenant cumulative quota (`packages.json` `limits.quota`) + B1 metering (m74–m79) | per-plan included allowances + usage overage |
| **Compliance** | **independently re-verifiable controls**: tamper-evident hash-chained per-tenant audit log (gate `m104`) + continuous SOC2-lite evidence collector that reflects reality (gate `m108`) + GDPR hard-erase/export (`m105`/`m109`) + trust center (`m112`) + OWASP ASVS L1/L2 map; **no third-party SOC2/HIPAA attestation yet** | **SOC 2 + ISO 27001 on Team** (the *paper*); HIPAA BAA on Enterprise — third-party attested |
| **WAF** | **in-stack ModSecurity v3 + OWASP CRS** as sole public listener (`docker/services/waf`) | none in-stack |

---

## Where Grobase wins

- **Multi-engine + BYO-DB (`tenant_owned`).** Grobase serves **up to 9 engines** through one
  engine-agnostic data plane (`packages.json` `engines`: sqlite, postgresql, mysql, mariadb,
  mongodb, redis, cockroachdb, mssql, http) and lets a tenant **bring their own database**
  (`tenant_owned` mounts — [`migrate-from-supabase.md`](../guides/migrate-from-supabase.md),
  [`competitive-matrix.md`](./competitive-matrix.md)). Supabase is Postgres-only, one DB per project.
- **Dense multi-tenancy (the moat).** Per-request RLS means `SHARE_POOLS` collapses every tenant
  onto **one** connection pool. **Measured: 24,888 tenants at 2.918 MiB data-plane RSS with 0
  standing pools** (gate [`m46-share-pools-isolation.sh`](../../mini-baas-infra/scripts/verify/m46-share-pools-isolation.sh),
  artifact [`footprint-live-24888-today.json`](../../mini-baas-infra/artifacts/scale/footprint-live-24888-today.json)).
  Pool count is **independent of tenant count** — Supabase has no equivalent density story.
- **4 isolation models per mount.** shared_rls, schema-per-tenant, db-per-tenant, pool-per-tenant —
  pick per mount (gate `m46`). Supabase gives you one (project = DB).
- **In-stack OWASP WAF.** ModSecurity v3 + OWASP CRS (`owasp/modsecurity-crs:4-nginx`) is the
  **sole public listener**; the data plane is server-to-server behind Kong
  ([`security-audit-asvs.md`](../security/security-audit-asvs.md), `docker/services/waf/Dockerfile`).
  **Neither Supabase nor Firebase ships an in-stack WAF** ([`competitive-matrix.md`](./competitive-matrix.md) row D5).
- **Single-binary nano / one.** A **5.16 MB** image / **~2.1 MiB** idle headless backend (nano), or
  **~2.2 MiB** with accounts + OAuth + MFA + files + admin UI (`binocle-one`, *our PocketBase*) —
  measured ([`cost-analysis.md`](../cost-and-tiers/cost-analysis.md), [`nano-vs-pocketbase.md`](./nano-vs-pocketbase.md)).
  Supabase has no single-binary form.
- **No-rewrite grow path.** nano → basic → essential → pro → max is **one codebase, one SDK**, no
  rewrite (`packages.json` `_tenancy_guidance`). Supabase scaling means resizing a project's compute.
- **< $1/tenant amortized.** A single `pro` host (~$21/mo infra) across ~50 tenants ≈
  **$0.40–1.00/tenant/month**; marginal cost of tenant N+1 ≈ storage only ([`cost-analysis.md`](../cost-and-tiers/cost-analysis.md) §3).
- **Per-tenant granular backup/restore (Supabase can't).** Restore **one** tenant without rolling
  back the other 9,999 — atomic Go-native pgx COPY (`internal/backup/{extract,restore}.go`) + PITR
  restore-to-timestamp with tiered retention (gates [`m87`](../../mini-baas-infra/scripts/verify/m87-per-tenant-backup.sh)/[`m99`](../../mini-baas-infra/scripts/verify/m99-pitr-restore.sh)).
  Supabase backups are **whole-project only**, and they stay in your own bucket (data residency, no
  SaaS backup-storage/egress markup).
- **No-cap, data-resident functions + storage.** The full Deno functions runtime (warm pool +
  per-invoke memory cap + live cron, gate [`m96`](../../mini-baas-infra/scripts/verify/m96-functions-warm-cron.sh))
  and S3 object storage **with on-the-fly image transforms** (gate
  [`m95`](../../mini-baas-infra/scripts/verify/m95-storage-transforms.sh)) carry **no invocation cap,
  no per-GB/egress cap** on self-host — Supabase's 500k-invocations/mo and 1 GB/100 GB are billing
  ceilings. Code and bytes never leave your infra.
- **Auth breadth on the same engine.** gotrue is vendored verbatim (`supabase/gotrue:v2.188.1`) so
  email/OAuth/MFA are at maturity parity; Grobase then adds **passkeys/WebAuthn** (gate `m107`),
  **per-tenant OIDC SSO** (gate `m110`), and **SCIM 2.0** (gate `m111`) — all flag-OFF byte-parity.
  Supabase gates SSO/SCIM behind paid Team/Enterprise tiers and ships no first-class passkeys.
- **Cryptographically verifiable compliance controls.** A buyer can independently recompute the
  tamper-evident hash-chained per-tenant audit log (`hash=sha256(prev_hash‖canonical(row))`, gate
  [`m104`](../../mini-baas-infra/scripts/verify/m104-audit-chain.sh)) and the continuous SOC2-lite
  evidence collector reflects reality + detects DB tamper (gate
  [`m108`](../../mini-baas-infra/scripts/verify/m108-soc2-evidence.sh)) — controls you re-verify and run
  in your own datacenter, not a certificate issued for someone else's cloud. (The *paper*
  attestation is still Supabase's win — see below.)

## Where Supabase wins (honest)

- **Mature Postgres-native ecosystem.** Decade of Postgres tooling, extensions, and migration
  patterns out of the box; you get real Postgres, not an abstraction.
- **Studio dashboard polish.** Supabase Studio (table editor, SQL editor, logs, auth UI) is far more
  mature than Grobase's tenant console.
- **`pg_graphql` first-class GraphQL.** GraphQL is native, supported, and documented. Grobase runs the
  **same `pg_graphql` extension** (gate `m59` even proves two-tenant RLS isolation), but only as an
  **opt-in glibc edition** (the lean default 5xxs the route) and **Postgres only** — so on GraphQL
  *default availability* Supabase still leads.

  > **Vector + full-text search is no longer a Supabase win — Grobase now wins it.** Grobase exposes
  > both as **typed first-class data-plane ops**, owner-scoped and capability-gated: `op=list` +
  > `search:{query,columns,language}` → **ranked, multi-column** `to_tsvector @@ websearch_to_tsquery`
  > with `ts_rank` ordering (gate **m101**), and `op=list` + `vector:{column,query,k,metric}` →
  > **pgvector k-NN** (`<=>`/`<->`/`<#>` = cosine/l2/ip, gate **m102**); the default Postgres image is
  > now `pgvector/pgvector:pg16`. This is **more ergonomic than Supabase**, where FTS is a
  > single-column query-string filter and vector search needs a hand-written SQL RPC.
- **Managed-edge functions + turnkey backups.** Supabase Edge Functions deploy to Deno Deploy
  **edge regions worldwide**; Grobase functions are **single-node**. And Supabase runs daily
  backups + PITR as a **hands-off managed SLA** with contractual retention — Grobase's per-tenant
  backup + PITR are powerful but **flag-gated OFF and self-operated** (you run the WAL archiving,
  base backups, retention pruning, and restore drill), with no read replicas.
- **SAML 2.0 SSO + turnkey enterprise auth.** Grobase ships **OIDC** SSO + SCIM but **defers SAML
  2.0** (needs a mock SAML IdP + XML-dsig — task #33); a SAML-only IdP must wait. Supabase's SSO/SCIM
  are also **turnkey managed** (you don't operate them) with a polished Studio auth-management UI.
- **Large community + managed-cloud maturity.** Huge community, broad docs, third-party tutorials,
  and a battle-tested hosted platform with years of operational history.
- **SOC 2 + ISO 27001 (Team) and HIPAA (Enterprise) available today.** Grobase ships an OWASP ASVS /
  SOC2-lite *control map* ([`security-audit-asvs.md`](../security/security-audit-asvs.md)) but **no third-party
  attestation yet** — if you need a signed SOC 2 report or a HIPAA BAA now, Supabase has it.

---

## Choose Supabase if … / Choose Grobase if …

> **Choose Supabase if** you want a managed, Postgres-native cloud you don't operate; you need a
> polished dashboard; GraphQL-on-by-default matters; you need a **signed SOC 2 / ISO 27001 / HIPAA**
> attestation today; or your team is happiest in the Postgres ecosystem and one DB per app is fine.
> (Vector + full-text search no longer belong here — Grobase matches them with typed first-class ops,
> gates m101/m102.)

> **Choose Grobase if** you want to **self-host one backend for any frontend** across **many engines**
> (not just Postgres); you need to **bring your own database**; you're packing **many tenants into a
> tiny footprint** (24,888 @ 2.9 MiB measured); you want a **5 MB single binary** at the floor and a
> **no-rewrite path** to a platform; you want an **in-stack OWASP WAF** by default; you need
> **per-tenant granular backup/restore** (restore one tenant without touching the rest);
> **no-cap, data-resident functions + storage** (no invocation / per-GB / egress ceiling, code+bytes
> never leave your infra); **passkeys + OIDC SSO + SCIM** without a $599 paywall;
> **cryptographically re-verifiable** audit + compliance controls; or you need **< $1/tenant**
> economics and 4 isolation models per mount.

---

## Pricing reality (published June 2026)

All figures below are **published by Supabase** as of **June 2026** — not measured by us.

- **Free** — **$0 / org**: 2 projects, 500 MB DB, 5 GB egress, 50,000 MAU, 1 GB storage, 500k
  edge-function invocations/mo, 200 concurrent realtime, 2M realtime messages/mo. Projects **pause
  after ~1 week of inactivity**.
- **Pro** — **$25/mo per org**, *including a $10/mo compute credit*: 8 GB DB included, 100 GB storage,
  100,000 MAU, daily backups / optional 7-day PITR, email support. **Compute add-ons billed above the
  $10 credit**: Micro (covered by credit), **Small ~$15/mo**, **Medium ~$60/mo**, larger sizes scale
  up. So a busy Pro project is **$25 + compute** in practice, not a flat $25.
- **Team** — **$599/mo**: SOC 2 + ISO 27001, 14-day backup retention, priority support, dashboard SSO.
- **Enterprise** — **custom**: HIPAA, BYO-cloud, dedicated support, SLA.

For Grobase, retail is the *positioning* price; the *infra* floor is lower (nano <$1 idle, essential
~$13 dedicated, pro/max <$1/tenant amortized — [`cost-analysis.md`](../cost-and-tiers/cost-analysis.md)).

---

## Sources

Supabase figures are published as of **June 2026**:

- <https://supabase.com/pricing>
- <https://uibakery.io/blog/supabase-pricing>
- <https://www.metacto.com/blogs/the-true-cost-of-supabase-a-comprehensive-guide-to-pricing-integration-and-maintenance>

Grobase figures: [`config/packages/packages.json`](../../mini-baas-infra/config/packages/packages.json)
(tiers), [`cost-analysis.md`](../cost-and-tiers/cost-analysis.md) (retail + infra), gate
[`m46-share-pools-isolation.sh`](../../mini-baas-infra/scripts/verify/m46-share-pools-isolation.sh) +
artifact [`footprint-live-24888-today.json`](../../mini-baas-infra/artifacts/scale/footprint-live-24888-today.json)
(density), [`security-audit-asvs.md`](../security/security-audit-asvs.md) (WAF + compliance posture).

Related: [`competitive-matrix.md`](./competitive-matrix.md) · [`competitive-benchmark-report.md`](./competitive-benchmark-report.md) · [`offer-vs-mongodb-atlas.md`](./offer-vs-mongodb-atlas.md)
