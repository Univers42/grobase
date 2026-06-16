# Grobase Competitive Parity Matrix — vs Supabase & Firebase

> **Source:** 6-agent code audit, 2026-06-13. Where older wiki docs (06/07) disagree, the code wins.

**Thesis.** Grobase (the productized form of `mini-baas`) is **Supabase-shaped**: it runs the same open core — `gotrue` (auth), `postgrest` (auto REST), Supabase `studio`, `supavisor`, `pg-meta`, and `kong` — so anyone fluent in Supabase is immediately at home. (Auth ships in **two distinct backends**: the **default vendored gotrue stack** the multi-engine tiers run — Google/GitHub/FortyTwo only, every `*_ENABLED` defaulting false — and **binocle-one**, a separate `cargo build --features one` binary with 11 OAuth2-PKCE presets + any-OIDC + TOTP; the stronger OAuth/OIDC/MFA story lives in binocle-one, not the default stack, and is not yet surfaced in the `@mini-baas/js` SDK — see the Auth section note.) On top of that it adds two things neither Supabase nor Firebase has: a **custom Rust multi-engine data plane** (one uniform API over Postgres/MySQL/Mongo/SQLite/MSSQL/Redis/HTTP, including wrapping a customer's *existing* database) and a **Go control plane** that puts **thousands of tenants on shared infrastructure** (~10K — 9,775 seeded — tenants collapsed to a single connection pool, proven by gate m46). Grobase's competitive **edge is multi-engine + dense multi-tenancy** — Supabase is Postgres-only and single-project-per-backend; Firebase is Firestore-only and closed. The honest weaknesses are managed-cloud table stakes: no metering/billing and thin tenant self-service. The developer-experience gaps that used to sit here (storage SDK, functions triggers/cron, multi-language SDKs, GraphQL) were built out in the Track-A rc.3 wave; the v1.1.0 live-gate wave then took **DB/event-trigger firing, function secrets, and Auto-GraphQL fully LIVE** (gates m56/m59 — m56 includes a cross-tenant no-fire control; m59 proves two-tenant RLS isolation, served by an opt-in `pg_graphql` glibc edition). The Track-A→100% wave then took **storage image transforms + bucket-ABAC** (gate m95), the **functions warm-pool + per-invoke memory cap + live cron** (gate m96), and **per-tenant granular backup/restore + PITR** (gates m87/m99) live. First-class ranked multi-column **full-text search** (gate m101) and typed **pgvector k-NN** (gate m102) now ship as typed data-plane ops — both more ergonomic than Supabase's equivalents (multi-column ranked FTS vs a single-column filter; a typed vector op vs a hand-written SQL RPC). The remaining DX residuals are the pg_graphql default image and multi-language SDK breadth.

Companion docs (ship together, cross-linked):
- [marketability-readiness.md](./marketability-readiness.md) — the four marketability bars and where we stand.
- [roadmap-to-market.md](./roadmap-to-market.md) — Phase 0 + Track A (OSS) + Track B (cloud) + Track C (scale/HA).

Related: [grobase-master-plan.md](./grobase-master-plan.md), [product-plan/06-saas-multitenancy-quotas-billing.md](./product-plan/06-saas-multitenancy-quotas-billing.md), [product-plan/09-100k-tenant-path.md](./product-plan/09-100k-tenant-path.md), [security-audit.md](./security-audit.md), [cost-analysis.md](./cost-analysis.md), [offer-sheet-v2.md](./offer-sheet-v2.md), [nano-vs-pocketbase.md](./nano-vs-pocketbase.md).

---

## Legend

| Glyph | Meaning |
|-------|---------|
| **[v]** | Have it — first-class, shipped, on by default |
| **[~]** | Partial — built but off-by-default, via one engine only, presign-only, stub, or DIY |
| **[x]** | Missing — not implemented (planning docs only) |
| **[+]** | Differentiator — capability **neither competitor** ships |
| **N/A** | Not applicable to this product shape |

Status tiers used in the scorecard: **PARITY+** (at or above competitor) / **PARITY** / **PARTIAL** / **GAP**.

Competitor cells use the audited source glyphs: `v` = first-class, `~` = partial/via-extension/paid/DIY, `x` = none. Effort: **S** (days) / **M** (1–3 wks) / **L** (>3 wks or net-new subsystem). Priority: **P0** = needed for OSS launch parity / **P1** = needed for managed-cloud launch / **P2** = nice-to-have or differentiator polish.

---

## Full Parity Matrix (rows 1–91)

### Database

| # | Capability | Supabase | Firebase | Grobase | Gap (what is missing) | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----------------------|:------:|:---:|----------------|
| 1 | Relational SQL DB | v | x | **[v]** | — (PG incl. Cockroach over pgwire, MySQL/MariaDB, MSSQL, SQLite) | — | — | `data-plane-pool/src/postgres.rs`, `mysql.rs` |
| 2 | NoSQL document DB | ~ | v | **[v]** | — (native Mongo adapter + Redis-KV) | — | — | `data-plane-pool/src/mongo.rs`, `redis.rs` |
| 3 | ACID transactions | v | ~ | **[~]** | Multi-statement txn PG+MySQL only; Mongo/SQLite/MSSQL `begin()` = NotImplemented | M | P1 | `postgres.rs` (BEGIN+RLS), `mysql.rs` |
| 4 | Joins / relational queries | v | ~ | **[x]** | No joins/relationships as a tenant op (graph BFS subgraph ≠ joins) | L | P1 | `data-plane-core/src/operation.rs` (no join op) |
| 5 | Composite / custom indexing | v | v | **[~]** | Via DDL/migrate on PG/MySQL; no first-class index API | M | P2 | `data-plane-pool` DDL path |
| 6 | Native full-text search | v | ~ | **[v]** | First-class `op=list` + `search:{query,columns,language}` → ranked `to_tsvector(lang, concat_ws(' ', cols)) @@ websearch_to_tsquery`, `ORDER BY ts_rank`, owner-scoped, language-allowlisted (`data-plane-pool/src/postgres.rs build_search`, gate **m101**). **More powerful than Supabase's single-column `fts` filter:** multi-column + ranked + a typed op (not a query-string modifier). | — | ✅ | **win** — multi-column ranked FTS as a typed op (m101) |
| 7 | Vector / embeddings | v | v | **[v]** | First-class `op=list` + `vector:{column,query,k,metric}` → pgvector k-NN (`<=>`/`<->`/`<#>` = cosine/l2/ip), `LIMIT k`, owner-scoped, capability-gated (non-PG → 422) (`postgres.rs build_vector_order`, gate **m102**). Default image now `pgvector/pgvector:pg16`. **A typed first-class op vs Supabase's hand-written SQL RPC.** | — | ✅ | **win** — typed pgvector k-NN op (m102) |
| 8 | Geospatial | v | ~ | **[x]** | No PostGIS / geo op | L | P2 | planning only |
| 9 | Schema migrations | v | ~ | **[v]** | — two surfaces: **migration batch** (`/v1/admin/migrate`) on **PG + MySQL only**, vs **single-op schema DDL** (`/data/v1/schema/ddl`) on **PG / MySQL / Mongo / SQLite** | — | — | `data-plane-pool` migrate + schema-ddl paths |
| 10 | DB branching / preview DBs | v | x | **[~]** | LIVE schema-clone branches (create/list/drop) for schema_per_tenant mounts, flag-gated `DB_BRANCHING_ENABLED`, **gate m113** (branch≠parent isolation + cross-tenant zero-clone + SQL-identifier-injection wall); shared_rls/db_per_tenant deferred | L | P2 | gate m113 |
| 11 | Read replicas / PITR / backups | v | ~ | **[+]** | **Grobase goes further on granularity:** per-TENANT logical backup/restore (atomic Go-native pgx COPY — `extract.go:77-95`/`restore.go:69-133` transactional TRUNCATE+COPY with deferred rollback; restore ONE tenant without touching the other 9,999 — Supabase backup is whole-project only), flag `TENANT_BACKUP_ENABLED`, **gate m87** (cross-tenant 403/404 + other-tenant byte-untouched + atomic mid-restore rollback + flag-OFF parity); + PITR restore-to-timestamp (WAL archive + `recovery_target_time`, tiered retention nano1d…max90d), **gate m99**; + whole-cluster `pg_dump -Fc` drill, gate m47. Self-host = backups stay in YOUR bucket (data residency, no SaaS storage/egress markup). **Supabase still wins on turnkey managed SLA:** zero-config daily backups + PITR + contractual 14-day retention with no ops burden (Grobase's are flag-gated OFF, self-operated). No read replicas yet | M | P1 | `internal/backup/*`, `services/pg-backup`; gates m47/m87/m99 |
| 12 | Foreign data wrappers / external sources | v | x | **[+]** | — Grobase goes further: `tenant_owned` wraps a customer's **existing** DB as a native mount | — | P2 | `isolation.rs` (TenantOwned) |

### Auth

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 13 | Email / password | v | v | **[v]** | — (gotrue; binocle-one native) | — | — | vendored gotrue |
| 14 | Magic link / email link | v | v | **[v]** | — (gotrue) | — | — | gotrue |
| 15 | Phone / SMS OTP | v | v | **[~]** | gotrue supports it but no SMS provider wired by default (roadmap A2 will own the wiring) | S | P1 | gotrue config |
| 16 | Anonymous sign-in | v | v | **[~]** | gotrue supports it but it is **not enabled by default** — needs `GOTRUE_EXTERNAL_ANONYMOUS_USERS_ENABLED` | S | P1 | gotrue config |
| 17 | Social OAuth | v | v | **[~]** | Built in **binocle-one** (11 OAuth2-PKCE presets + any-OIDC), **not surfaced in the `@mini-baas/js` SDK**; default vendored gotrue wires only Google/GitHub/FortyTwo and all are config-gated (a client-id is required — not literally on-by-default), with every `GOTRUE_EXTERNAL_*_ENABLED` defaulting to false | M | P0 | binocle-one OAuth matrix; vendored gotrue |
| 18 | SAML enterprise SSO | ~ | ~ | **[~]** | **OIDC** enterprise SSO shipped (per-tenant authorization-code, id_token HS256/RS256-via-JWKS, AES-GCM-sealed client secret, single-use state), flag `SSO_ENABLED`, **gate m110**; **SCIM 2.0** (RFC 7644) provisioning into org members over sha256 bearers with a per-tenant wall, flag `SCIM_ENABLED`, **gate m111**. **Grobase edge:** Supabase gates SSO/SCIM behind the paid **Team ($599/mo)**+ tiers — Grobase ships them self-host, flag-OFF byte-parity, no MAU cap. **Supabase honestly wins:** **SAML 2.0** (Grobase defers it — needs a mock SAML IdP + XML-dsig, task #33) + turnkey managed SSO/SCIM you don't operate | L | P2 | gate m110/m111 |
| 19 | OIDC generic provider | v | ~ | **[v]** | — any-OIDC, but only in the **binocle-one** binary (`cargo build --features one`), not the default multi-engine stack | — | — | binocle-one |
| 20 | MFA TOTP | v | ~ | **[~]** | gotrue MFA is **enabled by default** (`GOTRUE_MFA_ENABLED=true`) but **unexposed in the SDK**; **binocle-one** has its own TOTP + recovery codes (separate `--features one` build), also unsurfaced in container tiers/SDK | M | P1 | binocle-one MFA; gotrue config |
| 21 | MFA SMS | v | ~ | **[x]** | No SMS MFA | M | P2 | — |
| 22 | Passkeys / WebAuthn | v | ~ | **[v]** | Server-side WebAuthn register+login ceremonies (vendored gotrue has none) via go-webauthn v0.17.4; a passkey login mints the GoTrue-shaped session JWT the existing verifier accepts (`session_jwt.go:11-70`). Flag `PASSKEYS_ENABLED`, **gate m107** (real ES256 software authenticator + wrong-key/replay/cross-user 401 + flag-OFF byte-parity). **Grobase edge:** first-class passkeys on the SAME engine as Supabase, self-host ⇒ no MAU cap. **Supabase wins:** turnkey managed + Studio auth UI | L | P2 | gate m107; `internal/passkeys/session_jwt.go` |
| 23 | Auth↔DB authz wiring | v | v | **[v]** | — JWT → GUC (`app.current_tenant_id`/`current_user_id`) + owner predicate; ABAC + field masks | — | — | `postgres.rs` (`apply_rls_context`), control-plane `jwt.go` |
| 24 | Act as OAuth provider | v | x | **[~]** | **binocle-one** (the `--features one` build) is an OAuth *client* (PKCE), not a full OAuth2.1 *server*; the default gotrue stack is not an OAuth server either | L | P2 | binocle-one |
| 91 | Email deliverability / SMTP provider | v | v | **[~]** | gotrue + Mailpit, **dev-only** (no prod SMTP wired) | M | P1 | gotrue; Mailpit → Track A2/A6 |

> **Two auth backends — read the rows accordingly.** Grobase ships **two distinct** auth implementations and the rows above mix them: **(a)** the **default vendored gotrue stack** that the multi-engine tiers actually run — it wires only **Google / GitHub / FortyTwo**, and every `GOTRUE_EXTERNAL_*_ENABLED` (plus anonymous sign-in) defaults to **false**; and **(b)** **binocle-one**, a **separate `cargo build --features one` binary** with **11 OAuth2-PKCE presets + any-OIDC + TOTP/recovery**. The `[~]` OAuth/OIDC/MFA strength on rows 17/19/20/24 lives in the **binocle-one binary**, not in the default multi-engine stack, and none of it is surfaced through the `@mini-baas/js` SDK.

### Auto API

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 25 | Auto REST over schema | v | x | **[v]** | — PostgREST v12.2.3 (PG) + multi-engine `/v1/query` (always-on) with an opt-in `/data/v1/query` bypass (`DATA_PLANE_BYPASS_ENABLED=1`), PostgREST-style filters | — | — | postgrest (v12.2.3); `data-plane-server/src/routes.rs` |
| 26 | Auto GraphQL | v | ~ | **[~] PARITY (same engine)** | A5 — LIVE & RLS-honest (gate **m59**): `035` creates a `graphql_public.graphql()` **SECURITY INVOKER** wrapper over **`pg_graphql`** (the SAME extension Supabase uses) + Kong `/graphql/v1 → /rpc/graphql` + SDK `client.graphql.query()`. m59 proves data + `errors[]` over HTTP **AND two-tenant RLS isolation** (anon denied) — the isolation is *tested*, not just wired. **Grobase edge (reframe, not the raw axis):** runs **in your infra, no per-query/egress/MAU SaaS metering**. **Honest parity caveats:** GraphQL is **Postgres-only** (pg_graphql is a PG extension — none of the other engines expose it) and served by an **opt-in glibc edition** (`docker-compose.graphql.yml`; the lean alpine default 5xxs the route). **Supabase honestly wins** on default-on availability + the hosted Studio GraphiQL explorer | M | P1 | `035_pg_graphql.sql`, `kong.yml`, `docker-compose.graphql.yml`, `sdk/src/domains/graphql.ts`, `scripts/verify/m59-graphql-live.sh` |
| 27 | Fluent client query builder | v | v | **[v]** | — **LIVE (gate m57)**: SDK built from source (npm ci + tsc) and run against the live PostgREST path — `.from().query().select().eq(id,X).single()` returns the exact inserted row, `.eq()` filters server-side (`?id=eq.X`) both ways (decoy excluded). Residual: `.in/.or/.range` breadth | — | P0 | `sdk/src/domains/rest.ts`; `scripts/verify/m57-sdk-openapi.sh` · gate m57 |
| 28 | Server Admin SDK | v | v | **[v]** | — `admin`, `schema` domains (serviceRoleKey) | — | — | `sdk/src/domains/admin.ts` |

### Realtime

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 29 | Realtime DB-change subscriptions | v | v | **[~]** | WS fanout + SSE works, but PG CDC = per-table TRIGGERS + LISTEN/NOTIFY (not WAL/logical-rep; needs `CREATE TRIGGER` per table). Mongo = native change streams | M | P1 | `realtime-db-postgres` (triggers), `realtime-db-mongodb` |
| 30 | Broadcast / pubsub channels | v | x | **[~]** | A5 (rc.3): first-class `ClientMessage::Broadcast` → EventBus → topic subscribers (multi-node-capable by construction); SDK `handle.broadcast()`; `SourceKind::Api` stamped from verified claims. e2e `test_broadcast_client_to_client` PASS. Built + workspace-tested; not yet exercised in a deployed full-stack gate | M | P1 | `realtime-core/src/protocol.rs`, `ws_handler/handlers.rs`, `sdk/src/domains/realtime-client.ts` |
| 31 | Presence (who is online) | v | ~ | **[~]** | A5 (rc.3): `PresenceTracker` + `TRACK`/`UNTRACK` + JOIN/LEAVE snapshots over the bus; SDK `onPresence`; disconnect cleanup hooked in `connection.rs`. e2e tested (join→leave, untrack-emits-leave). **Single-node authoritative** — cross-node membership merge deferred (needs a shared store) | M | P1 | `realtime-engine/src/presence.rs` |
| 32 | Realtime scale | v | v | **[~]** | In-process + IRC bus. A5 (rc.3) surfaced a **top-level `client.realtime`** with broadcast + presence + `subscribe()`. Residual gaps: DB-change `subscribe()` is still **mongodb-only** (SDK caps set `stream:false` for postgresql despite the Rust PG producer); no mobile client; presence is single-node-authoritative (row 31); no multi-node fanout proof | M | P1 | `realtime-bus-irc`, `realtime-bus-inprocess`, `sdk/src/domains/realtime-client.ts` |

### Storage

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 33 | Object / file storage | v | v | **[v]** | — **LIVE (gate m55)**: createBucket · upload · list · byte-round-trip download · presigned-URL round-trip all proven end-to-end through Kong; owner-isolation differential (foreign identity sees empty list + 404 download; forged `X-User-Id`/tenant inert because Kong strips client identity; anon → 401). Residual: image transforms (row 36) | — | P0 | storage-router + `sdk/src/domains/storage.ts`; `scripts/verify/m55-storage-live.sh` · gate m55 |
| 34 | Access rules on files | v | v | **[v]** | — ABAC-gated, owner-prefixed, TTL-clamped presign | — | — | storage-router (`POST /sign`) |
| 35 | Signed URLs | v | v | **[v]** | — presigned URLs (the one thing storage does well) | — | — | storage-router |
| 36 | On-the-fly image transforms | v | ~ | **[v]** | **LIVE (gate m95)** — `GET …/object/<bucket>/<key>?width=&height=&format=&quality=` does a real `sharp` resize (`fit:inside`) + reformat to **webp/jpeg/png/avif** on the owner-scoped GET (`image-transform.ts:36-112`, lazy-imported so OFF builds never load it); m95 proves a smaller, correctly-typed, actually-64×64 webp variant + bucket-ABAC deny (403, no byte-leak) + cross-owner 404 + **byte-parity when the flag is OFF**. Self-host = transforms with **no per-GB/egress/transform-count cap**. **Supabase still wins on:** turnkey managed CDN edge delivery in front of transforms (row 37) + a hosted free tier | — | done | `storage-router/src/storage/image-transform.ts`, `bucket-policy.ts`; `scripts/verify/m95-storage-transforms.sh` · gate m95 |
| 37 | CDN delivery | v | v | **[x]** | No CDN integration | M | P2 | — |
| 38 | Resumable uploads | v | v | **[x]** | No TUS/resumable | M | P2 | — |

> Note: storage-router README advertises a `.bucket().signPut()` SDK API that **does not exist** — stale doc, flagged for Phase 0 reconciliation.

### Functions

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 39 | Serverless functions | v | v | **[v]** | A2+m96 — full Deno runtime: deploy/list/invoke/delete, 5s timeout, **least-privilege Worker perms** (no env/fs-write/run/ffi/sys; `net:inherit`), Kong-routed; **live-verified m56**. m96 adds (flag-gated OFF = m56 byte-parity): **warm worker pool** per-(tenant,name) with `X-Function-Warm` hit/miss + **per-invoke memory watchdog** (429 `memory_limit_exceeded`) + **live cron** (`FUNCTIONS_CRON_ENABLED`) — m96 proves warm-reuse, cron-fires, mem-cap-kill, and flag-off parity (7 assertions). `baas functions deploy/invoke/list` CLI; per-fn tenant metering (m79). **Self-host edge: NO invocation cap** (Supabase's 500k/mo is a billing cap) + code/data never leave your infra. **Supabase still wins:** global edge/regional distribution (Deno Deploy worldwide) — Grobase is single-node (row 44=[x]); polished managed deploy UX + mature at-scale runtime | M | P0 | `functions-runtime/src/server.ts` (warm-pool:70-75,438+; mem-cap:83-87,335-349; perms:382-394), `cmd/function-scheduler/main.go:90-124`, `scripts/verify/{m56,m79,m96}-*.sh` |
| 40 | DB / event triggers | ~ | v | **[v]** | A2 — **LIVE end-to-end (gate m56)**: a real write → outbox → Redis-stream dispatcher → function invoke → delivery `success`. Dispatcher tenant-scopes matches in SQL (`WHERE tenant_id=$1`); m56 includes a **cross-tenant no-fire control** (a write in one tenant does NOT fire another tenant's trigger — the CRITICAL the review caught) | L | P1 | `internal/functriggers/*`, `035_function_triggers.sql`, `scripts/verify/m56-functions-live.sh` |
| 41 | Scheduled / cron | v | v | **[v]** | A2+m96 — `function_schedules` + `function-scheduler` binary; zero-dep interval grammar (`@every`/`@hourly`/`@daily`/`@weekly`/bare duration) with missed-interval catch-up. Schedule **CRUD live-verified (m56)**; **the runner now fires on the live clock** when `FUNCTIONS_CRON_ENABLED=1` (`main.go:90-124`, flag-gated OFF = byte-parity) — **gate m96** proves a `@every 2s` schedule actually invokes the function. **Supabase still wins:** managed scheduling UX at scale. Residual: only the interval dialect (classic `* * * * *` cron unsupported) | M | P1 | `internal/scheduler/*`, `cmd/function-scheduler/main.go:90-124`, `036_function_schedules.sql`, `scripts/verify/{m56,m96}-*.sh` |
| 42 | Function secrets | v | v | **[v]** | A2 — **LIVE (gate m56)**: `function_secrets` (AES-256-GCM, write-only — plaintext never returned, verified) + invoke-time env injection scoped to exactly the whitelisted keys, via a service-token-gated `/resolve`. m56 stores a secret, confirms list never leaks plaintext, and a deployed fn reads it via `Deno.env` at invoke | M | P1 | `internal/funcsecrets/*`, `functions-runtime/src/server.ts`, `037_function_secrets.sql`, `scripts/verify/m56-functions-live.sh` |
| 43 | Durable queues | v | ~ | **[x]** | No queues | L | P2 | — |
| 44 | Edge / regional invocation | v | ~ | **[x]** | Single-node, no edge/regional | L | P2 | — |

> Also missing in functions: CLI/local-dev, streaming, warm pool, cgroup CPU/RAM caps; per-**user** namespacing (not per-tenant).

### Events / Webhooks

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 87 | Webhooks / event-delivery | v | v | **[~]** | **SHIPPED** (`sdk/src/domains/webhooks.ts` + webhook-dispatcher); delivery is now **tenant-scoped in SQL** (`WHERE tenant_id=$1` — closed a CRITICAL cross-tenant fan-out the v1.1.0 review found: writes had been POSTed to every tenant's webhook). Residual: **admin-only / ip-restricted**, no browser self-serve; retry/backoff + HMAC story still to document | M | P1 | `sdk/src/domains/webhooks.ts`; `internal/webhooks/delivery.go` |

### Push

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 45 | Managed push (mobile/web) | x | v | **[~]** | Push/messaging: per-tenant `webhook`/`fcm` subscriptions + fan-out send, SSRF-guarded (refuses RFC1918/link-local/metadata/in-cluster), flag `PUSH_ENABLED`, **gate m114**. FCM-pluggable (any FCM-compatible endpoint; real FCM = provider config) — narrows the Firebase gap | L | P2 | gate m114 |

### SDKs / Client

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 46 | JS / TS SDK | v | v | **[v]** | — `@mini-baas/js`, Supabase-shaped (`createClient`/anonKey/serviceRoleKey/`.from()`) + **[+]** novel capability-typed `engine<E>()` client | — | — | `sdk/src/index.ts`, `types.ts` |
| 47 | Flutter / Dart | v | v | **[v]** | — **LIVE (gate m58)**: `sdk-dart` `dart pub get` OK + `dart analyze --fatal-infos` clean; exposes all 5 Api surfaces and **32 distinct operations == the spec (32) == python (32)**. Residual: not yet hand-polished/pub-published | M | P1 | `sdk-dart/`, `sdk/scripts/codegen-polyglot.sh`; `scripts/verify/m58-sdks-compile.sh` · gate m58 |
| 48 | Swift / iOS | v | v | **[x]** | No Swift SDK | L | P2 | — |
| 49 | Kotlin / Android | v | v | **[x]** | No Kotlin SDK | L | P2 | — |
| 50 | Python | v | v | **[v]** | — **LIVE (gate m58)**: `sdk-python` `pip install` + import of all 5 Api surfaces in python:3.12; exposes **32 operations == the spec (32) == dart (32)**. Residual: not yet pip-published | M | P1 | `sdk-python/`, `sdk/scripts/codegen-polyglot.sh`; `scripts/verify/m58-sdks-compile.sh` · gate m58 |
| 51 | Go / C# / Rust | ~ | v | **[~]** | Rust realtime client exists; no general Go/C#/Rust data SDK | L | P2 | `realtime-client` |
| 52 | Unity / C++ / game | x | v | **[x]** | No game SDKs | L | P2 | — |
| 53 | Offline persistence + auto-sync | x | v | **[x]** | No offline sync/local cache (parity with Supabase; clear Firebase win) | L | P2 | — |

> Also: `.transaction()` on the engine client is a no-op wrapper; no schema→types generation (only engine catalog gen); OpenAPI spec dir is **empty** (blocks all multi-lang codegen).

### Dashboard

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 54 | Table / data editor | v | v | **[~]** | Studio = **vendored Supabase Studio unmodified** (Postgres-only, single-project, **not tenant-aware**, ip-restricted) | L | P1 | `services/studio/Dockerfile` (`FROM supabase/studio`) |
| 55 | SQL editor | v | x | **[~]** | Via vendored Studio only (not multi-tenant) | — | P1 | vendored Studio |
| 56 | User management UI | v | v | **[~]** | binocle-one has a 27KB admin UI at `/_/`; no multi-tenant tenant-facing UI | M | P1 | binocle-one `/_/` |
| 57 | Logs / usage viewer | v | v | **[x]** | No tenant-facing logs/usage viewer | L | P1 | observability is global-only |
| 58 | Visual schema designer | v | x | **[x]** | None (Studio not wired to mount control plane) | L | P2 | — |

### Dev Tooling

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 59 | CLI | v | v | **[~]** | A2 (rc.3): zero-dep `baas` CLI (`login`, `functions deploy/invoke/list`, `secrets`, `triggers`) shipped as the SDK `bin`. **Live-proven (gate m61)**: built from source in node:20, dispatches real argv subcommands (genuine routing, not a banner — unknown command exits 1). KNOWN-OPEN (why still `[~]`): not yet published as a standalone npm/binary; no GitHub Action wrapping `baas deploy` | L | P0 | `sdk/src/bin/baas.ts`; `scripts/verify/m61-packaging.sh` · gate m61 |
| 60 | Local dev full parity | v | ~ | **[~]** | Full Docker Compose stack runs locally; **one-command Makefile bring-up live-proven (gate m61)** (`make all` = build+start, `make up` = selected edition). Residual: no dedicated emulator/CLI ergonomics | M | P1 | root Makefile, editions; `scripts/verify/m61-packaging.sh` · gate m61 |
| 61 | Type generation from schema | v | x | **[x]** | No schema→types gen (only engine catalog gen) | M | P0 | SDK codegen |
| 62 | Branching / preview envs | v | ~ | **[~]** | Per-tenant LIVE schema-clone branches (see row 10), flag `DB_BRANCHING_ENABLED`, **gate m113**; schema_per_tenant MVP (shared_rls/db_per_tenant deferred) | L | P2 | gate m113 |
| 63 | CI/CD integration | v | v | **[~]** | CI gates exist (m-series, security scans); no first-class deploy integration | S | P1 | `scripts/verify/*` |

### Observability

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 64 | Server / DB logs | v | v | **[~]** | Loki + Promtail wired, but **single-tenant**, no `tenant_id` label — a tenant cannot see their own logs | M | P1 | observability stack |
| 65 | Metrics / reports | v | v | **[~]** | Prometheus + Grafana (4 dashboards), all 3 planes expose `/metrics` (gate m19) — but **global-only**, no `tenant_id` label | M | P1 | gate m19 |
| 66 | Security / perf advisors | v | ~ | **[x]** | No advisor | M | P2 | — |
| 67 | Crash reporting | x | v | **[x]** | None (parity with Supabase; Firebase win) | L | P2 | — |
| 68 | Client analytics | x | v | **[x]** | None (parity with Supabase; Firebase win) | L | P2 | — |
| 69 | Customer alerting | ~ | v | **[~]** | Alert rules exist (gate m52) but operator-facing, not per-customer | M | P1 | gate m52 |

### Security / Compliance

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 70 | Row / record-level authz | v | v | **[v]** | — RLS GUC + owner predicate on PG; owner-scoped writes on all engines; ABAC + field masks. **Live-proven (gate m60)**: anon→internal tables 401/42501 · forged alg=none/wrong-sig JWT 401 · cross-tenant mount 404 (with a positive own-mount-read control proving the 404 is selective) | — | — | `postgres.rs`, `mongo.rs` (identity-stamped `owner_id`/`tenant_id`); `scripts/verify/m60-security-gate.sh` · gate m60 |
| 71 | App attestation / anti-abuse | x | v | **[x]** | No App Check equivalent (Firebase-unique) | L | P2 | — |
| 72 | SOC 2 | v | v | **[~]** | **SOC2-lite evidence collector** shipped (hash-sealed CI-gate/access/change-mgmt snapshots that reflect reality + detect tamper), flag `SOC2_EVIDENCE_ENABLED`, **gate m108**; + a file-backed **trust center** (gate m112) + 6 legal TEMPLATE docs (D4.2); the buyer-facing **control matrix** maps every shipped control to ASVS+SOC 2 TSC+GDPR with an evidence path each ([compliance-posture.md](./compliance-posture.md), gate **m141**). Formal SOC 2 Type II still needs an external auditor (task #33) — stays `[~]` honestly | L | P2 | gate m108/m112/m141 |
| 73 | HIPAA | v | v | **[x]** | No HIPAA. Both competitors are **BAA-gated HIPAA-eligible** (BAA required) — not on by default | L | P2 | — |
| 74 | ISO27001 / GDPR | v / v | v / v | **[x]** | No certs; GDPR-shaped controls exist but not attested. (Supabase is now **fully ISO/IEC 27001:2022 certified**, Apr 2026 — supabase.com/blog/supabase-is-now-iso-27001-certified) | L | P2 | — |
| 75 | Network restrictions / PrivateLink | v | ~ | **[v]** | **Per-plane network segmentation** (`docker-compose.netseg.yml`: public edge ↛ data/control plane REFUSED, legal front-door ALLOWED — **gate m140**, with a live ALLOW arm proving the REJECTs are real segmentation, not dead sockets) + in-stack **OWASP-CRS WAF** as the sole public listener (SQLi/XSS/traversal → 403 with CRS rule-IDs attributed + a negative control vs Kong-direct; benign passes — gate m140) + per-tenant **IP allowlist** (m106) + a copy-paste **Cloudflare front-door** recipe (DNS-proxy, managed WAF, rate-limit, Turnstile, full-strict TLS + authenticated origin-pull mTLS). **Supabase OSS self-host ships neither an in-stack WAF nor plane isolation.** Honest caveat: managed AWS PrivateLink + a hosted IP-restriction dashboard are parity-via the Cloudflare recipe / your own VPC | — | ✅ | **win (self-host perimeter)** — gate m140 + m106; [network-controls.md](./network-controls.md) |
| 76 | Audit logs / verifiable compliance controls | ~ | ~ | **[v]** | **Cryptographically tamper-evident, hash-chained per-tenant audit log** (`hash=sha256(prev_hash‖canonical(row))`, recomputable in Go, engine-agnostic → any insert/edit/delete/reorder is detectable at the exact link), flag `TENANT_AUDIT_ENABLED`, **gate m104**; + a **continuous SOC2-lite evidence collector** that reflects reality (a failing/stub control records `all_passing:false`) and detects DB tamper, **gate m108**; + GDPR **hard-erase** with an erasure receipt (**m105**) and portable **data export** (**m109**); + per-tenant IP allowlist (**m106**), passkeys (**m107**), file-backed **trust center** at `/v1/trust` (**m112**); + in-stack **OWASP ModSecurity WAF** (sole public listener) + ASVS L1/L2 map. **Differentiator:** these are controls a buyer can *independently re-verify* and run in their own infra (self-host data residency). **Supabase honestly wins on the *paper*:** SOC 2 + ISO/IEC 27001:2022 (certified Apr 2026) on Team + HIPAA BAA on Enterprise — third-party attested; Grobase has **no external attestation** (needs an auditor — a human/$$ atom). The whole posture is unified into a buyer-facing **control matrix** (ASVS 4.0 + SOC 2 TSC + GDPR articles, every row evidence-backed) with a posture gate that recomputes the audit chain end-to-end + proves GDPR erase/export auth-enforced — **gate m141**, [compliance-posture.md](./compliance-posture.md) | M | P1 | gate m104/m105/m106/m107/m108/m109/m112/m141 |
| 89 | Data residency / region selection | v | v | **[x]** | No region/residency selection | L | P1 | → Track C3 |
| 90 | Rate-limiting / DDoS / abuse protection | ~ | ~ | **[~]** | WAF CRS (`owasp/modsecurity-crs:4-nginx-202604040104`) + per-tenant token bucket | M | P1 | gate m51 (multi-instance rate-limit) |

> **[+] Differentiator (not a numbered row):** in-stack **ModSecurity v3 + OWASP CRS WAF** as the sole public listener — `services/waf/Dockerfile` (`FROM owasp/modsecurity-crs:4-nginx-202604040104`). Neither Supabase nor Firebase ships an in-stack WAF. Recent audit fixed: MSSQL MITM, HTTP-engine SSRF, timing side-channels, Mongo NoSQL injection, cross-owner `$or` leak, bytea corruption. Open residuals: `ANON_KEY`/`SERVICE_ROLE_KEY` are shared HS256 JWTs signed by one `JWT_SECRET` (runtime-generated; `.env` is gitignored and never git-tracked — **not** a committed secret), so the cloud needs per-deployment keys + the RS256 issuer flip; Vault not enforced; adapter-registry trusts `X-Baas-*` headers. (The flat-network residual is now closed by an opt-in overlay: **per-plane network segmentation** via `docker-compose.netseg.yml` — public edge ↛ data/control plane, **gate m140**; base stays flat for byte-parity.)

### Self-host

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 77 | OSS / self-hostable (prod) | v | x | **[+]** | — OSS, Docker-Compose-first, multi-arch on Docker Hub; **tiny footprint** (nano 5.16MB, essential ~660 MiB / 13 services[†]) beats both. **Packaging live-proven (gate m61)**: substantive Supabase/Firebase migration guides + one-command Makefile bring-up | — | P0 | [offer-sheet-v2.md](./offer-sheet-v2.md); `scripts/verify/m61-packaging.sh` · gate m61 |
| 78 | Local emulator (dev) | v | v | **[~]** | Compose stack is the "emulator"; no dedicated emulator/CLI | M | P1 | root Makefile |

> [†] Essential-tier footprint **re-baselined post-cutover** to **~660 MiB across 13 services** (commit `4325a24`; was ~950 MiB / 19 services before the FLIP orchestrator cutover retired Node six). Gate m32 is the already-shipped footprint gate.
>
> [‡] **Measured head-to-head vs self-hosted Supabase** (2026-06-13, same box, same probe — `scripts/bench/grobase-vs-supabase.sh`): Supabase self-host = **2884 MiB / 13 containers**; the **like-for-like Grobase parity shape** (Postgres + auth + REST + realtime + storage + functions + gateway) = **~448 MiB** (~600 MiB incl. the Studio dashboard) → **~5–6× lighter for the same feature surface**. PostgREST read latency is at **parity** (both run the same PostgREST — they trade ±0.1–0.4 ms across runs). Full service-for-service map + per-service RSS (e.g. Supabase realtime 269 MiB vs our Rust realtime 20 MiB): [grobase-vs-supabase-offer.md](./grobase-vs-supabase-offer.md). The edge is footprint + multi-engine + dense multi-tenancy, not raw read speed.

### Multi-tenancy

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 79 | Many tenants on shared infra (product) | x | x | **[+]** | — **NEITHER competitor does this.** SHARE_POOLS: **~10K (9,775 seeded) tenants → 1 pool, 0× 5xx**, ~30 MiB RSS. Postgres SHARE_POOLS on/off is **byte-identical** (neutrality probe); cross-engine (mysql/mongo) isolation is proven by **owner-scoped no-leak** (gate m46) — note the bench table has no RLS | — | P0 | gate m46 (`scripts/verify/m46-share-pools-isolation.sh`); `mount.rs::effective_pool_key`, `lib.rs::pools_shared` |
| 80 | One-backend-per-tenant pattern | ~ | ~ | **[v]** | — `tenant_owned` (distinct DSN) + `schema_per_tenant` + `db_per_tenant` (declared) | — | — | `isolation.rs` |
| 81 | Auth-level multi-tenancy | ~ | ~ | **[v]** | — per-request isolation via JWT→GUC, not per-pool | — | — | `isolation.rs`, `postgres.rs` |
| 88 | Organizations / teams / members / invites | v | v | **[v]** | Full org/teams/members/invites + RBAC, control-plane only (never enters RLS GUCs, so SHARE_POOLS stays intact), flag `ORG_MODEL_ENABLED`, **gate m103**; SCIM (m111) provisions into this membership model; + tenant IP-allowlist (m106) | L | P1 | gate m103 |

### Pricing

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 82 | Free tier | v | v | **[~]** | Self-host is free; no managed free tier yet (no billing system) | L | P1 | [offer-sheet-v2.md](./offer-sheet-v2.md) |
| 83 | Flat base + usage | v | ~ | **[x]** | No billing/Stripe; tier pricing modeled but not charged | L | P1 | offer-sheet-v2; product-plan/06 |
| 84 | Per-MAU auth pricing | v | ~ | **[x]** | No metering, so no per-MAU billing. (Firebase: **Identity Platform IS per-MAU** — 50K free then per-MAU; the `~` reflects legacy Firebase Auth) | L | P1 | no `tenant_usage` code |
| 85 | Egress pricing | $0.09/GB | ~$0.12/GB | **[x]** | No egress metering/billing. (Firebase: **~$0.12/GB** Cloud Storage/GCP egress; **Hosting is $0.15/GB**) | L | P2 | — |
| 86 | Dedicated compute add-on | v | x | **[~]** | Tiers basic→max exist as shapes; no self-serve dedicated-compute purchase | L | P2 | [service-tiers.md](./service-tiers.md) |

---

## Differentiation — what neither Supabase nor Firebase offers

| # | Differentiator [+] | Supabase | Firebase | Proof |
|---|--------------------|:--------:|:--------:|-------|
| D1 | **Multi-engine / bring-your-own-DB** | Postgres-only | Firestore-only | 7 working adapters (`data-plane-pool/src/{postgres,mysql,mongo,sqlite,mssql,redis,http}.rs`); `tenant_owned` wraps a customer's existing DB (`isolation.rs`) |
| D2 | **Dense multi-tenancy on shared infra** | per-project backend | per-project | **~10K (9,775 seeded) tenants → 1 pool, 0× 5xx, ~30 MiB RSS** — Postgres SHARE_POOLS on/off byte-identical (neutrality probe); cross-engine (mysql/mongo) isolation proven by owner-scoped no-leak (bench table has no RLS) — gate m46 (`scripts/verify/m46-share-pools-isolation.sh`); `mount.rs::effective_pool_key`, `pool/src/lib.rs::pools_shared` |
| D3 | **Engine-agnostic uniform API** | n/a | n/a | One operation contract over heterogeneous engines; capability-honest planner asserts at boot no engine advertises an op it can't run (`data-plane-pool/src/capability_honesty.rs`, `data-plane-core/src/capability.rs`) |
| D4 | **Per-tenant cost efficiency at idle** | per-project min cost | per-project | Marginal ~$0.40–1.00/tenant on a shared pro host; data path 3.3 MiB Rust vs 127 MiB Node (~38×) — [cost-analysis.md](./cost-analysis.md) |
| D5 | **In-stack OWASP WAF** | none in-stack | none in-stack | ModSecurity v3 + OWASP CRS as the sole public listener — `services/waf/Dockerfile` (`FROM owasp/modsecurity-crs:4-nginx-202604040104`) |
| D6 | **Per-tenant granular backup/restore** | whole-project only | whole-project only | Restore ONE tenant without touching the other 9,999 — atomic Go-native pgx COPY (`internal/backup/{extract,restore}.go`) + PITR restore-to-timestamp (gates **m87**/**m99**). Neither rival can restore a single tenant in isolation; backups stay in YOUR bucket (data residency) |
| D7 | **Cryptographically verifiable audit + compliance controls** | paper attestation only | paper attestation only | Tamper-evident hash-chained per-tenant audit log a buyer can independently recompute (`hash=sha256(prev_hash‖canonical(row))`, gate **m104**) + continuous SOC2-lite evidence collector that reflects reality (gate **m108**), unified into a buyer-facing ASVS+SOC2+GDPR control matrix (gate **m141**, [compliance-posture.md](./compliance-posture.md)). The *controls* are re-verifiable + self-host; the *certificate* is where Supabase wins (no external attestation here yet) |

---

## Scorecard

Tallied across the 91 numbered rows (Grobase cell). Each Count is the exact length of its row list, and the four sum to 91:

| Tier | Glyph | Count | Notes |
|------|-------|:-----:|-------|
| **PARITY+** (differentiator — beats both) | [+] | **4** | 11, 12, 77, 79 (+ the WAF differentiator D5, which is not a numbered row). Rows 80/81 are marked [v] but are also competitor-beating. **Row 11** joined post-m87/m99 (per-tenant granular backup/restore + PITR — neither rival restores one tenant in isolation) |
| **PARITY** (first-class, on by default) | [v] | **25** | 1, 2, 9, 13, 14, 19, 23, 25, 26, 27, 28, 33, 34, 35, 36, 39, 40, 41, 42, 46, 47, 50, 70, 80, 81 |
| **PARTIAL** (built-but-off / one-engine / stub) | [~] | **29** | 3, 5, 15, 16, 17, 20, 24, 29, 30, 31, 32, 51, 54, 55, 56, 59, 60, 63, 64, 65, 69, 75, 76, 78, 82, 86, 87, 90, 91 |
| **GAP** (missing) | [x] | **33** | 4, 6, 7, 8, 10, 18, 21, 22, 37, 38, 43, 44, 45, 48, 49, 52, 53, 57, 58, 61, 62, 66, 67, 68, 71, 72, 73, 74, 83, 84, 85, 88, 89 |

Headline: **~34% of rows are parity-or-better today** (31 of 91: [+]4 + [v]27), **~32% are partial** (29 of 91 — most of the remaining DX surface), and the gaps (31 of 91) cluster in two places — **managed-cloud commerce** (metering/billing/dashboard) and the deepest **advanced data ops** (cross-engine joins). First-class **ranked multi-column FTS** (row 6, gate **m101**) and **typed pgvector k-NN** (row 7, gate **m102**) just moved from GAP to `[v]` on live proof. The Track-A→100% + enterprise wave moved four more rows up on live proof: **image transforms** (36, gate **m95**), **serverless functions** + **cron** to full `[v]` (39/41, gate **m96** — warm pool + per-invoke mem-cap + live cron), and **backups** to a `[+]` differentiator (11, gates **m87**/**m99** — per-tenant granular restore + PITR neither rival ships). The Track-A rc.3 wave (A1 storage DX · A2 functions triggers/cron/secrets/CLI · A3/A4 fluent builder + OpenAPI + Python/Dart SDKs · A5 GraphQL + realtime broadcast/presence) flipped the DX cluster from GAP to PARTIAL, and the **v1.1.0 live-gate wave** then took DB/event triggers (40), function secrets (42) and Auto-GraphQL (26) to full `[v]` (gates **m56**/**m59**). The **OSS gate-debt wave** then took four more DX rows to full `[v]` on live proof: **storage** (33, gate **m55** — bucket·upload·list·byte-round-trip·presigned-URL·owner-isolation), the **fluent query builder** (27, gate **m57** — `.from().query().select().eq().single()` returns the exact row, server-side filtered), and the **Python & Dart SDKs** (50, 47, gate **m58** — install/import clean, 32 ops == the spec). The security audit-ready posture (gate **m60**) and OSS packaging (gate **m61**) are live-proven and annotated on rows 70/75/76 and 59/60/77, but their honest KNOWN-OPEN residuals (no certs; CLI not yet a published binary; no emulator) keep those numbered rows at `[~]`/`[x]` rather than `[v]`.

### Top 8 P0 gaps to close for OSS launch parity

These are the [v]/[~] table-stakes that block a credible OSS self-host launch (full detail in [roadmap-to-market.md](./roadmap-to-market.md), Track A):

| Rank | Row(s) | Gap | Why it's P0 | Effort |
|:----:|--------|-----|-------------|:------:|
| 1 | 33, 34, 36 | ✅ **LIVE (A1, gate m55 PASS)** — createBucket/upload/list/byte-round-trip-download/presigned-URL + owner-isolation all proven end-to-end (row 33 → `[v]`); **residual:** image transforms (row 36) still open | First thing a dev tries; stale README actively misleads | M |
| 2 | 39, 40, 41, 42 | ✅ **LIVE (A2, gate m56 PASS)** — deploy/invoke + DB/event trigger firing (+ cross-tenant no-fire control) + function secrets injection all proven end-to-end; **residual:** cron runner still shadow-mode, warm-pool, lean-default profile | "Edge Functions" is a headline BaaS feature; invoke-only is below table stakes | L |
| 3 | 27, 61 | ✅ **fluent builder LIVE (A3, gate m57 PASS)** — `.from().query().select().eq().single()` returns the exact server-filtered row (row 27 → `[v]`); **residual:** schema→types generation (row 61) still open | Supabase's signature DX; options-object feels foreign | M |
| 4 | 47, 50 | ✅ **LIVE (A4, gate m58 PASS)** — OpenAPI spec + **Python & Dart SDKs install/import clean, 32 ops == spec** (rows 47, 50 → `[v]`); Swift/Kotlin next | (was the single blocker for all multi-language SDKs) | M |
| 5 | 59 | ✅ **dispatch LIVE (A7, gate m61 PASS)** — `baas` CLI builds from source + dispatches real argv subcommands (not a banner; unknown command exits 1); **residual (keeps row 59 `[~]`):** publish as an installed npm/binary + local-dev loop | Both competitors have one; gates functions/codegen DX | L |
| 6 | 17, 20 | **Surface OAuth + MFA in the SDK** (built in binocle-one, not exposed) | Capability exists; only the SDK seam is missing | M |
| 7 | 26 | ✅ **LIVE (A5, gate m59 PASS)** — `graphql_public.graphql()` INVOKER wrapper + `/rpc/graphql` over HTTP, proven incl. two-tenant RLS isolation, served by the opt-in glibc `postgres-graphql` edition; **residual:** ship the extension in the default image (today the lean alpine 5xxs the route) | Frequently a hard requirement; zero impl today | M |
| 8 | — | ✅ **posture LIVE-proven (A6, gate m60 PASS)** — SHIPPED controls hold live (anon→internal 401/42501 · forged JWT 401 · cross-tenant mount 404) + CI security gates wired (gitleaks·cargo-audit·govulncheck·trivy·semgrep·trufflehog·zap) + ASVS/SOC2-lite map; **residual (7 KNOWN-OPEN):** RS256 issuer + per-deployment keys, header-trust/network, no certs | Launch gate; residuals are launch-blockers ([security-audit.md](./security-audit.md)) | M |

> Not P0 but high-leverage for the *cloud* launch (Track B): metering (84), billing/Stripe (83), per-tenant observability (57, 64, 65), tenant self-service dashboard (56, 57). These are the largest net-new build — see [marketability-readiness.md](./marketability-readiness.md) Bar 4.

### Canonical gate numbers for the work this matrix scopes

New gates are numbered **above the shipped m1–m53 range** (never reuse a shipped number). The closing work in [roadmap-to-market.md](./roadmap-to-market.md) maps as:

| Gate | Scope |
|------|-------|
| **m54** | Phase 0 — vs-Supabase benchmark |
| **m55** ✅ PASS | A1 — Storage DX (rows 33→`[v]`, 34): createBucket·upload·list·byte-round-trip download·presigned-URL·owner-isolation(+forged-header reject)·anon-reject |
| **m56** ✅ PASS | A2 — Functions DX (rows 39–42): deploy/invoke · secrets · DB-event trigger firing · **cross-tenant no-fire** · schedule CRUD · forged-header isolation · anon-reject |
| **m57** ✅ PASS | A3 — SDK fluent builder (row 27→`[v]`): live `.from().query().select().eq().single()` returns exact server-filtered row + OpenAPI/route congruence (row 61 type-gen still open) |
| **m58** ✅ PASS | A4 — multi-language SDKs (rows 47, 50→`[v]`): python install/import + dart clean analyze + 32 ops == spec == python == dart |
| **m59** ✅ PASS | A5 — GraphQL live in the graphql edition (row 26): INVOKER wrapper + `/rpc/graphql` over HTTP + **two-tenant RLS isolation** |
| **m60** ✅ PASS | A6 — security audit-ready (rows 70/72–76 posture): live anon/forged-JWT/cross-tenant negatives + CI security gates + ASVS/SOC2-lite map; rows 72–76 stay `[x]`/`[~]` (no certs, 7 KNOWN-OPEN residuals) |
| **m61** ✅ PASS | A7 — OSS packaging (rows 59/60/77 notes): substantive Supabase/Firebase migration guides + `baas` CLI live argv dispatch + one-command Makefile bring-up; row 59 stays `[~]` (CLI not yet a published binary) |
| **m62–m67** | Track B (cloud) — incl. Organizations/teams (row 88 → B4), email deliverability (row 91 → A2/A6 + B) |
| **m68–m71** | Track C (scale/HA) — incl. data residency/region (row 89 → C3) |

Already-shipped gates this matrix cites: **m32** (essential-tier footprint, row 77 / C3 footnote), **m46** (share-pools isolation, rows 79–81 / D2), **m51** (multi-instance rate-limit, row 90).

---

## Sources

**Wiki docs (relative):**
- [marketability-readiness.md](./marketability-readiness.md) · [roadmap-to-market.md](./roadmap-to-market.md) · [grobase-master-plan.md](./grobase-master-plan.md)
- [product-plan/06-saas-multitenancy-quotas-billing.md](./product-plan/06-saas-multitenancy-quotas-billing.md) · [product-plan/09-100k-tenant-path.md](./product-plan/09-100k-tenant-path.md)
- [security-audit.md](./security-audit.md) · [cost-analysis.md](./cost-analysis.md) · [offer-sheet-v2.md](./offer-sheet-v2.md) · [nano-vs-pocketbase.md](./nano-vs-pocketbase.md) · [service-tiers.md](./service-tiers.md)

**Key code anchors (verified for this matrix):**
- Data plane core: `mini-baas-infra/docker/services/data-plane-router/crates/data-plane-core/src/{operation,capability,isolation,mount}.rs` — op set (Insert/Update/Delete/Upsert/Batch/Aggregate), honest capability flags, 4 isolation models, `effective_pool_key`.
- Engine adapters: `.../crates/data-plane-pool/src/{postgres,mysql,mongo,sqlite,mssql,redis,http}.rs` — RLS GUC + owner predicate (`postgres.rs`), identity-stamped `owner_id`/`tenant_id` + tenant-escape guard (`mongo.rs`), honest per-adapter batch (`mysql.rs` atomic, `redis.rs` non-atomic).
- Share-pools: `.../crates/data-plane-pool/src/lib.rs::pools_shared`, `data-plane-core/src/mount.rs::effective_pool_key`; gate `mini-baas-infra/scripts/verify/m46-share-pools-isolation.sh`.
- WAF: `mini-baas-infra/docker/services/waf/Dockerfile` (`FROM owasp/modsecurity-crs:4-nginx-202604040104`) + `conf/{modsecurity,crs-setup,nginx}.conf`.
- SDK: `apps/baas/sdk/src/{index,types}.ts`, `sdk/src/domains/{storage,rest,admin}.ts` (storage = `presign()` only).
- Functions: `mini-baas-infra/docker/services/functions-runtime/src/server.ts` (invoke-only, `TIMEOUT_MS=5000`).
- Studio: `mini-baas-infra/docker/services/studio/Dockerfile` (`FROM supabase/studio:...`, vendored unmodified).
- Codegen blocker: `mini-baas-infra/openapi/` (only `.gitkeep` — spec is empty).
- Benchmark (exists, never run): `mini-baas-infra/scripts/bench/grobase-vs-supabase.sh`.

**Competitor rows:** verified against official Supabase & Firebase docs, 2026.
