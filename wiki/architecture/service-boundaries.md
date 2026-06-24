# Architecture Rule — Service Boundaries

Authoritative, binding rule for how this product is deployed and where logic lives. It applies to every
app built on grobase (the website portal, vault42, and any future app). The short version: **grobase owns
all state on fly.io; frontends are stateless clients on Vercel; each app is a declarative *provisioning
contract* + a frontend; grobase itself contains zero app-specific code.**

## Stack topology

```
Browser / client
  │
  ├─── Vercel ────────────────────────────────────────────────────────────────
  │    Role    : static assets, frontend logic, edge rendering, same-origin rewrite → grobase
  │    Runtime : serverless, stateless, ephemeral
  │    URL     : *.vercel.app (proto) → custom domain (prod)
  │
  └─── fly.io ────────────────────────────────────────────────────────────────
       Role    : grobase (BaaS) — the GENERIC DATA FACTORY: persistent state, auth, realtime,
                 the database it OWNS and manages (Postgres, ACID/WAL/backups), provisioning
       Runtime : long-lived process(es), persistent volume(s)
       URL     : https://grobase.fly.dev   (vault42 motor: https://vault42.fly.dev,
                 login authority: https://grobase-nano.fly.dev)
```

## Hard boundary rules

**Belongs on fly.io / grobase — never on Vercel:**
- Any logic that reads or writes persistent state.
- The database itself — **grobase owns and manages it.** An app never touches raw storage; it goes through
  grobase. This is what prevents corruption and keeps a single, safe source of truth.
- Auth token issuance and validation; OTP issuance.
- WebSocket / realtime endpoints.
- File / blob handling.
- Background jobs, cron, queues.
- Anything that must survive across requests.

**Belongs on Vercel — never on fly.io:**
- UI components and pages; static assets.
- A **same-origin rewrite/proxy** that forwards `/auth/*`, `/query/*`, … to grobase (so the browser stays
  same-origin — no CORS, the strict CSP stays `connect-src 'self'`, and grobase is never directly
  browser-exposed). This is a *forwarder*, not a Backend-for-Frontend: it holds no state and no business logic.
- Build-time data fetching (SSG/ISR), if applicable.

## The contract — Vercel → grobase

The frontend talks to grobase **exclusively over HTTPS and WebSocket**. No business logic leaks into Vercel.
The frontend is a **pure client**: cut from grobase it renders pages but owns no data and can do nothing.

```
HTTP : https://grobase.fly.dev/auth/v1/*   (GoTrue auth)
       https://grobase.fly.dev/query/v1/*  (owner-scoped CRUD; JSON in/out)
WS   : wss://grobase.fly.dev/realtime/v1/ws (browser → fly directly; never via Vercel)
Auth : Authorization: Bearer <token>        (token issued by grobase, stored client-side)
```

WebSocket connections go **browser → fly.io directly** — Vercel serverless cannot hold persistent
connections. Never route real-time traffic through Vercel.

## CORS / same-origin

Preferred: a **Vercel rewrite** keeps the browser same-origin, so no CORS is needed and the CSP stays
`connect-src 'self'`. Fallback (if calling grobase cross-origin): Kong allows the exact frontend origin via
`KONG_CORS_ORIGIN_*` — proto `https://*.vercel.app`, prod the locked production domain. **Never `*` with
credentials.**

## grobase is a generic, contract-driven factory (no app-specific hardcode)

grobase contains **no references to any specific app** (`grep -ri 'vault42\|website\|nimbus' src/` returns
nothing — keep it that way). Each app is described by a **provisioning contract** — a declarative manifest at
`infra/config/contracts/<app>.json` — and grobase provisions/seeds/manages that app's **isolated** database
from it:

```
app = provisioning contract  +  frontend            grobase = the factory that consumes contracts
```

A contract declares: the tenant + plan, the target database/engine + isolation (`read_scoped` + RLS +
owner-scoping), the schema, seed data, the API keys to mint, and the `PUBLIC_*` config to emit into the
frontend. A **generic provisioner** (`cmd/contract-provisioner`) reads it, builds a `provision.StackSpec`,
calls `POST /v1/provision` (the existing idempotent `Reconciler`), applies the schema, runs the seed, and
emits the frontend config. This replaces the per-app hardcoded `scripts/seed/*-tenant.sh`. Two apps' DBs are
**separate databases** provisioned this way and can **never merge** (per-request owner-scoping + `read_scoped`
+ RLS, plus physical database separation).

> Note: "provisioning contract" (this declarative app manifest) is distinct from vault42's Ed25519 **login
> contract** (issued by the contract authority). Same word, different concept.

## vault42 — the motor, not a datastore

vault42 is the **business-logic motor**: the zero-knowledge secret engine (vault42-server) + the login
authority (vault42-contract). It **connects to grobase as its store** (GrobaseStore → `/query/v1`,
per-owner-scoped, JWT-minted) instead of reinventing its own backend. grobase owns vault42's database the
same way it owns the website's — by contract, isolated, never merged.

## Decision rule for the agent

> "Does this touch state, auth, files, or connections that outlive a single request?"

- **YES →** it goes in grobase (fly.io).
- **NO  →** it can live in Vercel.

If unsure, default to grobase. Pushing stateful logic into Vercel functions is the primary source of bugs and
data loss in this architecture. And: never hardcode an app into grobase — express it as a contract.

## Environment variables

| Variable | Where set | Value (proto) |
|---|---|---|
| `PUBLIC_GROBASE_URL` | Vercel env / emitted by the contract | `https://grobase.fly.dev` (or `''` when using a same-origin rewrite) |
| `PUBLIC_GROBASE_WS_URL` | Vercel env / contract | `wss://grobase.fly.dev` |
| `KONG_CORS_ORIGIN_*` | grobase (fly) | the exact frontend origin (only if cross-origin, not when rewriting) |

Never hardcode URLs in source. Never put fly.io secrets in Vercel env or vice-versa. Each app's `PUBLIC_*`
are **emitted by its provisioning contract**, not hand-written.

## Non-goals

- Vercel is **not** a BFF — grobase owns the API surface; the Vercel rewrite is a forwarder only.
- Do **not** replicate data between services — the single source of truth is grobase.
- Do **not** add a database layer to Vercel — Vercel Blob/KV are out of scope.
- Do **not** hardcode an app's schema/keys/seed into grobase — it lives in the app's contract.
