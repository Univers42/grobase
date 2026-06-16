# Node-graph contract — BaaS ⇄ osionos handshake

**Status:** MVP shipped on the BaaS side (`POST /query/v1/graph`). This file is the
**single source of truth** both codebases build against:

- **BaaS** (`apps/baas/mini-baas-infra`) — owns the data plane, the `/graph`
  endpoint, the node/edge model, and the consistency guarantees.
- **osionos** (`apps/osionos/app`) — owns the client: the pure graph model
  (`graphModel.ts` / `deriveGraph.ts` / `diffGraph.ts`) and the visualisation.

> **The one-line story.** The graph is the killer demo of the backend-agnostic
> plane: *cross-database edges are the one thing only an agnostic layer can show.*
> It ships with **zero new engine work** at the explicit-edges MVP level. We do
> **not** claim global atomic snapshots — we claim **per-node atomic, edges
> single-backend-atomic, subgraph eventually-consistent**, and we never lie about
> which guarantee you got (`GraphResponse.guarantee`).

If either side needs to change a type below, it's a **contract change** — edit
*this* file first and ping the other AI before implementing.

---

## 1. The frozen types (copy verbatim on the osionos side)

```ts
// A node = one row/record from any backend, id = <mountId>:<resource>:<pk>.
type NodeId = string;

interface GraphNode {
  id: NodeId;
  mount: string;
  resource: string;
  pk: string;
  data: Record<string, unknown>; // the row JSON, normalised by the BaaS
  note?: string;                 // optional markdown body (website-dependent)
}

// An edge = a row in the dedicated `edges` mount (the PRIMARY edge source).
interface EdgeRecord {
  id: string;
  from: NodeId;
  to: NodeId;
  type: string;        // e.g. "references" | "tagged" | "linked"
  label?: string;
  directed?: boolean;  // default true
}

type GraphGuarantee = 'per_node_atomic' | 'subgraph_eventual';

interface GraphResponse {
  focus: NodeId;
  depth: number;
  nodes: GraphNode[];
  edges: EdgeRecord[];
  guarantee: GraphGuarantee; // the tier ACTUALLY delivered — honest, per doc-02
}
```

`NodeId` parse/format is `mount:resource:pk` where **`pk` may itself contain `:`**
(split on the first two colons only). The BaaS implementation lives in
`src/apps/query-router/src/graph/graph.types.ts` — keep the osionos `graphModel.ts`
byte-compatible with it.

---

## 2. The endpoint

```
POST /query/v1/graph          (auth: same X-Baas-Api-Key as the rest of /query/v1)
{
  "focus":     "<mount>:<resource>:<pk>",   // required
  "depth":     1,                           // optional, 0–3, default 1
  "edgesDbId": "<mount id holding edge rows>",// required
  "edgesTable":"edges"                      // optional, default "edges"
}
→ 200 GraphResponse
```

**How it's assembled** (pure orchestration over `/v1/query`, no cross-DB join):
BFS from `focus` to `depth` rings — for each node: `list {id: pk} limit 1` to fetch
it, then `list` the `edges` mount where `from == nodeId OR to == nodeId`, then visit
the peers. A node the caller **cannot read is silently omitted** (the graph shows
only what your permissions allow — per-tenant, per-resource ACL applies for free).

### 2.1 The global graph (`/graph/overview`)

The Obsidian "whole-vault" view — focus-less, returns every node from a set of
resources plus every edge:

```
POST /query/v1/graph/overview      (auth: same X-Baas-Api-Key)
{
  "resources":[ {"dbId":"<m>","table":"notes"}, {"dbId":"<m2>","table":"users"} ], // required
  "edgesDbId":"<mount id holding edge rows>",   // required
  "edgesTable":"edges",                         // optional, default "edges"
  "limit": 500,                                 // optional rows PER resource, 1–2000, default 500
  "generators": { ... }                         // optional, same shape as §3.1
}
→ 200 GraphResponse   (no `focus`; always guarantee "subgraph_eventual")
```

It `list`s each resource (bounded by `limit`) → nodes, `list`s the whole `edges`
mount, then layers the §3.1 generators. Same per-permission scoping (unreadable
rows dropped). **Live-verified** cross-database (3 Postgres notes + a MySQL user in
one response). Use it for the initial whole-graph render; use §2 `/graph` to expand
a focus locally without pulling everything.

---

## 3. The `edges` mount (the primary edge source)

Edges are **first-class data** — Obsidian's `[[wikilink]]` model. Provision one
table/collection (any engine) and store edge rows:

| column | type | notes |
|---|---|---|
| `id` | string/pk | edge id |
| `from` | string | a `NodeId` |
| `to` | string | a `NodeId` |
| `type` | string | relationship kind |
| `label` | string? | optional |
| `directed` | bool? | default true |

Because `from`/`to` are global `NodeId`s, **a cross-database link is just an edge
whose endpoints are in different mounts** — that's the whole trick, and it needs no
foreign keys (which can't cross databases anyway).

### 3.1 Secondary edge generators (shipped)

Beyond the explicit `edges` mount, `/graph` can derive edges from a node's own
data — all emitting the same `EdgeRecord` shape, so the client never knows which
generator produced an edge. Configure them per request under `generators`:

```jsonc
"generators": {
  "noteField": "body",                                  // parse [[NodeId]] → type "note_link"
  "tags":   { "field": "tags", "mount": "<m>", "resource": "tags" },   // string[] → type "tagged"
  "references": [ { "field": "author_id", "mount": "<m>", "resource": "users" } ] // FK-by-declaration → type = field name
}
```

- **note** — Obsidian `[[<NodeId>]]` links in a markdown field.
- **tag** — a string-array field → one edge per tag to a tag node.
- **reference** — a scalar field value → an edge to `<mount>:<resource>:<value>`
  (FK *by declaration*; real schema-introspected FKs are a later, additive
  generator that needs an introspection capability).

Generated-edge **targets may be dangling** (the tag/reference node may have no
row) — that's expected (Obsidian shows unresolved links too); the client may
synthesise those nodes. **Live-verified** end-to-end: a Postgres note linked to a
**MySQL** user (cross-database), plus `note_link` + `tagged` edges, in one response.

> **owner-predicate gotcha:** on engines that always scope reads by `owner_id`
> (MySQL/Mongo), a node is only fetchable if its row's `owner_id` matches the
> caller — so **write node rows through the api-key** (the BaaS injects `owner_id`),
> don't side-load them. Postgres reads rely on RLS instead.

---

## 4. Division of responsibility (so the two AIs don't collide)

| Concern | Owner | Where |
|---|---|---|
| Node identity, normalised row JSON | **BaaS** | `/v1/query` (done) |
| `edges` mount + `/graph` assembly + guarantee tier | **BaaS** | `src/apps/query-router/src/graph/*` (done) |
| Pure graph model: `graphModel.ts`/`deriveGraph.ts`/`diffGraph.ts` | **osionos** | `apps/osionos/app` (Phase 0) |
| Layout, rendering, interaction, note panel | **osionos** | `apps/osionos/app` |
| **This contract** | **shared** | this file — edit before changing either side |

osionos Phase 0 is **pure / contract-only**: it consumes a `GraphResponse` (real or
fixture) and never calls the network itself, so it can be built and unit-tested
**today** against §1 and drops in unchanged when the live endpoint is wired.

---

## 5. Honesty constraints (must be respected on both sides)

1. **Consistency is tiered and reported.** `depth 0` → `per_node_atomic`;
   `depth ≥ 1` spanning mounts → `subgraph_eventual` (assembled from several atomic
   reads; there is **no global MVCC across heterogeneous engines** — this is a
   fundamental limit, see doc-02 §0). The client should treat `subgraph_eventual`
   as a possibly-slightly-stale snapshot (fine for a graph view).
2. **No cross-database joins** — traversal is N round-trips. Prefer the **local
   graph** (depth 1–2) and expand on demand; the **global** `/graph/overview` (§2.1)
   is allowed but is **bounded** (`limit` rows per resource, default 500, max 2000;
   edge fan-out 1000) — it samples, it does not promise the entire dataset. `depth`
   is capped at 3 server-side.
3. **Per-tenant + per-permission.** The graph only contains nodes the caller may
   read; unreadable peers are dropped, not errored.
4. **PK convention:** node fetch filters on the `id` column (`{id: pk}`). Tables
   whose primary key isn't surfaced as `id` aren't addressable as nodes yet
   (deferred — needs schema introspection).

---

## 6. osionos Phase 0 spec (pure functions — build against fixtures)

```ts
// graphModel.ts — the §1 types + NodeId helpers (parse/format, mirror graph.types.ts)
// deriveGraph.ts — (nodes: GraphNode[], edges: EdgeRecord[]) → in-memory graph;
//                  explicit edges (the `edges` mount) are PRIMARY; FK/tag/note
//                  generators are secondary and emit the same EdgeRecord shape.
// diffGraph.ts   — (prev, next) → { addedNodes, removedNodes, changedNodes,
//                  addedEdges, removedEdges } for incremental re-render.
```

Fixture to unit-test against (a valid `GraphResponse`):

```json
{
  "focus": "db-1:notes:42",
  "depth": 1,
  "nodes": [
    { "id": "db-1:notes:42", "mount": "db-1", "resource": "notes", "pk": "42",
      "data": { "id": "42", "title": "Atomic graph" } },
    { "id": "db-2:users:7", "mount": "db-2", "resource": "users", "pk": "7",
      "data": { "id": "7", "name": "alice" } }
  ],
  "edges": [
    { "id": "e1", "from": "db-1:notes:42", "to": "db-2:users:7",
      "type": "authored_by", "directed": true }
  ],
  "guarantee": "subgraph_eventual"
}
```

Note the cross-database edge (`db-1` note → `db-2` user) — that's the demo.

---

## 7. Testing the live endpoint (BaaS side)

1. Provision a mount + an `edges` table; insert a couple of rows and a couple of
   edges via the normal `/query/v1/<dbId>/tables/<table>` API.
2. `curl -X POST $GATEWAY/query/v1/graph -H "X-Baas-Api-Key: <key>" -d
   '{"focus":"<dbId>:notes:1","depth":1,"edgesDbId":"<dbId>"}'`
3. Assert the `nodes`/`edges`/`guarantee` shape matches §1.

(Direct against the data-plane bypasses Kong auth; through the gateway exercises
the real ACL path.)

---

## 8. MVP scope vs. deferred

**Shipped:** explicit-edges graph assembly, `depth` BFS (≤3), per-permission node
omission, the honest `guarantee` tier, `directed`/`type`/`label` edges, the
**note/tag/reference secondary generators** (§3.1), the **global `/graph/overview`**
(§2.1, bounded whole-vault view), and a **live cross-database** demo (Postgres notes
↔ MySQL user in one graph, both the local and the global endpoint).

**Graph writes:** atomic node+edge writes are shipped via **single-mount `/txn`**
(see [txn-contract.md](./txn-contract.md)) — co-locate a node and its edges in one
mount and the write is all-or-nothing. Cross-**mount** atomicity (2PC) is still
deferred and almost never needed, since edges are single-backend-atomic rows.

**Deferred (open follow-ups, each additive):** real schema-introspected FK edges
(needs an introspection capability); introspection for non-`id` PKs; a
materialised/cached global graph (or Trino, doc-05) for large views; `depth > 3`;
richer `note` population; cross-mount 2PC writes.
