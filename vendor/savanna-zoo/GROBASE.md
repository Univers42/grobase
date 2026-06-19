# Savanna Park Zoo on Grobase

`vendor/savanna-zoo` re-platformed onto the **local Grobase BaaS**. Unlike the other vendor apps
(vite-gourmand / Canagrou / MovieVerse), savanna-zoo was **already built for the classic
Supabase-style stack** — GoTrue (`/auth/v1`) + **PostgREST** (`/rest/v1`) + realtime + MinIO storage
— which Grobase exposes natively through Kong. So the re-platform is the **MovieVerse playbook** (app
tables in the shared `public` schema, **role-based RLS via the GoTrue JWT**, no owner column), not the
gourmand data-plane owner-predicate.

## What runs where

| Concern | How |
|---|---|
| **Data API** | PostgREST at `/rest/v1/<table>` (Kong → `postgrest:3000`) — the app's existing client works as-is |
| **Auth** | GoTrue at `/auth/v1` — 5 staff users **+ visitor self-signup** (role=visitor) |
| **RLS (staff)** | role-based via `zoo_jwt_role()` reading the **`app_metadata`** role (server-controlled — see Security) |
| **RLS (tickets)** | **per-user owner-scoping**: `tickets.user_id = zoo_uid()` (the JWT sub); a visitor sees only their own, staff bypass |
| **MongoDB** | the **Visit Journal** (`observations`) on a Mongo mount via the query-router `/query/v1/{dbId}/tables`, owner-scoped per user |
| **Realtime** | Grobase agnostic-realtime **WebSocket** at `/realtime/v1/ws` (was SSE) — see below |
| **Storage** | MinIO via `/storage/v1` (storage-router) — identity-gated (needs a verified GoTrue Bearer) |
| **Schema** | 10 zoo tables + `zoo_audit_log` in `public`; triggers (updated_at, ticket QR, visitor_stats aggregate — SECURITY DEFINER) |
| **Serve** | static `front/dist` behind a same-origin reverse proxy (`grobase/serve.mjs`) → Kong (`/rest /auth /realtime /storage /query`); no CORS |

## Bring it up

```bash
# 1. provision the DB + GoTrue users (run from repo root; passes the real ANON_KEY)
cd vendor/savanna-zoo
ANON=$(grep '^ANON_KEY=' ../../.env | cut -d= -f2)
API_KEY="$ANON" bash infra/init.sh          # tables + seed + RLS + NOTIFY pgrst + 5 GoTrue users

# 2. build the SPA (glibc node image — host node_modules has the glibc rollup binary)
docker run --rm -v "$PWD/front":/app -w /app node:20-bookworm-slim sh -c 'npm run build'

# 3. serve it same-origin (zero-dep serve.mjs proxies /rest /auth /realtime /storage → Kong)
docker run -d --name mini-baas-savanna --network mini-baas_mini-baas \
  -v "$PWD":/app:ro -w /app/grobase -e PORT=80 -e KONG_URL=http://kong:8000 \
  -p 5182:80 node:20-alpine node serve.mjs
# → http://localhost:5182   (NOTE: 5181 is taken by mini-baas-hypertube; savanna uses 5182)

# 4. add the MongoDB plane (Visit Journal): tenant + mbk_ key + savanna-mongo mount
bash ../../scripts/seed/savanna-tenant.sh   # writes VITE_BAAS_MONGO_DBID + VITE_BAAS_APP_KEY into front/.env
#    → then rebuild the SPA (step 2) so it picks up the mongo coordinates, and restart the container
```

Or via the Grobase compose profile: `orchestrators/compose/base/savanna.yml` (`savanna` profile, port
`SAVANNA_PORT` default 5181 — override to 5182 if hypertube holds 5181).

**Staff login** (all password `zoo-admin-2024`): `sophie.laurent@savanna-zoo.com` (admin),
`marcus.osei`/`elena.moreau` (zookeeper), `yuki.tanaka` (vet), `lucas.petit` (reception).
**Visitors** self-sign-up in the app (`/account`) — a demo one is seeded: `visitor@savanna-zoo.com` /
`zoo-admin-2024`. Visitors book tickets (owner-scoped) and keep a private MongoDB Visit Journal.

## Per-user tickets, visitor accounts & the MongoDB Journal

The public Tickets flow used to book **anonymously**, which failed with
`42501 new row violates row-level security policy for table "tickets"`: PostgREST's default
`Prefer: return=representation` reads the inserted row back, but the old `tickets_read` policy was
staff-only, so anon couldn't see its own row. The fix makes tickets **per-visitor**:

- **`infra/004_visitor_accounts.sql`** — `tickets.user_id uuid DEFAULT zoo_uid()` (the JWT `sub`),
  owner-scoped INSERT/SELECT/UPDATE RLS (`user_id = zoo_uid()` OR staff), and the ticket-QR +
  `visitor_stats` triggers promoted to **`SECURITY DEFINER`** so a visitor's booking can still
  aggregate into the admin-only `visitor_stats` table. A visitor now books, sees **only their own**
  tickets (+ QR codes) at `/my-tickets`, and staff (admin/reception) still see all.
- **Frontend** — `auth.signUp` (GoTrue, role=visitor, autoconfirm) + an `/account` page; the Tickets
  page requires a signed-in visitor and books under their JWT; `MyTickets` reads owner-scoped tickets;
  the Navbar is account-aware. The booking Bearer is what stamps `user_id`.
- **MongoDB Visit Journal** — `front/src/baas/mongo.js` talks to a **Mongo mount** through the
  query-router (`POST /query/v1/{dbId}/tables/observations`, ops `insert`/`list`/`delete`) with the
  app key + the visitor Bearer, so the data plane stamps `owner_id=user:<sub>` and owner-scopes reads
  — each visitor's `/journal` shows only their own documents. Provisioned by
  `scripts/seed/savanna-tenant.sh` (tenant + `mbk_` key + `savanna-mongo` mount → the `zoo_app` Mongo
  DB); `serve.mjs` gained a `/query/` proxy prefix.

## Security — every Grobase service tested (`m155`)

`scripts/verify/m155-savanna-security.sh` exercises **each** service and proves the security property it
owns (no vacuous passes): **Kong** (no-apikey → 401, unknown → 404, valid → 200), **GoTrue**
(signup/login/wrong-password/`/user`/JWT/logout), **RLS** (visitor A sees only their ticket, B sees 0
of A's, admin all, anon 0, zookeeper staff-write blocked), **triggers** (QR + visitor_stats),
**realtime** (WS subscribe + write → live EVENT), **storage** (401 without a Bearer, 200 with an admin
identity), and **MongoDB** (query-router insert/list, B can't read A's journal).

An **adversarial 6-surface sweep** (RLS · Mongo · GoTrue/JWT · Kong · storage · realtime) ran on top of
the gate; it found two app-level holes (both fixed) and several platform-level ones (below).

⚠️ **Fix 1 — privilege escalation (`infra/005_secure_roles.sql`).** Adding visitor self-signup exposed a
latent hole: GoTrue's signup `data` lands in **`user_metadata`, which is client-controlled**, and the
original `zoo_jwt_role()` trusted it — so anyone could sign up with `{"data":{"role":"admin"}}` and read
every visitor's tickets + write staff. The fix reads the staff role from **`app_metadata`** (writable
only via the GoTrue admin API / a trusted server-side allowlist), so a forged `user_metadata.role` is
inert. Verified live (m155 §C2): a self-signup `role=admin` now reads 0 tickets and writes 0 staff rows.

⚠️ **Fix 2 — realtime PII broadcast (`infra/006_realtime_privacy.sql`).** Grobase's realtime gateway
fans out row-change events **owner-blind** to any authenticated subscriber, so a visitor could
`SUBSCRIBE pg/tickets/inserted` and harvest every booking's PII (name, email, qr, user_id) over the
WebSocket — even though PostgREST RLS hides those rows. (Confirmed live: a visitor read a victim's ticket
email.) The proper fix is owner-scoped fan-out in the gateway (platform work); the app-level mitigation
ships now: **drop the realtime publish trigger on every non-public table** (`tickets`,
`visitor_messages`, `health_records`, `feeding_logs`, `zoo_audit_log`). Public-by-RLS tables
(`animals`/`events`/`staff`/`ticket_types`/`visitor_stats`, all `SELECT USING(true)`) keep realtime.
Cost: the admin grids for those tables lose live auto-update (fetch-on-load instead). Verified live
(m155 §E2): a visitor subscribed to `pg/tickets/inserted` now receives **nothing**.

**Platform-level findings — now FIXED in Grobase core** (each gated + proven; the cloud/infra ones are
ON, the storage one flag-gated OFF for parity and ON via `make cloud-up`):

| # | Finding | Fix | Gate |
|---|---|---|---|
| F1 | Kong **Admin API** on host `127.0.0.1:8003` leaks the `service_role` key via `/key-auths` | Admin API no longer host-published (internal-only, `gateway.yml`) | `m157` |
| F2 | `GET /admin/v1/databases` + anon key + forged `X-Baas-Tenant-Id` → cross-tenant mount enumeration | Kong **ACL** restricts the adapter-registry admin route to the `service_role` consumer (`kong.yml`) | `m158` |
| F3 | storage `listBuckets` unscoped + visitor bucket-create | flag `STORAGE_BUCKET_SCOPE_ENABLED`: non-privileged → empty list + 403 create (storage-router) | `m159` |
| F4 | GoTrue `/recover` 500-vs-200 differential → user enumeration | bundled **mailpit** SMTP sink → `/recover` returns 200 uniformly (`auth-api.yml`) | `m156` |

## Changes made (the whole re-platform)

- **`infra/001_zoo_tables.sql` + `infra/init.sh`** — renamed `audit_log` → **`zoo_audit_log`**: the shared
  Grobase `public` schema already owns an `audit_log`; the rename stops savanna's RLS/GRANT from
  clobbering it. The other 9 tables don't collide. The frontend never touches the audit table.
- **`front/src/baas/client.js`** — (1) `BASE` falls back to `window.location.origin` when
  `VITE_BAAS_ENDPOINT` is empty (same-origin proxy); (2) **`subscribe()` rewritten from SSE/EventSource
  to the Grobase realtime WebSocket** — topics `pg/<table>/<op>` (`inserted|updated|deleted`; `'*'` →
  all three), protocol `AUTH → AUTH_OK → SUBSCRIBE{sub_id,topic} → EVENT`. The PG producer delivers the
  **full row** in `event.payload.data`, so the existing refetch-on-change hooks light up live.
- **`front/.env`** — `VITE_BAAS_ENDPOINT=` (empty → same-origin) + `VITE_BAAS_API_KEY=<ANON_KEY>`.
- **`grobase/serve.mjs`** — zero-dep static server + same-origin reverse proxy (clone of the gourmand
  one) forwarding `/rest /auth /realtime /storage` to Kong, incl. the realtime WS upgrade.
- **`orchestrators/compose/base/savanna.yml`** — opt-in `savanna` compose profile.
- **`scripts/verify/m154-savanna-zoo.sh`** — the gate: data · RLS roles · QR + visitor_stats triggers ·
  realtime trigger plumbing.

## Why realtime works without polling

Grobase's realtime plane is **independent of the query-router**. Migration `012` installs a
`realtime_notify` trigger on every `public` table (and an event trigger that auto-installs it on any new
`CREATE TABLE`), so a **PostgREST/direct-SQL write** fires `pg_notify('realtime_events', …)`. The Rust
`realtime-db-postgres` producer `LISTEN`s on that channel and republishes each change on
`pg/<table>/<op>` to WebSocket subscribers — full row included.

## Gotchas

- **Port 5181 is taken by `mini-baas-hypertube`** — savanna serves on **5182**. (A container whose host
  port is already bound silently stays in `Created` state; `docker run -d` won't error loudly.)
- **The realtime PG producer does not auto-reconnect.** If `docker logs mini-baas-realtime` shows
  `PostgreSQL connection error: connection closed`, the LISTEN is dead and PostgREST writes stop
  producing events — `docker restart mini-baas-realtime` revives it.
- **Build with a glibc node image** (`node:20-bookworm-slim`), not `node:20-alpine` — the host
  `node_modules` carries the glibc (`-gnu`) rollup native binary; alpine (musl) fails with
  `MODULE_NOT_FOUND` on rollup's `native.js`.
- **The query-router `sort` dialect is `{ field: 'asc' | 'desc' }`, not Mongo's `1`/`-1`.** Sending
  `sort: { created_at: -1 }` to `/query/v1/.../tables/...` passes DTO validation but the **data plane**
  rejects it with `422 data-plane rejected mongodb.<coll>.list`. The read op is **`list`** (not
  `select`); `order:[...]` is rejected (`400 property order should not exist`).
- The app is now **dual-engine**: Postgres/PostgREST for the core + a **MongoDB mount** for the Visit
  Journal (via the query-router). The `model/mongo` schema files remain aspirational/unused; the live
  Mongo collection is just `observations`.
- **Realtime is intentionally OFF for the PII tables** (006) — if an admin grid for tickets/messages/
  feeding doesn't live-update, that's by design (security), not a regression; it refetches on load.

Verified live (Playwright, port 5182): **visitor signup → book → My Tickets (+QR) → MongoDB Visit Journal
(persists across reload) → logout**, plus the original staff/admin flows — **0 console errors**. Security
gate `scripts/verify/m155-savanna-security.sh` green across Kong · GoTrue · RLS · triggers · realtime
(incl. the leak-closed check) · storage · MongoDB.
