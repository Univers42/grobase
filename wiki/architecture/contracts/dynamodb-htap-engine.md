# DynamoDB HTAP Engine — design (8th data-plane adapter)

> **Status: DESIGN / scaffold.** Nothing here is built yet. This is the Architect's grounded
> design for an **8th** Rust data-plane adapter (`dynamodb`), flag-gated **OFF** by default so the
> default build, default compose, and default env stay **byte-parity** with today's 7-engine stack.
> Every contract reference below is checked against the real source as of 2026-06-14; anything not
> yet measured is labelled **projected** / **scaffold**.
>
> **Ethos (kernel rule #4):** a claim without an artifact is not in the plan. The OLTP latency
> numbers below are AWS/Scylla *published* figures, not Grobase measurements — labelled as such.
> Grobase's own numbers land only once `m88-dynamodb-engine.sh` runs against DynamoDB-Local.

Engine string: `dynamodb`. Cargo feature: `dynamodb` (OFF by default). Capability constructor:
`EngineCapabilities::dynamodb()`. Closest existing sibling: the **Redis** adapter
(`crates/data-plane-pool/src/redis.rs`) — owner-prefixed keys, per-request owner-scope, no RLS, no
`begin()` historically. This adapter is to DynamoDB what the Redis adapter is to Redis, **plus** a
genuine native transaction (`TransactWriteItems`) the Redis adapter never had.

---

## 1. Positioning — one engine, three endpoints, OLTP **and** OLAP

Grobase ships a **DynamoDB-compatible engine that is endpoint-agnostic**: the *same* adapter and
the *same* SDK surface serve three concrete backends, selected purely by the mount's DSN/endpoint,
with no per-backend code path:

| Endpoint | DSN shape (sketch) | Use case | Isolation strategy |
|---|---|---|---|
| **(a) AWS DynamoDB** | `dynamodb://aws?region=eu-west-1` (creds via adapter-registry) | BYO / customer's own table | `tenant_owned` (the table predates the platform) |
| **(b) DynamoDB-Local** | `dynamodb://local?endpoint=http://dynamodb-local:8000` | dev / self-host / CI gate | `shared_rls` (owner-stamped PK) |
| **(c) ScyllaDB Alternator** | `dynamodb://scylla?endpoint=http://scylla:8000` | self-hosted high-throughput prod | `shared_rls` (owner-stamped PK) |

ScyllaDB **Alternator** is a DynamoDB-API-compatible server: it speaks the exact same wire protocol,
so the `aws-sdk-dynamodb` client points at it with only an endpoint override. That is the wedge: a
customer can develop on DynamoDB-Local, ship to AWS DynamoDB if they want managed AWS, **or** self-
host Scylla Alternator for throughput/cost — *same adapter, same SDK, no rewrite* (the kernel's
no-rewrite grow-path applied at the engine level).

**Why beat AWS, stated honestly:**

1. **One uniform API + one cost model for OLTP *and* OLAP.** AWS makes you bolt on Athena/Redshift/
   Glue (a separate service, separate API, separate bill) the moment you need analytics over a
   DynamoDB table. Grobase serves OLTP from the `dynamodb` engine and OLAP from the **export bridge**
   (§5) into the existing Trino/analytics plane — one SDK, one mount catalog, one `rps = capacity ×
   fair_share × 0.5` cost model (`cost-analysis.md`). HTAP without the bolt-on.
2. **No lock-in.** Endpoint-agnostic means a tenant can migrate AWS → Scylla → AWS without touching
   application code. AWS's value-add is that you *can't* easily leave; ours is that you can.
3. **Dense multi-tenancy.** AWS bills per-table/per-capacity-unit; thousands of small tenants on
   DynamoDB is expensive. Grobase folds many tenants onto **one** Scylla/Local endpoint via owner-
   stamped partition keys (§3), reusing the `SHARE_POOLS` density story — **pool count ⊥ tenant
   count** (`scale-slo.md` §1), now extended to a KV/document engine that costs near-zero at rest.

**Where we honestly do NOT win:** AWS DynamoDB's global tables, on-demand auto-scaling, point-in-time
recovery, and 9-region replication are AWS-operated and we do not reproduce them — for those, a tenant
should pick endpoint **(a)** and accept AWS. Grobase's win is the *uniform API + OLAP bridge + no
lock-in + density*, not out-operating AWS's managed infrastructure. (`/compare` "choose them if"
discipline.)

---

## 2. OLTP path — `DataOperation` AST → DynamoDB API

The adapter lowers our engine-neutral `DataOperation` (`data-plane-core/src/operation.rs`) to the
DynamoDB control/data API exactly as the Redis adapter lowers it to Redis commands. Mapping:

| `DataOperationKind` | DynamoDB API | Notes |
|---|---|---|
| `Get` | **GetItem** | PK = `(owner_pk, id)`; the owner condition is structural (§3), not a filter. |
| `Insert` | **PutItem** + `ConditionExpression: attribute_not_exists(pk)` | create-only; a colliding id → `ConditionalCheckFailedException` → mapped to **409 Conflict** (matches the existing constraint-409 invariant, `wiki/`). |
| `Update` | **UpdateItem** + `ConditionExpression: attribute_exists(pk) AND owner = :owner` | partial update; missing item → affected_rows 0 (Redis-update parity). |
| `Delete` | **DeleteItem** + owner `ConditionExpression` | idempotent; returns affected_rows. |
| `List` | **Query** (preferred) / **Scan** (fallback) | **Query** when the request keys the owner partition (the common path — owner_pk is the partition key, so Query is a single-partition read); **Scan** + `FilterExpression` only for the rare cross-partition admin case. The capability `pattern_search = Indexed` reflects "Query is indexed, Scan is the fallback." |
| `Upsert` | **PutItem** (no condition) | last-writer-wins put; owner stamped into the item. |
| `Batch` | **BatchWriteItem** | up to 25 put/delete requests per call (the DynamoDB hard limit) → `max_batch_size: 25`. **Honest non-atomicity:** `BatchWriteItem` is *not* a transaction (partial success possible, unprocessed items retried), so the `BatchSummary { atomic: false, … }` shape — identical to the Redis/Mongo ordered-batch contract — is the correct, honest report. Atomicity belongs to TransactWriteItems below, not here. |
| **TRANSACTIONS** (`begin/execute/commit`) | **TransactWriteItems** | see below — the headline. |

### 2.1 TransactWriteItems — the fastest honest ACID transaction

`TransactWriteItems` is an **all-or-nothing** write across up to 100 items (and up to 4 MB): every
Put/Update/Delete/ConditionCheck in the set commits, or none do. Two properties make it the
standout:

- **Single-digit-millisecond ACID.** A `TransactWriteItems` round-trip is one network call that the
  service commits atomically — AWS/Scylla *published* single-digit-ms latencies for small transacts.
  (**projected for Grobase** — measured only once m88 runs; do not quote a Grobase ms number until
  then.) This is dramatically simpler than the 2-phase `begin → execute×N → prepare → commit`
  dance the SQL adapters thread through a pinned connection.
- **`ClientRequestToken` = native idempotency.** DynamoDB de-duplicates a `TransactWriteItems` by its
  `ClientRequestToken` for ~10 minutes: re-sending the *same* token with the *same* statements is a
  no-op that returns success. We map our `DataOperation::idempotency_key` → `ClientRequestToken`, so
  `native_idempotency: true` is **honest** — the engine, not the app, guarantees exactly-once. This
  is a genuine capability edge: only this engine (and arguably none of the other 7) sets that flag.

**TxHandle mapping (the design choice).** Our `TxHandle` trait
(`data-plane-core/src/ports.rs`) is `begin → execute(op) ×N → prepare → commit/rollback`, modelled
on a connection-pinned SQL transaction. DynamoDB has no open-transaction handle — the whole transact
is one stateless call. So the adapter's `DynamoTxHandle` **buffers** each `execute(op)` into an
in-memory `Vec<TransactWriteItem>` and only issues the single `TransactWriteItems` call at
`commit()`:

- `begin()` → allocate an empty buffer + a fresh `ClientRequestToken` (from `idempotency_key` if
  provided, else generated) + the owner from `RequestIdentity`.
- `execute(op)` → translate the op to a `TransactWriteItem` (with its owner condition) and push it;
  return a synthetic per-item `DataResult` (no I/O yet). Reject `Get`/`List`/`Aggregate` inside a tx
  (TransactWriteItems is write-only; reads use `TransactGetItems`, deferred to a follow-up).
- `prepare()` → no-op (DynamoDB has no prepare phase; `two_phase_commit: true` is justified by the
  *atomic multi-item* semantics, see §4, not by a wire-level 2PC handshake — the comment must say so).
- `commit()` → issue `TransactWriteItems` with the buffered items + token. A
  `TransactionCanceledException` (e.g. a conditional check failed on one item) means **the whole
  transaction rolled back** — map to `409 Conflict`; nothing was written. This is the load-bearing
  rollback the m88 gate proves.
- `rollback()` → drop the buffer without issuing the call (nothing was sent, so nothing to undo).

This buffer-then-commit shape mirrors how the SQLite/MSSQL adapters treat a single atomic batch, and
keeps the `TxHandle` contract honest: a partially-applied transaction is structurally impossible
because **no write leaves the process until `commit()`**.

---

## 3. Isolation — owner-stamped partition key + condition expressions (no RLS)

DynamoDB has **no row-level security**. Isolation is identical in spirit to the Redis adapter
(`redis.rs`): the verified identity owns a key prefix; a forged id cannot escape it. Here the prefix
is the **partition key**.

- **Owner derivation (verbatim from Redis):** `owner = identity.user_id.unwrap_or(identity.tenant_id)`
  — the exact `RedisPool::owner` / `MongoPool::owner` rule (`redis.rs:157`). One source of truth for
  "who owns this row," sourced from `RequestIdentity` (`data-plane-core/src/identity.rs`), never from
  the request body.
- **Table layout:** composite primary key `(owner_pk: S, id: S)` where `owner_pk` carries the owner
  (optionally namespaced — see below). A `Get`/`Update`/`Delete` keyed by `(owner_pk = owner, id =
  requested_id)` **cannot** read another owner's item, because the partition key is the owner: a
  foreign id under another owner's partition is simply a different key that does not exist for this
  caller. This is the structural equivalent of Redis's `{owner}:{resource}:{id}` envelope.
- **Defense in depth:** every read AND write also carries a `ConditionExpression`/`FilterExpression`
  pinning `owner_pk = :owner` (and, on writes, the item's stored `owner` attribute), so even a
  Scan-fallback path cannot return cross-owner rows. This mirrors the Mongo adapter's
  "stamp + filter on every op" belt-and-braces (`mongo.rs` `check_tenant` + owner stamp).

### 3.1 `pools_shared` + isolation mapping

The endpoint (the DynamoDB connection) holds **no tenant state** — exactly the `shared_rls`
precondition for `pools_shared` (`data-plane-pool/src/lib.rs:91`). With `DATA_PLANE_SHARE_POOLS` on,
one Scylla/Local endpoint serves every tenant on one client handle, isolation re-applied **per
request** from the identity's owner_pk. That is the same per-request-not-per-pool property that makes
pool count independent of tenant count (`scale-slo.md` §1) — now realised on a KV engine.

The adapter sets `shared_pool = crate::pools_shared(&mount)` at `open_pool` (verbatim Redis pattern)
and, like Redis/Mongo, **skips the single-owner pool guard** when `shared_pool` is true (the per-
request owner_pk carries isolation; there is no single pool owner to assert).

`EngineClass::of` mapping (`isolation.rs:148`): DynamoDB should join the **`Namespace`** class
(alongside `mysql | mongodb | redis`) so that `schema_per_tenant` produces a `UseNamespace`
directive the adapter consumes as a partition-key *prefix* segment — `<namespace>:<owner>` — exactly
how Redis prepends `<namespace>` to its key. This is a **one-line** edit to the `match` in
`EngineClass::of`. **Parity note:** the `match`'s `_ => Unscoped` arm means an unknown engine string
already degrades to no-op; adding `"dynamodb"` to the `Namespace` arm changes behaviour *only* for a
mount whose engine is literally `dynamodb` AND isolation is `schema_per_tenant` — which cannot exist
until the feature is built and a mount is provisioned for it. Every existing mount is byte-identical.

Per-strategy behaviour:

| Mount isolation | DynamoDB partition key |
|---|---|
| `shared_rls` (default) | `owner_pk = owner` (historical envelope) — `ScopeDirective::None`. |
| `schema_per_tenant` | `owner_pk = "<namespace>:" + owner` — `UseNamespace`, namespace = `safe_schema(tenant_id)`. |
| `db_per_tenant` | distinct endpoint/table per tenant via DSN; `ScopeDirective::None`. |
| `tenant_owned` (BYO AWS table) | **no owner stamping** — `Isolation::owner_scoped() == false`; tenant gating already happened at key→mount resolution (`isolation.rs` `TenantOwned` doc). The customer's table schema is used as-is. |

---

## 4. Capability descriptor — `EngineCapabilities::dynamodb()`

Proposed constructor (drop-in alongside `redis()` / `mongodb()` in `capability.rs`), each value
justified honestly. **Invariant (the capability-honesty test, `data-plane-pool/src/capability_honesty.rs`):**
`supported_ops()` MUST equal exactly the set for which `supports_op()` returns true — the descriptor
cannot advertise an op the adapter does not dispatch.

```rust
#[must_use]
pub fn dynamodb() -> Self {
    Self {
        read: true,          // GetItem / Query / Scan
        write: true,         // PutItem / UpdateItem / DeleteItem
        upsert: true,        // PutItem (no condition) = last-writer-wins
        batch: true,         // BatchWriteItem (NON-atomic, max 25)
        aggregate: false,    // DynamoDB has NO server-side GROUP BY/SUM — OLAP is the bridge (§5)
        introspect: true,    // DescribeTable / ListTables → SchemaDescriptor
        schema_ddl: true,    // CreateTable / DeleteTable (single-op DDL surface)
        stream: false,       // DynamoDB Streams CDC = DESIGNED but DEFERRED to a follow-up (§5/§8)
        ddl: false,          // no apply_migration batch (mirrors mongo: schema_ddl true, ddl false)
        transactions: true,  // TransactWriteItems (buffer-then-commit TxHandle, §2.1)
        savepoints: false,   // no nested-savepoint concept in a single transact call
        isolation_levels: vec![IsolationLevel::Serializable], // transact is serializable-isolated
        two_phase_commit: true,   // TransactWriteItems is all-or-nothing across items (§2.1)
        native_idempotency: true, // ClientRequestToken de-dupes a transact — engine-guaranteed (§2.1)
        max_batch_size: 25,       // BatchWriteItem hard limit (NOT the 100-item transact limit)
        cost: CostCapabilities {
            latency_class: LatencyClass::Native,        // first-class driver, not an FDW/passthrough
            pattern_search: PatternSearchCapability::Indexed, // Query is indexed; Scan is the fallback
            joins: JoinCapability::None,                // KV/document — no joins, like redis/http
        },
    }
}
```

`supported_ops()` for the adapter (matches `supports_op()` given the flags above — note `aggregate`
is the **only** CRUD-family op excluded, exactly like Redis):

```rust
pub(crate) const SUPPORTED_OPS: &[DataOperationKind] = &[
    DataOperationKind::List,   DataOperationKind::Get,
    DataOperationKind::Insert, DataOperationKind::Update, DataOperationKind::Delete,
    DataOperationKind::Upsert, DataOperationKind::Batch,
    // Aggregate deliberately ABSENT — supports_op(Aggregate)==false because aggregate:false.
];
```

**Honesty call-outs (each flag is a claim that must survive review):**

- `aggregate: false` — **the single most important honest flag.** DynamoDB has no server-side
  grouped aggregation; claiming it would be a lie. OLAP is the export bridge (§5), served *outside*
  this engine. `supports_op(Aggregate)` is therefore false and the route rejects `op=aggregate` on a
  `dynamodb` mount with the same NotImplemented path Redis uses.
- `introspect: true` / `schema_ddl: true` — `DescribeTable`/`ListTables` give a real `SchemaDescriptor`
  (table list + key schema + attribute types), and `CreateTable`/`DeleteTable` are a genuine single-
  op DDL surface, so both flags are earned (these are *route* capabilities — `introspect_never_leaks_into_supports_op`
  / `schema_ddl_never_leaks_into_supports_op` keep them out of `supports_op`). **Caveat:** DynamoDB is
  schema-on-read for non-key attributes, so the descriptor honestly reports only the *key* attributes
  with declared types; non-key columns are dynamic. The descriptor comment must say so.
- `ddl: false` — there is no transactional multi-statement `apply_migration`; like mongo, `schema_ddl`
  is true while `ddl` stays false. This is the exact `schema_ddl_flag_matches_each_engine_ddl_surface`
  precedent.
- `two_phase_commit: true` — justified by **atomic multi-item all-or-nothing**, NOT a wire-level XA/2PC
  handshake. The constructor comment must state this explicitly (same care the postgres/mongo
  constructors take) so a reader doesn't assume distributed-XA.
- `native_idempotency: true` — the **only** adapter that can honestly set this, via `ClientRequestToken`.
- `stream: false` for the MVP — Streams CDC is designed (§5) but not in the first slice; setting it
  true before the producer exists would violate capability-honesty.

---

## 5. OLAP path (HTAP) — the export bridge, NOT the engine

**DynamoDB is not an analytical store.** The `dynamodb` engine therefore serves **only** OLTP and
honestly reports `aggregate: false`. Analytics (`op=aggregate` / ad-hoc analytical queries) are
served by a **separate export bridge** into the existing analytics plane — the same Trino federation
already wired for the `analytics` / `full` editions (`docker/services/trino/`,
`deploy/helm/mini-baas/values-analytics.yaml`).

```
┌──────────────┐   OLTP (single-digit-ms)     ┌──────────────────────────────┐
│  SDK / app   │ ───────────────────────────► │ dynamodb engine (this adapter)│
└──────────────┘                              └──────────────┬───────────────┘
        │  OLAP (op=aggregate / analytical SQL)              │  change feed
        ▼                                                    ▼
┌──────────────┐    federated SQL     ┌──────────┐   DynamoDB Streams / export
│ analytics    │ ◄─────────────────── │  Trino   │ ◄────────────────────────────
│ plane (Trino)│                      │ columnar │   (control-plane producer)
└──────────────┘                      └──────────┘
```

**Bridge design (a future control-plane producer — scaffold):**

- **Source:** DynamoDB Streams (the table's change feed: insert/modify/remove records) OR a periodic
  `ExportTableToPointInTime` to object storage. Streams gives near-real-time HTAP; periodic export is
  cheaper and simpler for the MVP-after-MVP.
- **Producer:** a Go control-plane producer (sibling to the existing `outbox-relay` Mongo projector,
  commit `333e0be`, and the `metering`/`backup` control-plane packages) that consumes Stream records
  and writes them into a columnar landing table the Trino `postgresql`/`mongodb` catalog can read —
  owner-stamped so the analytics plane preserves per-tenant scope.
- **Serving:** `op=aggregate` against an analytics-mounted target runs in Trino, **never** in the
  DynamoDB engine. The mount catalog distinguishes the OLTP `dynamodb` mount from its analytics
  projection, so there is no false aggregate claim anywhere.

**Explicitly deferred:** the bridge is **design-only** here. The MVP adapter ships OLTP; the bridge
producer is a separate slice (§8). Until it exists, a tenant needing analytics over a DynamoDB mount
uses the existing analytics plane against a manually-projected table — and the engine's
`aggregate: false` tells the SDK so up front.

---

## 6. Cargo / feature — OFF by default, optional deps

A new **optional** feature `dynamodb`, off by default, with its AWS deps **optional** so the default
build does not even fetch them (kernel rule #5; the byte-parity guarantee). Edits to
`crates/data-plane-pool/Cargo.toml`:

```toml
[features]
# default is UNCHANGED — dynamodb is NOT added here, so the default build is byte-identical.
default = ["postgres", "mongodb", "mysql", "redis", "sqlite", "mssql", "http"]
# ... existing engine features unchanged ...
dynamodb = ["dep:aws-sdk-dynamodb", "dep:aws-config", "dep:aws-smithy-runtime-api"]

[dependencies]
# ... existing deps unchanged ...
aws-sdk-dynamodb       = { workspace = true, optional = true }
aws-config             = { workspace = true, optional = true }
aws-smithy-runtime-api = { workspace = true, optional = true }   # error-kind matching for cond-check
```

Workspace `Cargo.toml` adds the version pins (projected — exact minor versions resolved at build):

```toml
# 8th engine (OFF by default): DynamoDB-compatible adapter (AWS DynamoDB /
# DynamoDB-Local / ScyllaDB Alternator). rustls to match the workspace TLS
# posture; behind-feature so the default build never fetches the AWS SDK.
aws-sdk-dynamodb       = { version = "1", default-features = false, features = ["rustls"] }
aws-config             = { version = "1", default-features = false, features = ["rustls"] }
aws-smithy-runtime-api = "1"
```

Module registration in `data-plane-pool/src/lib.rs` (mirrors the `#[cfg(feature = "redis")]` lines
exactly):

```rust
#[cfg(feature = "dynamodb")]
mod dynamodb;
#[cfg(feature = "dynamodb")]
pub use dynamodb::DynamoEngineAdapter;
```

Adapter registration in `data-plane-server/src/routes.rs` (mirrors the redis push at :268–:269):

```rust
#[cfg(feature = "dynamodb")]
adapters.push(Arc::new(DynamoEngineAdapter::new(resolver.clone())));
```

The boot-time capability-honesty battery (`lib.rs:21` `#[cfg(all(test, feature = "..."))]`) gets
`feature = "dynamodb"` added to its `cfg(all(...))` list **only** when the feature is built — when
`dynamodb` is off (the default), the battery compiles the 7-engine set exactly as today.

**Parity statement:** because `dynamodb` is absent from `default`, `cargo build`, the default router
image, the default compose, and `make baas-verify-all` are byte-identical to today — the AWS SDK is
never compiled or fetched. The feature only materialises under `--features dynamodb` (or an explicit
edition that opts in), which no shipping edition does yet.

---

## 7. Gate plan — `m88-dynamodb-engine.sh` (against DynamoDB-Local)

A self-contained, isolated-ephemeral gate (the m74/m72 style: throwaway containers on a private
network, `$$`-suffixed names, EXIT-trap cleanup, never touches a `mini-baas-*` container). Tests run
against the official **`amazon/dynamodb-local`** image (a real DynamoDB-API server, no AWS account).
**This gate needs a live `docker run` and is NOT executed in this slice — it is authored here and run
in the next slice.**

Three blocks, the middle one **load-bearing** (a gate that only proves the happy path is a vacuous
gate the reviewer rejects):

- **(A) POSITIVE round-trip.** Build the router `--features dynamodb`, point a `dynamodb` mount at
  the `dynamodb-local` container, then:
  1. `Insert` (PutItem + attribute_not_exists) → 201/created; re-Insert same id → **409 Conflict**.
  2. `Get` the item back → exact round-trip equality.
  3. `List` (Query on the owner partition) → returns exactly the owner's items.
  4. `begin → execute(Put A) → execute(Update B) → commit` (TransactWriteItems) → both visible
     atomically; assert a fresh `Get` sees A and B.
  5. Re-`commit` the **same** `ClientRequestToken` → success, no duplicate (proves
     `native_idempotency`).

- **(B) LOAD-BEARING REJECT** (the real proof of the isolation + transaction contract):
  1. **Cross-owner read denied.** Owner U1 writes `id=x`. Owner U2 (different `RequestIdentity`)
     `Get`s `id=x` → **empty / not-found**, never U1's item. Same for `List`/`Update`/`Delete`. This
     is the partition-key isolation property (§3).
  2. **Transaction rollback on conditional-check failure.** A `TransactWriteItems` whose second item
     has a failing `ConditionExpression` (e.g. `attribute_not_exists` on an id that already exists) →
     `TransactionCanceledException` → **409**, and a follow-up `Get` proves the **first** item was
     **NOT** written (whole-transaction rollback). This is the load-bearing atomicity proof.

- **(C) FLAG-OFF PARITY.** Build the router with the **default** features (no `dynamodb`). Assert:
  the `dynamodb` engine is **absent** from `/v1/capabilities` (or the adapter list), a `dynamodb`
  mount resolves to "unknown engine," and the default image's adapter set is byte-identical to the
  pre-change build. This is the byte-parity guarantee made testable.

Gate skeleton (42-header, `bash -n`/shellcheck-clean — **authored, not run**):

```bash
#!/usr/bin/env bash
# m88-dynamodb-engine.sh — DynamoDB HTAP engine (8th adapter) live gate.
#   (A) POSITIVE round-trip: put/get/query/transact + ClientRequestToken idempotency.
#   (B) LOAD-BEARING REJECT: cross-owner read denied; transact rollback on cond-check.
#   (C) FLAG-OFF PARITY: default build => dynamodb engine absent, byte-identical.
# Isolated-ephemeral (m74 style): throwaway amazon/dynamodb-local + router built
# --features dynamodb, $$-suffixed names, private network, EXIT-trap full cleanup.
# Needs a live `docker run` (next slice). OFF by default => default build untouched.
set -euo pipefail
# ... (provision dynamodb-local, build router --features dynamodb, run A/B/C, trap cleanup) ...
```

It will get the usual `baas-verify-m88` root-Makefile wrapper once it exists.

---

## 8. Honest residuals — MVP vs deferred

**In the MVP adapter (first slice, behind `--features dynamodb`):**

- CRUD: Get/Insert(cond)/Update/Delete/Upsert/List(Query+Scan-fallback) with owner-stamped PK.
- `Batch` via BatchWriteItem (non-atomic, max 25, honest `BatchSummary{atomic:false}`).
- **Transactions** via TransactWriteItems (buffer-then-commit `TxHandle`) + `ClientRequestToken`
  idempotency — the headline.
- Isolation: owner-stamped partition key + condition expressions; `shared_rls` / `schema_per_tenant`
  (namespace prefix) / `db_per_tenant` / `tenant_owned`; `pools_shared` density.
- `introspect` (DescribeTable/ListTables) + `schema_ddl` (CreateTable/DeleteTable).
- Endpoint-agnostic: AWS DynamoDB, DynamoDB-Local, ScyllaDB Alternator via DSN/endpoint override.

**Deferred (named follow-ups, NOT silently dropped):**

1. **DynamoDB Streams CDC** (`stream: false` in MVP). Real-time change feed → realtime plane and the
   OLAP bridge. Setting `stream: true` waits on the producer existing (capability-honesty).
2. **The OLAP export bridge** (§5) — design-only here; the Go control-plane producer (Streams →
   Trino columnar) is a separate slice. Until then `aggregate: false` is the honest user-facing fact.
3. **Global Secondary Indexes (GSIs).** The MVP keys only on `(owner_pk, id)`. GSIs (alternate query
   patterns) are a richer follow-up; `List` is Query-on-partition or Scan-fallback until then.
4. **PartiQL.** DynamoDB's SQL-ish surface (`ExecuteStatement`) could back a richer `List`/raw path;
   the MVP uses the typed item API only. PartiQL would be the natural `execute_raw` surface.
5. **`TransactGetItems`** (atomic multi-item *reads* inside a tx). The MVP tx is write-only (`begin`
   rejects Get/List); read-transactions are a follow-up.
6. **Grobase-measured latency.** Every OLTP latency in §1–§2 is AWS/Scylla *published*; the Grobase
   number is **projected** until `m88` runs and writes an artifact under `artifacts/bench/`.

---

## 9. Source touch-points (for the implementing slice — design reference only)

| File | Change | Parity-safe because |
|---|---|---|
| `crates/data-plane-pool/src/dynamodb.rs` | **new** adapter (model on `redis.rs`) | new file, only compiled under `--features dynamodb`. |
| `crates/data-plane-pool/src/lib.rs` | `#[cfg(feature="dynamodb")] mod/pub use` | cfg-gated; default build unchanged. |
| `crates/data-plane-pool/Cargo.toml` | `dynamodb` feature + optional deps | not in `default`; deps optional → never fetched by default. |
| `crates/data-plane-core/src/capability.rs` | add `EngineCapabilities::dynamodb()` + honesty-test rows | a new constructor; existing constructors untouched. |
| `crates/data-plane-core/src/isolation.rs` | add `"dynamodb"` to `EngineClass::Namespace` arm | only affects an engine string that cannot exist until built. |
| `crates/data-plane-server/src/routes.rs` | `#[cfg(feature="dynamodb")] adapters.push(...)` | cfg-gated; default adapter set unchanged. |
| `scripts/verify/m88-dynamodb-engine.sh` | **new** gate (authored, run next slice) | a test script; does not run by default. |
| workspace `Cargo.toml` | aws-sdk version pins (optional, behind-feature) | optional deps; default resolution unchanged. |

Every change is either a **new file** or a **cfg-gated addition**, so the default build / default
compose / default env stay **byte-parity** with the current 7-engine stack — the kernel's
flag-OFF-by-default discipline, applied at the engine-adapter level.
