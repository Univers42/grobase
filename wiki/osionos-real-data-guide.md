# Working with real data on the BaaS — a guide for the osionos team

This is the practical, end-to-end guide for putting **real osionos data** into the
BaaS and reading it back as a **cross-database graph**. Everything here is
**live-verified** against the deployed `graphdemo` tenant. Companion contracts:
[graph-contract.md](./graph-contract.md) (read), [txn-contract.md](./txn-contract.md)
(atomic writes).

---

## 1. The mental model (one paragraph)

A **mount** is one database connection (one engine). A **node** is one row/record
in a mount; its global id is **`NodeId = <mountId>:<resource>:<pk>`** (e.g.
`e6eb87db-…:og_nodes:n1`). An **edge** is just a row in a dedicated *edges* mount
with `from`/`to` `NodeId`s — so a **cross-database link is simply an edge whose two
endpoints live in different mounts** (no foreign keys, which can't cross databases).
You **write** rows/edges through `/query` or `/txn`; you **read** the assembled
graph through `/graph` and `/graph/overview`. That's the whole system.

---

## 2. The `graphdemo` tenant — your mounts

| Engine | `dbId` (mount) | Use for | Transactions? | Notes |
|---|---|---|---|---|
| **Postgres** | `e6eb87db-3fc6-4ae8-bda2-10e9a436dbe9` | the bulk: products, tasks, projects, content, inventory; **the `edges` mount** | ✅ yes | `og_nodes`, `og_edges`, `og_overlays` |
| **MySQL** | `f0016d68-dd0d-4ec6-9997-310974e12574` | a second relational backend | ✅ yes | `og_users` |
| **MongoDB** | `ca660785-ccc3-48b9-92fd-a47c7a863923` | document data, e.g. CRM **people** | ❌ **no** | `og_people` — **use `/query` insert, not `/txn`** |
| **Redis** | `99d0dfd0-d18d-4f3e-a0b3-50d93bb92305` | (test mount) | ❌ no | — |

> The **edges mount** should be the **same mount as the nodes you want to edit
> atomically** (see §5). The fixture keeps `og_edges` in Postgres.

**Cross-database is real here:** put product/task nodes in Postgres, people in
Mongo, and an edge `pg:og_nodes:task-7 → mongo:og_people:p1` (type `Client`) — the
graph stitches them into one view.

---

## 3. Auth + env (already staged in your `.env`)

Every call needs **two headers**: the per-tenant key, and (through Kong) the anon
key. Your client already does this.

```
VITE_BAAS_URL=http://127.0.0.1:8000          # Kong gateway root; client appends /query/v1/...
VITE_BAAS_API_KEY=mbk_…                       # → X-Baas-Api-Key (per-tenant)
VITE_BAAS_KONG_KEY=eyJ…(anon JWT)             # → apikey (Kong key-auth)
VITE_BAAS_EDGES_DB_ID=e6eb87db-…             # the edges mount
VITE_BAAS_EDGES_TABLE=og_edges
VITE_BAAS_GRAPH_RESOURCES=[{"dbId":"e6eb87db-…","table":"og_nodes"},
                           {"dbId":"f0016d68-…","table":"og_users"},
                           {"dbId":"ca660785-…","table":"og_people"}]   # ← add Mongo here
```

> **Port note:** the gateway is on `127.0.0.1:8000`, but the Makefile allocates
> ports dynamically — if a call can't connect, check `docker port mini-baas-kong
> 8000/tcp`. CORS already allows `http://localhost:3001` + the `X-Baas-Api-Key`
> header, so in-browser BaaS mode works over plain http.

---

## 4. Writing single rows — `POST /query/v1/<dbId>/tables/<resource>`

```jsonc
// insert (the workhorse for bulk loading)
{ "op":"insert", "data": { "id":"task-7", "title":"Ship v2", "status":"open" } }

// update (only rows you own — see §6)
{ "op":"update", "filter": { "id":"task-7" }, "data": { "status":"done" } }

// delete
{ "op":"delete", "filter": { "id":"task-7" } }

// upsert — REQUIRES `filter` naming the conflict key AND a UNIQUE(owner_id, key)
// index on the table (the fixture's og_nodes/og_edges/og_overlays now have it):
{ "op":"upsert", "filter": { "id":"task-7" }, "data": { "id":"task-7", "title":"…" } }
```

Reads on the same endpoint: `{ "op":"list", "filter":{…}, "limit":500, "sort":{…} }`
(limit max **500**), `{ "op":"get", "filter":{"id":"…"} }`, and **aggregate** (§7).

### The rules that bite (all verified)

- **`owner_id` is server-injected.** Every insert is stamped with your identity as
  `owner_id`. You can only `update`/`delete` rows you own — that's deliberate.
- **A no-op is `201`, not an error.** An `update`/`delete` matching nothing returns
  `201` with **`rowCount: 0`**. If you do optimistic UI, **revert on
  `rowCount === 0`**, not only on HTTP error.
- **`409 Conflict`** = integrity violation (dup PK/unique, FK, not-null), with the
  real reason (`duplicate key value violates unique constraint "…"`). Rolled back.
- **`upsert` needs a `UNIQUE(owner_id, <key>)` index.** Without it you get a `502`
  (`ON CONFLICT` has no matching index). Either add that index, or just use
  `insert` for new rows + `update` for existing (the simplest bulk pattern).
- **Idempotency:** pass `idempotencyKey` (or the `Idempotency-Key` header) on writes
  that may be retried.

---

## 5. Writing atomically — `POST /query/v1/txn`

One backend transaction, all-or-nothing, **single mount**:

```jsonc
{ "mount":"e6eb87db-…",
  "operations":[
    { "op":"update", "resource":"og_nodes", "filter":{"id":"n1"}, "data":{"title":"…"} },
    { "op":"insert", "resource":"og_edges", "data":{"id":"e9","from":"…","to":"…","type":"link"} }
  ] }
→ 201 { "guarantee":"atomic", "results":[ {op,resource,rowCount}, … ] }
```

- **Transactional engines only** (`postgresql`/`mysql`). On **Mongo/Redis** you get
  `400 "engine '<e>' does not support requested capability 'transactions'"` — use
  plain `/query` inserts there (see §8).
- **No cross-mount atomicity** (that's 2PC, not offered). To edit a node + its edges
  atomically, keep them in the **same mount**.
- Same `rowCount`/`409` semantics as §4. Keep batches small (txn TTL ≈ 30s).

---

## 6. Per-engine specifics (so reads/writes line up)

- **Postgres** — reads rely on RLS; on a table with no RLS policy, `list` returns
  all rows. Writes (`update`/`delete`) are owner-scoped. The edges mount lives here.
- **MySQL** — **reads are always `owner_id`-scoped.** A row is only readable if you
  own it → **write `og_users` rows through the api-key** (never side-load via the
  mysql client), so `owner_id` is set to you.
- **MongoDB** — **non-transactional** (use `/query` insert, not `/txn`). Collections
  auto-create on first insert. Your **logical `id` round-trips** (the adapter no
  longer overwrites it with Mongo's `_id`), so a doc written as `id:"p1"` reads back
  as `id:"p1"` and connects to edges referencing `…:og_people:p1`.

---

## 7. Reading the graph

```jsonc
// Whole-vault view (the initial render) — bounded, focus-less:
POST /query/v1/graph/overview
{ "resources":[ {"dbId":"<pg>","table":"og_nodes"}, {"dbId":"<mongo>","table":"og_people"} ],
  "edgesDbId":"<pg>", "edgesTable":"og_edges", "limit":500,
  "generators": { "noteField":"body", "tags":{"field":"tags","mount":"<pg>","resource":"tags"} } }

// Local neighbourhood (expand on double-click):
POST /query/v1/graph
{ "focus":"<pg>:og_nodes:n1", "depth":1, "edgesDbId":"<pg>", "edgesTable":"og_edges" }
```

Both return `{ focus?, depth, nodes[], edges[], guarantee }`. **Generators** derive
extra edges from node data (`note_link` from `[[NodeId]]`, `tagged` from a string
array, references from a scalar field) — see graph-contract.md §3.1. **Guarantee**
is `per_node_atomic` (single read) or `subgraph_eventual` (multi-read across mounts;
treat as possibly-slightly-stale — never imply a global snapshot).

**Aggregations** (now exposed through the gateway): `op:"aggregate"` for
COUNT/SUM/AVG/MIN/MAX + GROUP BY — e.g. nodes per resource, edges per type:

```jsonc
{ "op":"aggregate", "filter":{…}, "aggregate":{ "groupBy":["type"],
  "aggregates":[ { "func":"count", "alias":"n" } ] } }
```
It respects the same `filter`/scoping as `list`.

---

## 8. Bulk-loading real data (the sync pattern)

What `sb-sync-osionos.ts` does, generalised:

1. **Route by engine.** Bulk relational rows → Postgres `og_nodes`; the second
   relational set → MySQL `og_users`; document/people → **Mongo `og_people`**;
   every relation property → the **edges mount** (`og_edges`, real types like
   `Project`, `Client`, `Tasks`, `Related Assets`).
2. **Batch the writes.** On Postgres/MySQL, group inserts into `/txn` batches
   (atomic per mount). On **Mongo, send plain `/query` inserts** (no `/txn`).
3. **Make it idempotent.** `--clean` (delete the tenant's rows) then insert; or use
   `upsert` (now that the fixture has the `UNIQUE(owner_id,id)` index).
4. **Use logical ids** everywhere (`task-7`, `p1`) — they become the NodeId pk and
   are what edges reference. (Mongo logical ids now round-trip; §6.)

### The Postgres + MongoDB split (your 2-line change)

Point the **people** set at the Mongo mount instead of MySQL:

```ts
const MOUNTS = {
  postgres: "e6eb87db-3fc6-4ae8-bda2-10e9a436dbe9",
  mongo:    "ca660785-ccc3-48b9-92fd-a47c7a863923",   // ← new
  edges:    "e6eb87db-3fc6-4ae8-bda2-10e9a436dbe9",
};
// CRM contacts → Mongo `og_people` via PLAIN /query insert (mongo ≠ transactional)
await baasInsert(MOUNTS.mongo, "og_people", contact);   // not /txn
// relation: pg node → mongo person, edge into the edges mount
await baasInsert(MOUNTS.edges, "og_edges",
  { id, from:`${MOUNTS.postgres}:og_nodes:${taskId}`, to:`${MOUNTS.mongo}:og_people:${contactId}`, type:"Client" });
```

Add `{"dbId":"ca660785-…","table":"og_people"}` to `VITE_BAAS_GRAPH_RESOURCES` and
the overview renders a genuine **Postgres + MongoDB** graph. *(Verified live: a PG
node and a Mongo person connect across backends in `/graph/overview`.)*

---

## 9. Honest limits (don't design around what we don't offer)

- **No cross-mount atomicity** (no 2PC). Co-locate rows that must be written atomically.
- **No cross-database joins.** The graph is N scoped reads; render local + expand,
  or use the bounded `/graph/overview` (samples `limit` rows per resource).
- **Consistency is tiered and reported** (`guarantee`). Surface it; never claim a
  global atomic snapshot across engines.
- **Mongo/Redis/HTTP are non-transactional** and won't accept `/txn`.

---

## 10. Quick reference

- Gateway: `http://127.0.0.1:8000` → `/query/v1/<dbId>/tables/<resource>` (CRUD +
  aggregate), `/query/v1/txn` (atomic batch), `/query/v1/graph[/overview]` (read).
- Mounts: PG `e6eb87db-…`, MySQL `f0016d68-…`, **Mongo `ca660785-…`**, Redis `99d0dfd0-…`.
- Headers: `apikey: <anon JWT>` + `X-Baas-Api-Key: <mbk_…>` + `Content-Type: application/json`.
- Statuses: `201` ok (check `rowCount`!), `400` validation / non-transactional engine,
  `403` unauthorized, `409` integrity conflict, `502` backend (e.g. upsert w/o the
  composite index).
