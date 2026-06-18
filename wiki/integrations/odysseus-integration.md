# Odysseus × osionos × Grobase — unified-product vision & feasibility

> **Status:** research dossier (no code changed). Grounded in the local clone at
> `apps/odysseus` (github.com/pewdiepie-archdaemon/odysseus, *dev* branch) read
> against our `apps/baas` (Grobase), `apps/baas/sdk`, and `apps/osionos/app`.
> **Verdict up front: MODERATE.** The clean win is Odysseus-as-reference-customer
> of Grobase, not a code merge. A real merge is feasible on the *data + tenancy +
> backup* axis (Option A) and forced on the *editor-replacement* axis (Option C).

---

## 0. What each piece actually is (so the vision isn't hand-wavy)

**Odysseus** is a self-hosted, single-tenant-by-default **AI workspace** —
"a self-hosted ChatGPT/Claude UI, with more jank and fun" (`README.md:13`). It is
a FastAPI monolith (`app.py` is **49 KB**, ~60 route modules in `routes/`) over a
**SQLAlchemy** store that defaults to **SQLite** (`core/database.py:34`,
`DATABASE_URL` overridable but no Postgres driver is shipped — see §3) with
**ChromaDB** for vectors (`docker-compose.yml:73`, `requirements.txt:18`). Its
surface: chat/agents, model management (Cookbook), deep research, compare,
**documents/notes/editor/gallery**, email (IMAP/SMTP), calendar (CalDAV), memory &
skills, scheduled tasks, MCP tools. Its own auth world: **bcrypt passwords +
file-based 7-day session tokens** (`core/auth.py:496-514`, `data/sessions.json`) +
scoped **`ody_` bearer API tokens** (`routes/api_token_routes.py:129`,
`app.py:322`). **Every owner-bearing table carries an `owner` (username) column**
(`core/database.py` — `Session.owner:97`, `Document.owner:209`, plus the
multi-user backfill `_migrate_assign_legacy_owner:1186`). Threat model: *trusted
users on a private network, treat it like an admin console* (`THREAT_MODEL.md:7`).

**Grobase / mini-baas** is our engine-agnostic BaaS: a REST/`/query/v1` surface
over **5 live engines** — postgresql, mongodb, mysql, redis, http (the live
`ENGINE_CAPS` catalog in `apps/baas/sdk/src/generated/engines.ts:28-31`; **sqlite
and mssql appear in the *tier* matrix** `config/packages/packages.json:16,37,79,100`
**but are not in the live multi-engine query-router catalog**). Four isolation
strategies; the code enum is `shared_rls` (default) / `schema_per_tenant` /
`db_per_tenant` (`go/control-plane/internal/tenants/models.go:137-139`), plus the
runtime `SHARE_POOLS` toggle. A mount is one connection; its DSN is **encrypted
AES-256-GCM at rest by the adapter-registry** (`provision.go:17-18`). The full
control plane ships in **`@mini-baas/js`** (`apps/baas/sdk/src/index.ts:182-256`:
`auth · query · rest · txn · schema · functions · graphql · realtime · webhooks ·
admin/tenants/provision · account` self-service).

**osionos** is our block editor. It already has a **live-database mode**: any
registered BaaS mount table renders as an editable `database_full_page` block with
id **`baas:<dbId>:<table>`**, discovered via `GET /admin/v1/databases` (tenant
header) or the `VITE_BAAS_LIVE_MOUNTS` env fallback
(`apps/osionos/app/src/widgets/database-view/model/liveMountCatalog.ts:67-96`),
with reads + outbox-backed writes through one memoized adapter per id
(`liveDatabaseAdapter.ts:43-50`). The end-to-end mechanics are documented in
`apps/baas/wiki/osionos-real-data-guide.md`.

---

## 1. The unified product vision

> **"Grobase Studio" — a self-hosted, multi-tenant AI workspace where every
> user's chats, documents, notes, gallery, email and calendar live on *one*
> engine-agnostic backend, the prose surfaces are osionos blocks, and tenancy,
> isolation, backup and metering ride Grobase."**

Concretely, the merged product would be:

- **The face is Odysseus's workspace** — the thing nobody else in our stack has:
  chat with any local/remote model, agents with tools, deep research, model
  Cookbook. That is the *demand-side* hook. We have no AI/LLM layer anywhere
  (osionos is an editor; Grobase is a data plane). Odysseus brings it for free.
- **The spine is Grobase** — Odysseus stops being single-SQLite-file and becomes a
  Grobase tenant. Its relational tables (sessions, documents, notes, calendar,
  memory metadata) live in a Grobase-managed Postgres mount under one isolation
  model; backup/restore stops being a JSON dump (`routes/backup_routes.py:18`) and
  becomes Grobase's provisioning + DSN-encrypted mounts; **multi-tenancy** stops
  being a bolted-on `owner` column and becomes Grobase's RLS/owner-scope per
  request — the exact thing Odysseus reinvented table-by-table.
- **The prose is osionos** — Odysseus's `Document` (markdown + version history,
  `core/database.py:191`) and `Note` surfaces are replaced/federated by osionos
  blocks, giving Odysseus a real WYSIWYG block editor (its own roadmap literally
  asks for this: *"Expand the Editor for quicker, more robust everyday use"*,
  `ROADMAP.md:58`) and giving osionos a flagship embedding context.

**Is this compelling or forced?** *Compelling at the seams, forced at the core.*
The compelling part is the data/tenancy/backup layer — Odysseus has hand-rolled a
weak version of exactly what Grobase sells (per-row `owner`, file backup, no real
isolation), and it openly wants help there (`THREAT_MODEL.md:81` "token scopes are
coarse"; `ROADMAP.md:75` "backup/restore guide"). The forced part is welding two
*frontends* (a vanilla-JS SPA of 84 JS files in `static/js/` + an inline-style
`index.html`, vs. our React/Vite osionos): you don't "merge" those, you pick one
shell and embed the other. **The honest framing is a one-directional integration:
Odysseus becomes a Grobase tenant and an osionos host — not a symmetric merge.**

---

## 2. Integration architecture — three options, ranked

### Option A — Odysseus's relational store → a Grobase-managed Postgres mount, surfaced in osionos *(RECOMMENDED, MODERATE)*

**Idea.** Point Odysseus's `DATABASE_URL` at a Postgres database that Grobase
provisions and owns as a mount; surface the same tables in osionos via the live
`baas:<dbId>:<table>` block; let Grobase own backup, tenancy and (later) metering.

**Mechanism (real, from the code).**
- Provision a tenant + a Postgres mount whose `connection_string` is the DB
  Odysseus will use: `MountSpec{Engine:"postgresql", ConnectionString:"postgres://…",
  Isolation:"shared_rls"|"schema_per_tenant"}` (`models.go:140-145`,
  registered via `provision.go:43-49`, DSN encrypted AES-256-GCM
  `provision.go:17-18`). This is the "wrap a customer's own DB" path — what the
  root `CLAUDE.md` Live-Database Demo already does for pg-commerce/mysql-ops/
  mongo-activity, owner-stamped with `api-key:<key uuid>`.
- Set `DATABASE_URL=postgresql://…` in Odysseus (`docker-compose.yml:34`,
  `core/database.py:34-40`). SQLAlchemy is dialect-agnostic; the engine line
  already branches on `"sqlite" in DATABASE_URL` (`database.py:39`).
- osionos points `VITE_BAAS_LIVE_MOUNTS` at the mount's `{dbId, table}` set; the
  `documents` / `notes` / `sessions` tables render as `database_full_page` blocks
  (`liveMountCatalog.ts:79`, real-data-guide §2).

**Changes on each side.**
- *Odysseus:* (1) add a Postgres driver — `psycopg`/`asyncpg` is **NOT** in
  `requirements.txt` today (verified: no postgres/psycopg/asyncpg entries), so the
  overridable `DATABASE_URL` is theoretical until a driver ships. (2) Its
  ~25 hand-rolled `_migrate_*` functions in `core/database.py` are **raw `sqlite3`
  + `PRAGMA table_info`** (e.g. `:681,:750,:1098`) — they no-op or break on
  Postgres; the schema-create path must move to SQLAlchemy `create_all` / Alembic.
  (3) The `EncryptedText` Fernet columns (`database.py:58`) keep working (app-level,
  engine-agnostic).
- *Grobase:* nothing new structurally — this is a `tenant_owned`-style external
  mount. Optionally a `schema_per_tenant` mount if Odysseus is multi-tenanted.
- *osionos:* config only (`VITE_BAAS_LIVE_MOUNTS`), zero code — the adapter is
  generic over any mount table.

**What's reused:** all of Grobase (provision, RLS, DSN encryption, backup-by-
provisioning, future metering); all of osionos's live-DB block; all of Odysseus's
backend logic *above* the ORM.

**Auth bridge:** weakest coupling — Odysseus keeps its own auth; Grobase sees a
single service principal (the mount's api-key). osionos reads with its tenant
key. Owner-scoping is doubled (Odysseus's `owner` column + Grobase's RLS), which
is belt-and-suspenders, not a conflict.

**Why it ranks #1:** smallest, most reversible, flag-gated-off-able slice that
delivers the marquee value (Grobase owns Odysseus's data + backup + tenancy) and
demonstrates the live-DB block on a *real third-party app's* tables.

### Option B — front Odysseus's FastAPI as an `http` mount *(EASY but SHALLOW)*

**Idea.** Register Odysseus as an `http` engine mount (the 5th live engine,
`engines.ts:32` http caps) so Grobase/osionos can read Odysseus surfaces through
the uniform `/query/v1` API without touching Odysseus's storage.

**Mechanism.** An `http` mount maps `op:list/get/insert/...` onto Odysseus's
existing REST routes (`/api/documents/library` `document_routes.py:263`,
`/api/notes`, etc.). Odysseus already speaks scoped bearer auth
(`app.py:322` `Bearer ody_…`), so the mount's stored credential is an `ody_`
token with the right scopes (`documents:read`, `documents:write`, …
`api_token_routes.py:15-30`).

**Changes:** Grobase needs an `http`-adapter mapping per Odysseus route shape
(read-mostly is trivial; writes need request-body templating). Odysseus:
**zero** — it's already an HTTP API with scoped tokens. osionos: config only.

**Trade-off:** no real merge of *data* — Odysseus's store stays SQLite, Grobase
gains no ownership of it, backup/tenancy/metering stay Odysseus's problem. Good
for a fast read-through demo ("osionos shows your Odysseus documents") but it
doesn't advance the enterprise story. Best as a **stepping stone to A**.

### Option C — embed osionos as Odysseus's document editor *(HARD, highest product payoff)*

**Idea.** Replace Odysseus's markdown/HTML/CSV multi-tab editor (its `Document`
model + the `static/js/` editor) with osionos blocks; an Odysseus document
becomes an osionos page (`database_full_page` or a block tree).

**Changes on each side.**
- *Odysseus:* deprecate the `Document`/`DocumentVersion` markdown model
  (`database.py:191-236`) as the *editor* surface; the AI-edit tools
  (`src/agent_tools/document_tools.py`, referenced `document_routes.py:111,646`)
  must learn the osionos block AST instead of markdown strings — this is the
  expensive part (the agent currently round-trips *markdown text*; osionos is a
  block document model). Version history must map to osionos's own versioning.
- *osionos:* mount as an embeddable surface inside Odysseus's SPA (iframe or a
  packaged React island). Odysseus's CSP is **nonce-based** with
  `frame-ancestors 'none'` on normal pages (`middleware.py:109,116-126`); it
  already carves a `frame-ancestors 'self'` exception for embedded PDF previews
  (`middleware.py:102-107`) — so framing osionos is precedented but needs a CSP
  carve-out + nonce wiring (osionos's own CSP is strict-hashed; cross-origin
  embedding is non-trivial — see `wiki/SECURITY.md`).
- *Auth bridge:* the hard one — the embedded osionos needs a Grobase session,
  Odysseus has its own. Either Odysseus mints a Grobase tenant key per logged-in
  user and hands osionos `VITE_BAAS_*` at frame-load, or both adopt a shared
  identity (our GoTrue/JWT). The cleanest is: **A first** (data already in
  Grobase), then C reads/writes that data — so the editor and the AI agent share
  one Grobase-backed source of truth.

**Why it ranks #3:** biggest UX payoff (Odysseus gets a real block editor; osionos
gets the flagship AI host) but the costliest — it touches the AI agent's document
contract, two CSPs, and the auth bridge simultaneously. Do it *after* A proves the
data spine.

**Ranking:** **A (do first) → B (cheap demo / bridge) → C (the prize, last).**

---

## 3. What merges cleanly vs what clashes

| Concern | Clean / Clash | Detail (with citations) |
|---|---|---|
| **Relational data** | ✅ clean (Option A) | SQLAlchemy is dialect-agnostic; `DATABASE_URL` already overridable (`database.py:34`). Postgres is our #1 live engine. |
| **Owner / tenancy model** | ⚠️ mostly clean | Odysseus per-row `owner` username (`database.py:97,209`) maps onto Grobase owner-scope/RLS; doubling is harmless. Clash only if we want Grobase RLS to be the *sole* gate — Odysseus's owner filters are app-level, not DB-level. |
| **SQLite migrations** | ❌ clash | ~25 `_migrate_*` use raw `sqlite3`+`PRAGMA` (`database.py:681…1257`); they don't run on Postgres. Must move to `create_all`/Alembic. **No PG driver shipped** (not in `requirements.txt`). |
| **Auth** | ❌ clash | Two universes: Odysseus bcrypt + file sessions + `ody_` tokens (`auth.py`, `app.py:322`) vs. our GoTrue/JWT + tenant api-keys. No shared identity today. Option A sidesteps it (service principal); Option C forces a bridge. |
| **ChromaDB / vectors** | ❌ no Grobase home | ChromaDB is a separate service (`docker-compose.yml:73`) for RAG/memory/skills (`requirements.txt:18`, `mcp_servers/rag_server.py`). Grobase has **no vector engine** in the live catalog (no pgvector mount, no vector caps in `ENGINE_CAPS`). Either keep ChromaDB beside Grobase, or add a pgvector mount (real work). |
| **AI / LLM layer** | ➖ no overlap (additive) | Odysseus's chat/agent/Cookbook (`routes/chat_routes.py`, `model_routes.py` 2266 lines, `src/llm_core`, `endpoint_resolver`) is a **model proxy** over `ModelEndpoint` rows (`database.py:333`). **We have no equivalent** anywhere in the stack — pure gain, but it stays Odysseus-side; nothing to merge, everything to inherit. |
| **Document model** | ❌ clash (Option C) | Odysseus `Document` = markdown/HTML/CSV string + linear `DocumentVersion` history (`database.py:191-236`); osionos = block AST. The AI-edit tools speak markdown — re-targeting them to blocks is the real cost. |
| **Backup** | ✅ clean win | Odysseus backup = a single JSON of memories/presets/settings/skills (`backup_routes.py:43-60`) — *documents/sessions/notes aren't even in it*. Grobase provisioning + DSN-encrypted mounts is a strictly better backup story. |
| **Desktop / offline** | ⚠️ partial | Both want local-first. Odysseus runs native (`README.md:76`) or Docker; osionos has native/local Electron editions. A merged "Grobase Studio Desktop" is plausible but is a third packaging effort, not a merge. Electron IPv4 gotcha applies (root `CLAUDE.md`: `net.fetch` → `127.0.0.1`). |
| **Extensibility / plug-in seam** | ✅ clean | Odysseus already exposes scope-gated agent APIs + a Claude Code skill bundle (`integrations/claude/README.md`) and MCP servers (`mcp_servers/`). An "external backend" plugs via `DATABASE_URL` (A) or `ody_` scoped tokens (B) — both first-class. |
| **Docker shape** | ✅ compatible | Odysseus compose = odysseus+chromadb+searxng+ntfy, binds `127.0.0.1` (`docker-compose.yml`). Drops into our Docker-first world as one more profile; **keep all Docker work on `/mnt/storage`** (project rule). |

---

## 4. Feasibility verdict

**MODERATE.** A real *data-spine* merge (Option A) is buildable in days, not
weeks, and is reversible/flag-gated. A *full product merge* (A+C, shared identity,
osionos as the editor, vectors homed in Grobase) is a multi-month program and
crosses the AI-agent document contract + two CSPs + an auth bridge.

**Top 3 enablers**
1. **osionos already renders any Grobase mount table** as an editable block
   (`liveMountCatalog.ts` / `liveDatabaseAdapter.ts`) — the hardest UI piece exists.
2. **Odysseus's `DATABASE_URL` is overridable** and SQLAlchemy is dialect-agnostic
   (`database.py:34`); Postgres is our flagship engine — Option A is "wrap an
   external DB," exactly the `tenant_owned`/Live-Database-Demo path we already run.
3. **Zero AI-layer overlap** — Odysseus brings the entire LLM/agent/Cookbook
   surface we lack; it's additive, not conflicting (`chat_routes.py`,
   `model_routes.py`, `src/llm_core`).

**Top 3 blockers**
1. **Two auth universes with no shared identity** (Odysseus bcrypt+file-sessions+
   `ody_` tokens vs. our GoTrue/JWT+tenant keys) — Option C can't ship without a
   bridge; `THREAT_MODEL.md:81` already flags Odysseus's scopes as coarse.
2. **SQLite-bound schema management** — ~25 raw-`sqlite3` `_migrate_*` functions
   plus **no Postgres driver in `requirements.txt`**; Postgres needs a driver add +
   Alembic/`create_all` migration before A is real.
3. **ChromaDB/vectors have no Grobase home** — RAG/memory/skills depend on a vector
   store our live catalog doesn't offer (no pgvector mount); a full merge must
   either keep ChromaDB external or build the vector engine.

---

## 5. Smallest provable first slice (Option A, read-only, reversible)

Goal: **prove Odysseus's documents render as osionos live-DB blocks off a
Grobase-managed Postgres mount** — no auth bridge, no editor replacement, flag-off-able.

```bash
# 0. From repo root — all Docker work on the big disk (project rule)
sudo install -d -o $USER /mnt/storage/odysseus-demo   # one-time

# 1. Bring up the BaaS query edition (our orchestrator, never raw compose)
cd apps/baas/mini-baas-infra
make up EDITION=query

# 2. Provision a tenant + an EMPTY external Postgres mount Odysseus will fill.
#    (Use the same provision path the Live-Database Demo uses; SDK/admin or the
#    control-plane POST /v1/tenants ... mounts:[{engine:postgresql, name:"odysseus",
#    connection_string:"postgres://…/odysseus", isolation:"shared_rls"}].)
#    Capture the returned mount id (dbId) and api key.

# 3. Point Odysseus at that Postgres DB + add a driver.
cd ../../../apps/odysseus
echo 'DATABASE_URL=postgresql+psycopg://USER:PASS@HOST:5432/odysseus' >> .env
#    add `psycopg[binary]` to requirements.txt (NOT shipped today), then:
docker compose up -d --build odysseus chromadb
#    Create a doc in the UI so `documents`/`document_versions` tables exist + fill.

# 4. Surface those tables in osionos via the env fallback (no /admin call needed).
#    apps/osionos/app/.env:
#    VITE_BAAS_URL=http://127.0.0.1:8000
#    VITE_BAAS_LIVE_MOUNTS=[{"dbId":"<mount-id>","name":"odysseus","engine":"postgresql"}]
#    Open the live block id  baas:<mount-id>:documents  → Odysseus docs as a grid.
```

**Pass criteria:** an Odysseus document written through Odysseus's own UI appears,
read-only, as rows in an osionos `database_full_page` block, served by Grobase off
the external Postgres mount. That single screenshot proves the data spine. (Writes,
owner-scope reconciliation, and the AI-edit→block re-targeting come *after*.)

**If the PG-driver lift is unwanted for a first look:** do **Option B** instead —
register Odysseus as an `http` mount with a scoped `ody_` token and read
`/api/documents/library` through `/query/v1`. Even cheaper, but proves less.

---

## 6. Is this worth doing? (strategic take)

Our stated mission is *the best self-hostable BaaS, growing toward managed-cloud /
enterprise-B2B* (kernel `apps/baas/.claude/CLAUDE.md`). Measured against that:

- **As a *merge*, the ROI is asymmetric.** Grobase + osionos give Odysseus a real
  data spine, real tenancy, real backup, and a real editor — Odysseus gets a lot.
  Grobase gets one more consumer and an AI face it doesn't have. But the AI face
  arrives welded to a 49 KB FastAPI monolith + vanilla-JS SPA + ChromaDB on a
  *"treat it like an admin console, trusted network only"* threat model
  (`THREAT_MODEL.md:7`) with acknowledged gaps (no shell sandbox, SSRF via
  `base_url`, coarse scopes — `THREAT_MODEL.md:71-81`). Absorbing that into a
  product we want to sell to enterprises imports security debt we'd have to own.

- **The genuinely valuable, low-risk move is Odysseus as a *reference customer*,
  not a merge.** Odysseus is a near-perfect Grobase case study: a real, popular,
  multi-feature self-hosted app that *reinvented the exact things we sell*
  (per-row `owner` instead of RLS; JSON-file backup instead of provisioning;
  coarse `ody_` scopes instead of ABAC). Porting it onto Grobase via **Option A**
  produces a credible "we wrap your existing app's database, give you isolation +
  backup + a live editor, and you change two env vars" demo — which is *exactly*
  the managed-cloud pitch — **without** us inheriting its AI/agent attack surface.

- **The AI layer is the one thing worth coveting**, and the cheapest way to get it
  is *not* to merge the monolith but to let Odysseus keep running as a tenant whose
  data we host (A) and whose surfaces we can embed (C later). We benefit from its
  AI without owning its security posture.

**Recommendation:** pursue **Option A as a reference-customer integration**
(Grobase hosts + backs up Odysseus's data; osionos surfaces it), keep **B** in
the back pocket as the cheap read-through demo, and treat **C** (osionos-as-
Odysseus-editor + shared identity + vector home) as an aspirational Track that we
only fund once A has proven the spine and the auth bridge is designed deliberately.
A symmetric "one product" merge is *possible* but **forced** — the compelling
story is "Grobase makes your self-hosted AI workspace enterprise-grade," and that
story is told by integration, not by fusion.

---

### Appendix — files read (both repos)

*Odysseus:* `README.md`, `ROADMAP.md`, `THREAT_MODEL.md`, `SECURITY.md`,
`core/database.py`, `core/auth.py`, `core/middleware.py`, `app.py` (auth/token
bridge §57-366), `routes/document_routes.py`, `routes/note_routes.py`,
`routes/editor_draft_routes.py`, `routes/api_token_routes.py`,
`routes/backup_routes.py`, `routes/chat_routes.py` (head), `mcp_servers/`,
`integrations/claude/README.md`, `docker-compose.yml`, `Dockerfile`,
`requirements.txt`.
*Ours:* `apps/baas/sdk/src/index.ts`, `apps/baas/sdk/src/generated/engines.ts`,
`apps/baas/mini-baas-infra/go/control-plane/internal/tenants/{provision.go,models.go}`,
`apps/osionos/app/src/widgets/database-view/model/{liveMountCatalog,liveDatabaseAdapter}.ts`,
`apps/baas/wiki/osionos-real-data-guide.md`, `config/packages/packages.json`,
root `CLAUDE.md` (Live-Database Demo).
