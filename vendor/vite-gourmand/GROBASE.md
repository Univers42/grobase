# vite-gourmand on Grobase

vite-gourmand (React/Vite SPA + NestJS/Prisma backend, normally on **Supabase**) re-platformed to run
**entirely on a local Grobase BaaS** — no NestJS server, no Supabase. The React app becomes a **static
SPA** talking directly to the Grobase gateway; the app keeps its **own PostgreSQL schema/data**, run
locally and **mounted into Grobase as an owner-scoped mount** (Grobase supplies the infrastructure, not
the data). Everything is local: no cloud keys, the only thing a human completes is the standard Grobase
`.env` — the app's `View/.env` + `View/public/baas-config.js` are machine-generated.

## What maps to what

| vite-gourmand (NestJS) | On Grobase |
|---|---|
| JWT + bcrypt + CSRF auth, 5 roles | **GoTrue** (`/auth/v1`); role in the JWT drives data-plane admin-bypass |
| Prisma → Supabase Postgres | **owner-scoped Postgres mount** over the app's own DB (`/query/v1/{dbId}/tables`) |
| `/api/*` REST controllers (~268) | the SPA's single chokepoint `View/src/services/api.ts` now **routes** to the gateway; `baas.ts` is the client |
| Order FSM, loyalty ledger, order-number, review moderation, delivery, soft-delete | **Postgres triggers** (`scripts/seed/gourmand-owner-scoping.sql`) — they hold with no app server |
| per-user data ("my orders") + RBAC | **per-row `owner_id`** (stamped/filtered by the Rust data plane) + **shared catalog** (`shared_resources`) + **admin bypass** |
| Unsplash / Google OAuth / Resend email / Mongo analytics / AI agent | dropped/disabled locally (GoTrue handles signup+reset mail); the UI degrades gracefully |

This required porting Grobase's **per-table-shared (F1) + admin-bypass (F2)** authorization from the
MySQL adapter to the **Postgres** adapter (the Postgres read path previously had no SQL owner-scoping —
it relied on RLS GUCs, which the BYPASSRLS mount role ignores). Flag-gated **OFF** by default
(`DATA_PLANE_PER_TABLE_ISOLATION`, `DATA_PLANE_ADMIN_BYPASS`) → byte-parity until flipped ON.

## Run it locally

```bash
# 1) bring the stack up with the authz flags ON (owner-scoping + admin bypass)
DATA_PLANE_PER_TABLE_ISOLATION=1 DATA_PLANE_ADMIN_BYPASS=1 make up

# 2) build the app's local DB substrate (schema + seeds + owner-scoping overlay) and
#    provision the tenant/mount/keys/GoTrue users + emit View/.env & baas-config.js
bash scripts/seed/gourmand-baas.sh

# 2b) (optional) dual-engine: add the MongoDB analytics mount + seed it
bash scripts/seed/gourmand-mongo.sh                # events + menu_views, readable via the gateway

# 3) build the SPA and serve it (static, same-origin proxy to Kong)
docker run --rm -v "$PWD/vendor/vite-gourmand/View":/app -w /app node:20-alpine \
  sh -c 'npm ci && npm run build'
GOURMAND_PORT=5180 docker compose --profile gourmand up -d --no-deps gourmand   # → http://localhost:5180

# verify the Grobase side end-to-end
bash scripts/verify/m149-gourmand-baas.sh
```

> **Always start the SPA service with `--no-deps`** — a bare `docker compose --profile gourmand up`
> reconciles the whole project and can recreate core services with default (conflicting) host ports,
> bypassing `resolve-ports.sh`. `--no-deps` touches only the gourmand container.

**Dual-engine (MongoDB).** vite-gourmand's backend used Mongo for analytics; `scripts/seed/gourmand-mongo.sh`
reproduces that as a second Grobase mount (`gourmand-mongo`, engine `mongodb`) with `events`/`menu_views`
collections. Mongo fails-closed on `tenant_owned`, so the mount is owner-scoped — the script stamps the
seeded docs with the app-key principal + `tenant_id` (discovered live) so the same identity the SPA uses
can read them. `mongoDbId` is appended to `baas-config.js`/`.env`.

Demo accounts (seeded): `admin@gourmand.local` / `employe@gourmand.local` / `client@gourmand.local`,
password `Gourmand#2026`.

## The `.env`

Nothing secret to fill in: after `make up`, all keys (anon, service-role, JWT secrets) already live in
`.env.secrets`; the `mbk_` app key is minted by `gourmand-baas.sh`, which writes `View/.env`
(`VITE_BAAS_URL/KONG_KEY/API_KEY/TENANT_ID/PG_DB_ID`) and `View/public/baas-config.js`
(`window.__BAAS__`). To point at a real Postgres instead of the local substrate, set `GOURMAND_DB_DSN`
before step 2.

## Client-side composition (the query API has no joins)

The query API returns **flat** rows, so the rich nested shapes the NestJS backend returned are
re-assembled in the browser by **`View/src/services/baas-compose.ts`** (a few flat reads + in-memory
maps). `api.ts` is a router that dispatches `/api/*` to GoTrue (`auth/*`), the composers (`site-info`,
`reviews`, `reviews/stats`, `promotions/active`, `menus` with images/dishes/diet/theme), plain-array
lists (`themes`/`diets`/`working-hours`/`notifications`), owner-scoped CRUD (`orders`/`loyalty`/
`support`), and **safe stubs** for dev/external endpoints (`logs`, `tests`, `ai-agent`, `crud`,
`google/config`) so nothing 400s or crashes. Verified with Playwright + a Postman-style sweep: **0
console errors / 0 warnings / 0 network-4xx** across all public **and** authed pages, with live data
(136 menus, 48 reviews, 160 events, 24 promos, Company, 23 users) + 120 Mongo analytics docs.

Gotchas baked into the composer: the data plane **caps a single read at 500 rows** (a higher `limit`
400s — `LIMIT_MAX`); the seed's `MenuImage.image_url` `/img/menus/*.jpg` paths were never bundled, so
they're rewritten to existing `public/` assets; the dev log-stream `EventSource('/api/logs/stream')`
has no Grobase backend and was disabled (it returned `text/html`). Owner-scoped reads (orders, loyalty)
return all rows on the current data plane (no read isolation until the Rust binary is rebuilt with the
F1/F2 flags) — correct data either way.

## Known limitations (faithful by design, not bugs)

- **External integrations dropped locally** (Unsplash, Google OAuth, transactional email, AI agent) —
  re-add as Grobase functions if needed; the router stubs them so the UI degrades cleanly.
- Per-user read **isolation** engages only once the data plane runs with `DATA_PLANE_PER_TABLE_ISOLATION=1
  DATA_PLANE_ADMIN_BYPASS=1` (the m149 gate); writes are already owner-stamped.

## Key files

- Data plane authz: `src/data-plane-router/crates/data-plane-pool/src/postgres/{adapter,tx,filter,query,pool}.rs`
- Schema overlay + triggers: `scripts/seed/gourmand-owner-scoping.sql` (loaded by `scripts/seed/gourmand-local-db.sh`)
- Provisioning: `scripts/seed/gourmand-baas.sh`
- Frontend client + router + composition: `View/src/services/{baas.ts,api.ts,baas-compose.ts}`
- Static serve: `grobase/serve.mjs` + `orchestrators/compose/base/gourmand.yml` (`gourmand` profile)
- Gate: `scripts/verify/m149-gourmand-baas.sh`
