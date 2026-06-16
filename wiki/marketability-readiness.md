# Marketability Readiness Checklist

> **Source:** 6-agent code audit, 2026-06-13. Where older wiki docs (`product-plan/06`, `product-plan/07`) disagree, the code wins.

This is the checkable **"are we ready to market?"** gate. It is organized by the **four marketability bars** the owner selected as acceptance criteria. Each bar has a checklist of concrete, evidence-backed items; each item carries its current status, what is needed to pass, the track/phase that delivers it, and the gate/artifact that proves it.

This doc is the **gate**. For per-feature competitive detail see [`competitive-matrix.md`](competitive-matrix.md). For the delivery plan (Phase 0 + Tracks A/B/C) see [`roadmap-to-market.md`](roadmap-to-market.md).

## How to read this

**Status glyphs**

| Glyph | Meaning |
|-------|---------|
| `[v]` | Have it — shipped and gated (real, on by default or one flag away with proof) |
| `[~]` | Partial — built but off-by-default, incomplete, or stale/misadvertised |
| `[x]` | Missing — planned, not built |
| `[+]` | Differentiator — capability neither Supabase nor Firebase ships |

**Track/Phase legend** (full plan in [`roadmap-to-market.md`](roadmap-to-market.md)):

- **Phase 0** — days: author docs, run the vs-Supabase benchmark, security quick-wins, reconcile doc drift.
- **A1–A7** — Track A, OSS self-host launch (ships first).
- **B1–B6** — Track B, managed cloud (metering → enforce → bill).
- **C1–C4** — Track C, scale & HA for the cloud SLO.

**Launch dependency:**

- **OSS launch** needs **Bar 1** (table-stakes parity at `[v]`/`[~]` with a credible plan) **+ Bar 3 (subset)** (residuals closed, ASVS/SOC2-lite map, CI security gates). Bars 2 and 4 are *not* blocking for OSS.
- **Cloud launch** needs **all four bars** green.

---

## Bar 1 — Parity-matrix green

**Acceptance:** every table-stakes capability vs Supabase/Firebase is `[v]` or `[~]` with a credible plan; the five differentiators are marketed. Row-level competitive detail lives in [`competitive-matrix.md`](competitive-matrix.md).

| Item | Status | What is needed to pass | Track/Phase | Evidence/gate |
|------|--------|------------------------|-------------|---------------|
| Relational + NoSQL DB, CRUD/upsert, typed filters | `[v]` | Already at parity on PG/MySQL; Mongo parallel grammar | shipped | `data-plane-pool/src/{postgres,mysql,mongo}.rs`; m46 |
| Multi-engine / bring-your-own-DB | `[+]` | Market it; nobody else has it | shipped | `tenant_owned` in `isolation.rs`; 7 adapters |
| Dense multi-tenancy on shared infra | `[+]` | Market it; nobody else has it | shipped | gate **m46** (10K tenants → 1 pool) |
| Engine-agnostic uniform API | `[+]` | Market it | shipped | capability-honest planner, `capability.rs` |
| ACID transactions | `[~]` | Multi-statement txns PG+MySQL only; Mongo/SQLite/MSSQL `begin()`=NotImplemented; SDK `.transaction()` is a no-op wrapper | A3 | `operation.rs`; `sdk/src/domains` |
| Joins / relational queries (matrix #4, P1) | `[x]` | No join/relationship op as a tenant op — covered as an **A5 stretch** (joins/FTS/vector) | A5 (stretch) | gate **m59** (A5 stretch); `routes.rs` (no join op) |
| Native full-text search (matrix #6, P2) | `[x]` | No FTS op exposed — covered as an **A5 stretch** (joins/FTS/vector) | A5 (stretch) | gate **m59** (A5 stretch) |
| Vector / embeddings (pgvector) (matrix #7, P2) | `[x]` | No vector search; competitors both ship it — covered as an **A5 stretch** (joins/FTS/vector) | A5 (stretch) | gate **m59** (A5 stretch) |
| Schema migrations | `[v]` | DDL/migrate on PG/MySQL/Mongo/SQLite | shipped | `data-plane-pool` migrate paths |
| Read replicas / PITR / backups | `[~]` | Whole-cluster only; no per-tenant; restore-drill tested | C / B6 | gate **m47** |
| Auto REST over schema | `[v]` | PostgREST + multi-engine `/query`+`/data` | shipped | PostgREST; `routes.rs` |
| Auto **GraphQL** | `[x]` | "graphql" is planning-only, zero impl; Supabase has pg_graphql | A5 | grep: no impl |
| Fluent client query builder | `[~]` | REST builder is options-object, not `.eq/.in/.or/.single/.range` chaining | A3 | `sdk/src/domains/rest.ts` |
| Server Admin SDK | `[v]` | createClient/serviceRoleKey present | shipped | `sdk/src/index.ts` |
| **Capability-typed engine client** | `[+]` | Novel DX; market it | shipped | `engine<E>()` in SDK |
| Email/password, magic link, OTP (SDK-exposed) | `[v]` | gotrue email + magic link surfaced in the SDK | shipped | `control-plane/internal/tenants/jwt.go` |
| Social OAuth / OIDC | `[~]` | Built in **binocle-one** (OAuth2 PKCE, 11 presets + any-OIDC) but **not yet surfaced in the SDK** | A3 | binocle-one OAuth |
| Anonymous sign-in | `[~]` | Supported path but **not enabled by default** | A3 | gotrue config |
| MFA TOTP + recovery | `[~]` | Built in binocle-one; **not surfaced in the SDK** | A3 | binocle-one admin UI |
| SAML enterprise SSO | `[x]` | None | post-launch | — |
| Passkeys / WebAuthn | `[x]` | None | post-launch | — |
| Auth ↔ DB authz wiring (RLS-equiv) | `[v]` | GUC + owner predicate + ABAC + field masks | shipped | `isolation.rs` |
| Realtime DB-change subscriptions | `[~]` | WS+SSE works; PG CDC is **triggers+LISTEN/NOTIFY, not WAL**; Mongo native streams; client Rust-only | A5 | `realtime-db-postgres`, `realtime-db-mongodb` |
| Broadcast / pubsub channels | `[x]` | No first-class broadcast primitive | A5 | — |
| Presence (who is online) | `[x]` | None | A5 | — |
| Object/file storage | `[v]` | MinIO + storage-router, presigned, ABAC-gated | shipped | `src/apps/storage-router` |
| Storage **SDK DX** (upload/download/list/createBucket/signedUrl) | `[~]` | SDK exposes **only `presign()`**; README advertises `.bucket().signPut()` that **does not exist** (stale) | A1 | `sdk/src/domains/storage.ts` |
| Image transforms / resumable uploads | `[x]` | None | A1 | — |
| Serverless functions | `[~]` | Deno worker, HTTP-invoke only; in extras profile | A2 | `functions-runtime/src/server.ts` |
| Function **triggers / cron / secrets / CLI** | `[x]` | None of these; per-user not per-tenant; no warm pool, no cgroup caps | A2 | `functions-runtime/src/server.ts` |
| Managed push (FCM) | `[x]` | None (also a Supabase gap; Firebase win) | post-launch | — |
| **JS/TS SDK** | `[v]` | `@mini-baas/js`, Supabase-shaped | shipped | `sdk/src/index.ts` |
| Python / Dart / Swift / Kotlin / Go SDKs | `[x]` | JS-only; **OpenAPI spec dir is empty** (`.gitkeep` only) — blocks all codegen | A3→A4 | `mini-baas-infra/openapi/` (empty) |
| Offline persistence + auto-sync | `[x]` | None (Firebase clear win) | post-launch | — |
| Dashboard: table editor / SQL editor / user mgmt | `[~]` | Studio is **vendored Supabase Studio, not tenant-aware**, ip-restricted, unwired | B4 | `services/studio/Dockerfile` |
| Per-customer dashboard (tenant-facing) | `[x]` | None | B4 | — |
| **CLI** + local-dev parity + type-gen | `[x]` | No `baas` CLI, no emulator parity, no schema→types | A2/A3 | — |
| Webhooks / event delivery (matrix, P1) | `[~]` | SHIPPED (`sdk/src/domains/webhooks.ts` + webhook-dispatcher) but **admin-only / ip-restricted, no browser self-serve**; retry/backoff + HMAC story to document | A3 / B4 | `sdk/src/domains/webhooks.ts`; webhook-dispatcher |
| Email deliverability / prod SMTP (matrix, P1) | `[~]` | gotrue + Mailpit **dev-only**; **no prod SMTP wired** | A2/A6 | gotrue config; Mailpit |
| SMS OTP (matrix, P1) | `[~]` | OTP path exists but **no SMS provider wired** | A2 | gotrue config |
| Rate-limiting / DDoS / abuse protection (matrix, P1) | `[~]` | WAF CRS + per-tenant token bucket, multi-instance correctness proven | shipped | `services/waf`; gate **m51** |
| In-stack OWASP WAF | `[+]` | Market it; neither competitor ships one | shipped | `services/waf` (ModSecurity v3 + CRS) |
| Self-host (prod) | `[v]` | OSS, Compose-first, multi-arch on Docker Hub; tiny footprint | shipped | nano 5.16MB / essential ~660 MiB, 13 svc |

**Bar 1 read:** parity foundations are strong and three differentiators are already shippable. The red rows that gate a *credible* parity story are: storage DX (A1), functions DX (A2), SDK fluency + OpenAPI commit + multi-lang (A3/A4), GraphQL + realtime broadcast/presence (A5), and a tenant-facing dashboard (B4). For per-row Supabase/Firebase comparison and effort/priority, see [`competitive-matrix.md`](competitive-matrix.md).

---

## Bar 2 — Proven scale SLO

**Acceptance:** a published, load-tested target — tenants @ p50/p95/p99 + RPS + uptime — backed by a re-runnable harness. See [`grobase-master-plan.md`](grobase-master-plan.md) §7 and [`product-plan/09-100k-tenant-path.md`](product-plan/09-100k-tenant-path.md).

| Item | Status | What is needed to pass | Track/Phase | Evidence/gate |
|------|--------|------------------------|-------------|---------------|
| 10K tenants → 1 pool, 0× 5xx | `[v]` | Proven on all 7 engines | shipped | gate **m46** (`scripts/verify/m46-share-pools-isolation.sh`) |
| Share-pools / 100K lever | `[v]` | Pool count independent of tenant count, proven | shipped | gate **m46**; `pools_shared` in `data-plane-pool/src/lib.rs` |
| Read throughput / latency baseline | `[~]` | ~400 rps/pool, p95<2ms (m46 run notes). **vs-Supabase read latency MEASURED 2026-06-13** (same probe, both PostgREST, 500-row seeded): Grobase **p50 1.45 / p95 2.40 ms** vs Supabase **p50 1.58 / p95 2.66 ms** — parity (same PostgREST). RPS/p99 still TODO | Phase 0 ✓ | gate **m46**; vs-Supabase = **m54** |
| Data-path footprint advantage | `[v]` | 3.3 MiB Rust vs 127 MiB Node (~38×) | shipped | gate **m32** (`scripts/verify/m32-footprint.sh`) |
| **vs-Supabase benchmark RUN + published** | `[v]` | **RUN 2026-06-13.** Footprint **Supabase 2884 MiB / 13 containers** vs **like-for-like Grobase parity shape ~448 MiB** (~600 MiB w/ dashboard) → **~5–6× lighter**; read latency parity. Service-for-service map: [grobase-vs-supabase-offer.md](grobase-vs-supabase-offer.md). RPS + p99 still TODO | **Phase 0 ✓** | gate **m54** — `scripts/bench/grobase-vs-supabase.sh` |
| 100K-tenant run measured | `[~]` | **At-rest density measured beyond 10K**: **24,887 live tenants held by a 2.6 MiB data plane, 0 standing pools** (2026-06-14, `artifacts/scale/footprint-live-24887.json`). 100K *load* run still **projected** — needs a quiet/isolated node (this dev box is k6/Chrome-CPU-starved; only ~50-min Argon2id seed is the wall, a seed-time not serve-time cost). SLO doc: [`scale-slo.md`](scale-slo.md) | C4 | gate **m46** + live footprint; clean 100K-load = on-demand (quiet node), not CI |
| Horizontal data-plane scale-out | `[~]` | Multi-instance **rate-limit correctness is proven** (gate **m51**); only **throughput scale-out (~800 rps)** remains unmeasured (supavisor opt-in, not wired to Rust DP) | C1 | gate **m51** (multi-instance rate-limit); target ~800 rps |
| Production HA topology | `[~]` | Multi-instance rate-limiting proven (m51); single-node otherwise — **full HA topology unmeasured** (Helm chart is eval-only stub; HA = swap `DATABASE_URL` to managed PG) | C2/C3 | gate **m51**; `product-plan/07-scale-ha-helm-deployment.md` |
| Published uptime SLA target | `[x]` | No SLA / status page yet | Cloud GTM | — |

**Bar 2 read:** the *dense-tenancy* scale story is proven (m46) and now restated as a standalone SLO in [`scale-slo.md`](scale-slo.md) — with a **new larger at-rest measurement: 24,887 live tenants held by a 2.6 MiB data plane with zero standing pools** (2026-06-14), the purest form of the pool-count-⊥-tenant-count claim. The **vs-Supabase head-to-head is run** (2026-06-13): **~5–6× lighter** footprint (~448 MiB vs 2884 MiB), read latency at **parity**. What remains for a marketable cloud SLO is (1) write-throughput/RPS + p99, and (2) the measured 100K *load* run on a quiet node + horizontal/HA topology (Track C) — the 100K serve path is projected (RSS/pools/0-5xx don't grow with N); the only wall is the ~50-min Argon2id seed, fixed by a v1.1 batch-provision endpoint.

---

## Bar 3 — Security audit-ready

**Acceptance:** open residuals closed, controls mapped to OWASP ASVS / SOC2-lite, CI security gates active (cargo-audit, govulncheck, DAST, fuzz). Formal SOC2 is **explicitly deferred**. See [`security-audit.md`](security-audit.md).

| Item | Status | What is needed to pass | Track/Phase | Evidence/gate |
|------|--------|------------------------|-------------|---------------|
| In-stack OWASP WAF (sole public listener) | `[+]` | ModSecurity v3 + CRS | shipped | `services/waf` |
| TLS verify-full per-engine (SECURITY_MODE=max) | `[v]` | On at max | shipped | `security-audit.md` |
| RLS + ABAC + field masks + owner-scoped writes | `[v]` | All engines, parameterized SQL, constant-time compares | shipped | `isolation.rs` |
| Audit fixes (MSSQL MITM, HTTP SSRF, timing, Mongo NoSQLi, $or leak, bytea) | `[v]` | Already fixed | shipped | `security-audit.md` |
| Supply chain lockdown | `[v]` | npm 1-day quarantine, frozen lockfiles, Trivy/SEMGREP/gitleaks | shipped | CI config |
| Secret-scan CI gate (anon/service keys) | `[~]` | `.env` is gitignored + key is runtime-generated (no committed secret); add a **blocking gitleaks CI gate** so none ever is; move to per-deployment keys + RS256 (A6) | **Phase 0** + A6 | `scripts/generate-env.sh`, `.gitleaks.toml` |
| JWT RS256 issuer flipped | `[~]` | RS256/JWKS verify-ready but gotrue still signs HS256 | A6 | `internal/tenants/{jwt,jwks}.go` |
| Vault enforced (no plaintext DSNs) | `[~]` | Plaintext DSNs possible outside max mode | A6 | — |
| Plane network isolation / NetworkPolicy | `[x]` | Flat single bridge network | A6 / C2 | `docker-compose.yml` |
| Adapter-registry identity trust | `[x]` | Trusts `X-Baas-*` headers with no HMAC | A6 | adapter-registry |
| Read auditing | `[x]` | Reads not audited | A6 | — |
| Per-tenant resource QoS | `[x]` | No per-tenant CPU/RAM QoS | A6 / C | — |
| CI security gates (cargo-audit, govulncheck, DAST, fuzz) | `[x]` | Add all four to CI | A6 | CI config (new) |
| OWASP ASVS / SOC2-lite control map | `[x]` | Author the mapping | A6 | `security-audit.md` (extend) |
| Secret rotation primitive | `[x]` | No atomic key rotation | A6 | — |
| Formal SOC2 / HIPAA / ISO | `[x]` | **Deferred by decision** (Supabase has SOC2 Type2 + HIPAA add-on) | post-launch | N/A |

**Bar 3 read:** the *baseline* is strong (WAF, audit fixes, supply chain). The launch gate is **A6** — close the residuals and publish the ASVS/SOC2-lite map + CI gates. **Phase 0** adds the blocking secret-scan CI gate (the anon key is runtime-generated and `.env` is gitignored — there is no committed secret to purge; the earlier 07-report claim is corrected). Formal SOC2 is intentionally out of scope for launch.

> **OSS-launch subset of Bar 3:** secret-scan CI gate (Phase 0), RS256 issuer + per-deployment keys + Vault enforce + CI security gates + ASVS-lite map (A6). Plane isolation, per-tenant QoS, and read auditing can trail into the cloud track.

---

## Bar 4 — Live demo + signup (cloud only)

**Acceptance:** a stranger can sign up → get a project + API key → run CRUD/realtime → see usage → be billed (Stripe). This is the largest net-new build (Track B). See [`product-plan/06-saas-multitenancy-quotas-billing.md`](product-plan/06-saas-multitenancy-quotas-billing.md).

| Item | Status | What is needed to pass | Track/Phase | Evidence/gate |
|------|--------|------------------------|-------------|---------------|
| Tenant self-service signup → project | `[~]` | Only **one JWT self-bootstrap endpoint**; no project/plan/key UI | B4 | `internal/tenants` |
| Public admin/control API | `[~]` | `/admin/v1/*` **exists and is Kong-routed** (tenants/keys/webhooks/provision/migrate/rotate/meta/databases — tenant-control binds `0.0.0.0`, exercised live by m46) but is **service-role + internal-network only**; the genuine gap is **no tenant-facing self-service admin API/UI** (no signup/project/plan/key UI) | B4 | Kong `/admin/v1/*`; gate **m46** |
| API-key management (create/rotate) | `[~]` | Keys exist (160-bit sha256); **no atomic rotation**, no self-serve | B4 | `internal/tenants/keys.go` |
| Run CRUD/realtime as a new tenant | `[v]` | Data + realtime planes work once provisioned | shipped | m46; realtime crates |
| **Usage metering** (requests/rows/storage/realtime-min/fn-invokes) | `[x]` | **Zero `tenant_usage` code** — #1 managed-cloud gap | B1 | — |
| Quota enforcement on-by-default | `[~]` | Built (allowlist + mask + quota + rate-limit) but **`PACKAGE_ENFORCEMENT` defaults OFF**; no 402 | B2 | `internal/packages`; gate **m51** (rate-limit) |
| Billing (Stripe usage-based + plan catalog) | `[x]` | No Stripe, no entitlements, no self-serve upgrade | B3 | — |
| Tenant-facing dashboard | `[x]` | None (Studio is not tenant-aware) | B4 | `services/studio` |
| **Per-tenant observability** | `[x]` | Full stack wired but **global-only — no `tenant_id` label anywhere**; tenant can't see own logs/metrics | B5 | gate **m19** (global metrics) |
| Per-tenant backup/restore (self-service) | `[x]` | Whole-cluster only | B6 | gate **m47** |
| Organizations / teams / members / invites (matrix, P1) | `[x]` | ABAC per-principal exists but **no org/membership/invite model** | B4 | `isolation.rs` (per-principal only) |
| Data residency / region selection (matrix, P1) | `[x]` | No region selection | C3 | — |
| Tenant data teardown / erasure | `[~]` | Soft-delete only (no hard teardown) | B4/B6 | — |

**Bar 4 read:** this bar is mostly net-new. The runtime (CRUD/realtime) works, and quota machinery is built-but-off; everything else — metering, billing, the tenant dashboard, per-tenant observability and backup — is Track B. This bar **does not gate the OSS launch**.

---

## Go / No-Go summary

| Bar | % ready now | Blocking items | Gates which launch |
|-----|-------------|----------------|--------------------|
| **1 — Parity-matrix green** | ~60% | Storage DX (A1), functions DX (A2), SDK fluency+OpenAPI commit+multi-lang (A3/A4), GraphQL+broadcast/presence (A5), tenant dashboard (B4) | **OSS** (table-stakes subset) + **Cloud** |
| **2 — Proven scale SLO** | ~60% | vs-Supabase RUN — footprint + read latency (Phase 0 ✓); still need write-RPS/p99, measured 100K run (C4), horizontal scale-out + HA (C1–C3) | **Cloud** |
| **3 — Security audit-ready** | ~60% | Secret-scan CI gate (Phase 0); RS256 issuer + per-deployment keys, Vault enforce, CI sec-gates, ASVS-lite map (A6); plane isolation, header HMAC, read audit, per-tenant QoS (A6/C) | **OSS** (subset: Phase 0 + A6) + **Cloud** (full) |
| **4 — Live demo + signup** | ~15% | Metering (B1), enforcement-on (B2), Stripe billing (B3), tenant self-service + dashboard (B4), per-tenant observability (B5), per-tenant backup (B6) | **Cloud** only |

### Launch gates

| Launch | Required bars | Net status | Critical path |
|--------|---------------|-----------|---------------|
| **OSS self-host** (ships first) | **Bar 1** (table-stakes at `[v]`/`[~]` + credible plan) **+ Bar 3 (subset)** | **Not yet** — needs A1, A2, A3 and A6; Phase-0 secret-scan CI gate is a quick pre-req | Phase 0 → A1 → A2 → A3 → A6 → A7 |
| **Managed cloud** | **All four bars** | **Not yet** — Bar 4 (~15%) is the long pole; also needs Bar 2 measured 100K + HA | OSS launch → B1→B2→B3→B4→B5→B6 (∥ C1–C4) |

> **Decisions baked into this gate:** ship OSS self-host **first**, then managed cloud; cloud billing = full metered + Stripe (staged meter → enforce → bill); security = audit-ready posture (ASVS/SOC2-lite + CI gates), **formal SOC2 deferred**; lead marketing with the five differentiators (multi-engine, BYO-DB, dense multi-tenancy, in-stack WAF, tiny footprint) and reach credible parity on the rest.

---

## See also

- [`competitive-matrix.md`](competitive-matrix.md) — per-feature row-by-row vs Supabase & Firebase (status / gap / effort / priority).
- [`roadmap-to-market.md`](roadmap-to-market.md) — the delivery plan: Phase 0 + Track A (OSS) + Track B (cloud) + Track C (scale/HA), each with anchors and exit gates.
- [`grobase-master-plan.md`](grobase-master-plan.md) — scale program (§7) and the benchmark placeholders.
- [`product-plan/06-saas-multitenancy-quotas-billing.md`](product-plan/06-saas-multitenancy-quotas-billing.md) — quotas/metering/billing design (Bar 4).
- [`product-plan/09-100k-tenant-path.md`](product-plan/09-100k-tenant-path.md) — 100K-tenant scaling path (Bar 2).
- [`security-audit.md`](security-audit.md) — audit findings and residuals (Bar 3).
- [`cost-analysis.md`](cost-analysis.md) / [`offer-sheet-v2.md`](offer-sheet-v2.md) — per-tenant cost model and pricing.
- [`nano-vs-pocketbase.md`](nano-vs-pocketbase.md) — nano-edition competitive footing.
