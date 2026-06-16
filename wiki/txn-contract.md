# Transaction contract — BaaS `/txn` (single-mount atomic writes)

**Status:** shipped on the BaaS side (`POST /query/v1/txn`). This is the write
counterpart to [graph-contract.md](./graph-contract.md) and unblocks osionos
Phase 3 (the editable inspector). It is the **single source of truth** for the
write/transaction handshake — edit this file before changing either side.

> **The one honest sentence.** We offer **real ACID, but only within one mount**:
> a batch of writes on a single backend commits all-or-nothing. We do **not**
> offer cross-mount/cross-database atomicity — that's two-phase commit, a
> fundamentally harder problem, and we don't pretend otherwise.

---

## 1. The endpoint

```
POST /query/v1/txn            (auth: same X-Baas-Api-Key as the rest of /query/v1)
{
  "mount": "<dbId>",                       // required — ALL ops run on this one mount
  "operations": [                          // required — 1..50 write ops, in order
    { "op": "insert", "resource": "notes", "data": { "id": "n1", "title": "…" } },
    { "op": "insert", "resource": "edges", "data": { "id": "e1", "from": "…", "to": "…" } },
    { "op": "update", "resource": "notes", "filter": { "id": "n1" }, "data": { "title": "…" } },
    { "op": "delete", "resource": "edges", "filter": { "id": "e1" } }
  ]
}
→ 201
{
  "guarantee": "atomic",                   // the real ACID tier — always "atomic" here
  "mount": "<dbId>",
  "results": [ { "op": "insert", "resource": "notes", "rowCount": 1 }, … ]
}
```

- `op` ∈ `insert | update | delete | upsert` (reads aren't offered in a txn yet).
- `data` for insert/update/upsert; `filter` for update/delete; optional
  `idempotencyKey` per op.
- The ops run **in array order** inside one backend transaction.

---

## 2. Semantics (what "atomic" means here)

1. **All-or-nothing, one mount.** Every op runs in a single native transaction on
   `mount`. If any op fails, the whole batch is **rolled back** — nothing persists.
   (Verified: an insert followed by a duplicate-PK insert leaves **zero** rows.)
2. **Authorized up front.** Every op is permission-checked **before** the
   transaction opens, so an unauthorized op (`403`) denies the whole batch with no
   partial write.
3. **Transactional engines only.** `postgresql` / `mysql`. A non-transactional
   engine (`mongodb` / `redis` / `http`) is rejected with
   **`400 "engine '<e>' does not support requested capability 'transactions'"`** —
   no silent best-effort.
4. **Keep batches small & fast.** The data-plane transaction TTL is ~30s; a batch
   that idles past it will be reaped. Group the writes that must be atomic, commit,
   move on.
5. **Writes are owner-scoped.** `update`/`delete` only affect rows your identity
   **owns** (`owner_id` = caller). Records created *through* the BaaS (insert via
   `/v1/query` or `/txn`) get `owner_id` set automatically and are editable;
   side-loaded/seeded rows are read-only to an api-key. This is intentional — you
   can't mutate another tenant's data.

> **Check `rowCount` — a no-op is not a failure.** An `update`/`delete` that
> matches nothing (wrong filter, or a row you don't own) returns
> **`201 guarantee:"atomic"` with `rowCount: 0`** — it committed, but changed
> nothing. Clients doing optimistic updates must treat `rowCount === 0` as
> "didn't apply" (revert the optimistic patch + tell the user), not as success.
> Only an HTTP error means rolled-back.

### The cross-mount boundary (read this)

`mount` is **one** mount. If two rows live in **different** mounts (e.g. a note in
Postgres and a user in MySQL) they **cannot** be written atomically — that's 2PC,
not offered. Options:
- **Co-locate** rows that must be written atomically in the same mount (e.g. put a
  note and its edges in the same Postgres mount → one `/txn` call is atomic).
- Or accept **non-atomic** sequential writes (separate `/txn` calls per mount) and
  design for compensation/idempotency on the client.

---

## 3. Errors

| Status | When | Effect |
|---|---|---|
| `400` | validation, or a non-transactional engine | nothing ran |
| `403` | any op unauthorized (checked before begin) | nothing ran |
| `409` | integrity-constraint violation mid-batch (dup PK/unique, FK, not-null, check) | **whole batch rolled back** |
| `502` | a genuine backend/transport failure | **whole batch rolled back** |

Neither `409` nor `502` is a partial write — the batch is rolled back before the
error returns. A `409` carries the engine's reason (e.g. `conflict: duplicate key
value violates unique constraint "notes_pkey"`), so the inspector can say "that id
already exists" instead of a generic failure.

---

## 4. How osionos's inspector should use it (Phase 3)

- Edit a node **and** its edges atomically **only when they share a mount** — send
  one `/txn` with the node `update` + the edge `insert`/`delete` ops.
- If the edges mount differs from the node mount, either co-locate them or do two
  calls and treat the result as eventually-consistent (surface that to the user the
  same honest way the graph surfaces `subgraph_eventual`).
- Always read `guarantee` (`"atomic"`) — it's the contract that the write was
  all-or-nothing. Never imply atomicity across mounts.

---

## 5. Division of responsibility

| Concern | Owner | Where |
|---|---|---|
| Single-mount transaction primitive (begin/execute/commit/rollback) | **BaaS data plane** | `data-plane-router` `/v1/transactions/*` (done) |
| `/txn` gateway: resolve mount, authorize each op, drive the txn, honest guarantee | **BaaS query-router** | `src/apps/query-router/src/query/{txn.controller,txn.dto}.ts`, `query.service.executeTransaction` (done) |
| Inspector edits → `/txn` batches; compensation when cross-mount | **osionos** | `apps/osionos/app` (Phase 3) |
| **This contract** | **shared** | this file — edit before changing either side |

---

## 6. Deferred (open follow-ups, additive)

Cross-mount **2PC** for PG↔MySQL (the only pair that can — `PREPARE TRANSACTION` +
XA); a transaction-scoped **read** op (read-your-writes inside the batch); mapping
constraint violations to `409`; a longer/explicit TTL knob. None are needed for the
single-mount atomic write that Phase 3 requires.
