# Grobase Engineering Capability Matrix — the polymorphic substrate, proven

**Verdict.** The polymorphic substrate is real and gate-proven: Grobase is one backend that
serves CRUD/aggregate/transaction traffic across **8 engine adapters** through **one uniform port**
(`EngineAdapter` / `EnginePool`), name-routed per mount, owner-scoped per request, with the
capability asymmetries between engines made **explicit and machine-checked** rather than papered
over. A tenant can connect any allowed engine (BYO, three credential modes), run N mounts of any
engine mix at once, pick one of four isolation models per mount, and the whole fleet collapses onto
a tiny resident footprint (24,887 live tenants held by a **2.6 MiB** data plane, 0 standing pools).
This document states exactly what that substrate does — and its honest limits — and cites the gate
script or artifact behind every claim. Where the honesty contract bites (redis has no aggregate,
http has no batch/aggregate, only Postgres+MySQL get full multi-statement transactions, `tenant_owned`
is not yet wired on mongo, ABAC conditions are not yet evaluated), it is named in §7, not hidden.

> Every number/capability below cites a **real** gate script (`scripts/verify/m*.sh`) or a **real**
> artifact file under `mini-baas-infra/artifacts/`. Claims with no artifact are not in this doc.

---

## 1. Engine × operation matrix

The data plane defines a fixed operation vocabulary, `DataOperationKind` (List, Get, Insert,
Update, Delete, Upsert, Aggregate, Batch), plus multi-statement **Transactions** (`begin()`). Each
adapter declares a `pub(crate) const SUPPORTED_OPS` and an exhaustive-by-enumeration `execute`
match, so the declared capability **cannot drift** from the runtime behaviour. A boot-time assertion
(`data-plane-pool/src/capability_honesty.rs`) checks descriptor ↔ `SUPPORTED_OPS` inside the
process; **gate m25** (`scripts/verify/m25-oltp-matrix.sh`) re-proves the same truth end-to-end
through the customer path (Kong key-auth → query-router → Rust `/v1/query` → engine pool).

| Engine | List | Get | Insert | Update | Delete | Upsert | Batch | Aggregate | Transactions |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--|
| **postgres**  | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | **full** (pinned multi-stmt `begin()`) |
| **mysql**     | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | **full** (pinned multi-stmt `begin()`) |
| **mongo**     | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ `NotImplemented` (session-threading refactor pending) |
| **mssql**     | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ `NotImplemented` (`transactions:false`; single batch still atomic) |
| **sqlite**    | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ `NotImplemented` (`transactions:false`; single batch still atomic) |
| **redis**     | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | **✗** | ✗ `NotImplemented` (MULTI/EXEC not yet exposed) |
| **http**      | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | **✗** | **✗** | ✗ `NotImplemented` (upstream-defined, not exposed) |
| **dynamodb**  | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | **✗** | **buffered** (`TransactWriteItems`, write-only; reads-in-tx are a follow-up) |

**Honest asymmetries (read these, not the green ✓'s).**
- **redis** serves Batch but **not Aggregate** — `SUPPORTED_OPS` omits `Aggregate`; `Aggregate`
  returns `NotImplemented` explicitly (`redis.rs`). Confirmed in the artifact: `oltp-matrix.json` →
  `redis.aggregate = {"observed":"unsupported","promised":false}`.
- **http** is the static-CRUD adapter: it serves the 6 single-row ops but **neither Batch nor
  Aggregate** — both are absent from `http.rs SUPPORTED_OPS` and the matrix marks http
  `"static-only (descriptor == SUPPORTED_OPS verified from source)"`.
- **dynamodb** serves Batch (`BatchWriteItem`) but **not Aggregate**; its transaction is a
  **buffer-then-commit** `TransactWriteItems` — write-only, atomic by construction (nothing leaves
  the process until `commit()`), so a partially-applied transaction is structurally impossible. It
  is opt-in behind a Cargo feature; the other 7 are default-on.
- **Full** multi-statement transactions (cross-request pinned `TxHandle`) exist **only on postgres
  and mysql**. mongo/mssql/sqlite/redis all return `NotImplemented` for `begin()` — and they say so:
  the refusal is **explicit and typed**, never a silent success. A single **Batch** is still atomic
  on sqlite/mssql (one underlying transaction), which is why the no-cross-request-tx engines can
  still do atomic multi-row writes.

The whole point of the matrix is that the ✗ cells are *declared and gated*, not discovered in
production. `oltp-matrix.json` records `"violations": 0` — descriptor and code agree on every cell.

**Source of truth:** per-adapter `SUPPORTED_OPS` in
`docker/services/data-plane-router/crates/data-plane-pool/src/{postgres,mysql,mongo,mssql,sqlite,redis,http,dynamodb}.rs`;
the uniform trait `EngineAdapter`/`EnginePool` in `…/crates/data-plane-core/src/ports.rs`; mount
name-routing in `…/data-plane-pool/src/registry.rs`; boot-time honesty check in
`…/data-plane-pool/src/capability_honesty.rs`.
**Proof:** `scripts/verify/m25-oltp-matrix.sh` + `mini-baas-infra/artifacts/oltp-matrix.json`.

---

## 2. Connect any engine / BYO

A tenant brings its own database; the control plane registers it as a **mount**. Registration is the
Go control plane's `adapterregistry` package
(`go/control-plane/internal/adapterregistry/{handler.go,models.go}`).

**The `allowedEngines` gate.** Registration is refused unless `r.Engine` is in `allowedEngines`
(`models.go`): `postgresql, cockroachdb, mysql, mariadb, mongodb, redis, sqlite, mssql, http`
(cockroachdb/mariadb are wire-compatible variants of the postgres/mysql adapters). An engine the
data plane does not understand cannot be mounted — the refusal is at the door, before any pool exists.

**Three credential modes** (each made unambiguous so a row is never "silently inline when a ref was
intended"):

| Mode | What it is | Where | Gate |
|---|---|---|---|
| **inline-enc** | A plaintext `connection_string` supplied at register time; stored encrypted (the pre-S2 baseline path, kept byte-parity). | `models.go` `ConnectionString` | `m25` exercises inline mounts |
| **Vault-ref** | A `credential_ref` pointing at a Vault path instead of an inline DSN — the secret never transits the registration API; a max-security tenant supplying inline plaintext is the case S2/G-Vault closes. | `models.go` `CredentialRefInput`; `handler.go` §S2 | `scripts/verify/m121-credref-vault-enforce.sh` |
| **CMEK / BYOK** | When `CMEK_ENABLED` is on and the caller supplies an **inline** DSN with a non-empty `KMSKeyID` (or the env default), registration routes the DSN through a CMEK envelope encrypted under the customer's KMS key (D4.8). | `models.go` `KMSKeyID` | `scripts/verify/m123-cmek-envelope.sh` |

`models.go` rejects the ambiguous combinations explicitly (`hasInline && hasRef` is an error;
`!hasInline && !hasRef` is an error), so every stored mount has exactly one credential provenance.

**Proof:** `scripts/verify/m121-credref-vault-enforce.sh`, `scripts/verify/m123-cmek-envelope.sh`;
source `go/control-plane/internal/adapterregistry/{handler.go,models.go}`.

---

## 3. Multi-DB & combination

There is **no cap on engine mix**. A single tenant can hold **N mounts** spanning any combination
of the allowed engines (e.g. postgres for relational + mongo for documents + redis for cache + an
external http API), because routing is **per request, per mount**: the request names a mount, the
registry resolves `mount.engine` to the adapter and `mount.tenant_id` to ownership, and the right
pool serves it (`registry.rs`). Mounts of different engines are completely independent.

The **only** ceiling is **per-tier `max_mounts`** — a commercial cap, not an engineering one — read
from `config/packages/packages.json` (`pool_policy`) and enforced in the Go `packages` manifest
gate. The same manifest gates *which* engines a tier may mount and caps the mount count; the config
source of truth and the embedded copy are held byte-identical.

**Cross-engine multi-mount is gate-proven.** `scripts/verify/m46-share-pools-isolation.sh` points two
`shared_rls` tenants at **one mysql backend and one mongo backend simultaneously** and proves all
three of: (a) no 502 — both tenants serve through the shared pool; (b) isolation — each tenant lists
only its own rows on both engines; (c) collapse — under `SHARE_POOLS=1` the two tenants share one
pool per engine. This is the live demonstration that the substrate routes a heterogeneous fleet
correctly.

**Proof:** `scripts/verify/m46-share-pools-isolation.sh`; tier cap in
`config/packages/packages.json` + `scripts/verify/m28-packages.sh`; routing in
`…/data-plane-pool/src/registry.rs`.

---

## 4. Isolation — four models, chosen per mount

Each mount declares an `isolation` field; the data plane parses it into `Isolation`
(`…/data-plane-router/crates/data-plane-core/src/isolation.rs`). The choice is **per mount**, so one
tenant can hold a shared-RLS mount and a dedicated-database mount at once. Unknown/empty values
degrade safely to `shared_rls` (never error). The control plane's `allowedIsolation` set
(`adapterregistry/models.go`) accepts all four.

| Model | What it does | Owner-scoping | Use |
|---|---|---|---|
| **`shared_rls`** *(default)* | One shared schema; rows separated by RLS + `owner_id`. The only strategy that existed pre-G5; the one that lets 10K tenants share one pool. | Yes — insert injects `owner_id`, update/delete filter on it, DDL synthesizes the column. | Massively multi-tenant, lowest footprint. |
| **`schema_per_tenant`** | A distinct schema per tenant (`tenant_<id>`); `search_path`/namespace pinned to it per request. | Yes | Stronger separation, still one database/pool family. |
| **`db_per_tenant`** | A distinct database/DSN per tenant; the resolver must supply a tenant DSN (no fall back to a shared one). | Yes | Hard physical separation per tenant. |
| **`tenant_owned`** | The mount **is** one tenant's database (an external client DB the platform dashboards — e.g. a customer's own Supabase project). No per-row `owner_id` scoping on writes and no `owner_id` DDL synthesis — the tables predate the platform and belong to the tenant wholesale. | **No** (by design) | BYO external DB the platform reads/writes as-is. |

**Why dropping owner-scoping on `tenant_owned` is still safe:** tenant gating already happened
*upstream* at key→mount resolution (`mount.tenant_id == caller tenant`); a foreign tenant's key
never resolves this mount at all, so there is no cross-tenant path to scope away (`isolation.rs`
SAFETY note).

**Honest gap:** `tenant_owned` is **not yet wired on mongo** — the model parses and works on the SQL
engines; the mongo adapter does not yet honour it. See §7.

**Proof:** `scripts/verify/m46-share-pools-isolation.sh` (live two-tenant isolation across engines);
source `…/data-plane-core/src/isolation.rs`, `…/adapterregistry/models.go`.

---

## 5. Permissions & RLS

Two enforcement layers, both gate-proven, with one honest depth gap.

**(a) Per-request owner-scoping / RLS.** Ownership is enforced **per request, not by pool state** —
this is what lets `SHARE_POOLS` collapse 10K tenants onto one pool. On postgres, every checkout calls
`apply_rls_context` (`postgres.rs`), setting the `app.current_tenant_id` (and `current_user_id`) GUCs
plus the `owner_id` predicate, both derived from the **request identity** — never from a pool field.
mongo similarly stamps `owner_id`+`tenant_id` from the request identity (the m46 fix that switched
mongo off the pool field). Because the scope is re-applied on every request, two tenants on one pool
never see each other's rows. **Proof:** `scripts/verify/m46-share-pools-isolation.sh` (cross-tenant
deny under a shared pool) + `scripts/verify/m12-tenancy.sh` (tenant-isolation RLS policies: Tenant A
registers a DB, Tenant B cannot see it).

**(b) Operation-level capability masking.** A tier can narrow what an engine is allowed to do.
`planner.rs apply_capability_overrides` intersects the engine's native capabilities with the tier's
overrides (e.g. `{"aggregate": false}`), and `tier_gate` returns `CapabilityGated` → **HTTP 403**
when the engine supports an op but the tier forbids it. This is how the same Postgres adapter serves
aggregate on a `pro` mount but 403s it on a lower tier. **Proof:** `scripts/verify/m28-packages.sh`;
source `…/data-plane-core/src/planner.rs`.

**Honest depth gap (ABAC).** Owner-scoping (subject == owner) is enforced and gate-proven, but the
**fine-grained ABAC** layer is not yet at depth: attribute *conditions* are effectively inert
(stored/parsed but not evaluated as a predicate against request attributes), and the API-key path is
the single authority rather than a full attribute-based PDP. This is the **ABAC closure workstream**
(a separate, tracked slice) — see §7 and the cross-track board (`.claude/plans/STATUS.md`). Until it
lands, treat permissions as *tenant + owner + tier-capability* enforcement, **not** condition-level
ABAC.

---

## 6. The density / latency moat

Measured on one box (`env.mem_total_mib = 31929`), same method against both stacks.

| Claim | Grobase | Supabase | Artifact + gate |
|---|---|---|---|
| **Full-platform footprint (RSS)** | **821.7 MiB** (essential edition) | **2884 MiB** | `artifacts/footprint-essential.json` (`ram_mib_total`), `bench/grobase-vs-supabase.json` (`supabase.total_rss_mib`), `bench/supabase-footprint-breakdown.txt`; gate `m32-footprint.sh` |
| **Minimal footprint (RSS)** | **309.8 MiB** (basic edition) | 2884 MiB | `artifacts/footprint-basic.json` (`ram_mib_total`); gate `m32-footprint.sh` |
| **Read latency p50 / p95** | **1.63 ms / 2.20 ms** | 1.51 ms / 2.57 ms | `bench/grobase-vs-supabase.json` (`grobase_postgrest.read_p50_ms` / `read_p95_ms`, n=60; same `curl GET /rest/v1/bench_items?limit=30`) |
| **At-rest tenant density** | **24,887 live tenants @ 2.6 MiB data plane, 0 standing pools** | — | `artifacts/scale/footprint-live-24887.json` (`tenants`, `rss_mib`, `pools_open`) |
| **Pool count ⟂ tenant count** | **~10K tenants → 1 pool, 0 server errors** | — | `scripts/verify/m46-share-pools-isolation.sh` + `bench/multitenant-10000-sharepools.json` (`tenants:9775`, `server_errors:0`) |

The read-latency line is honest both ways: at p50 Supabase is marginally faster (1.51 vs 1.63 ms);
at p95 Grobase is faster (2.20 vs 2.57 ms). The decisive, unambiguous wins are **footprint** (821.7
vs 2884 MiB full platform; 309.8 MiB minimal) and **density** (a ~25K-tenant fleet imposes no
standing memory cost beyond the binary baseline — `pools_open: 0`, lifetime `evicted: 0`). Pool
count being independent of tenant count is the architectural property that makes the density real.

**Reproduce:** `make bench-footprint` / `make -C ../.. baas-verify-m32` (footprint);
the vs-Supabase run produces `bench/grobase-vs-supabase.json`; the density probe is documented
inline in `scale/footprint-live-24887.json` (`docker exec … psql … count(*) from public.tenants`;
`docker stats`; `curl …/metrics | grep pools`).

---

## 7. Honest gaps

A frank list — each is a real limit of the current substrate, not a future-tense feature.

- **Engine-parity asymmetries are real** (and that is the *point* — they are declared, not hidden):
  - redis has **no Aggregate**; http has **no Batch and no Aggregate**; dynamodb has **no Aggregate**.
  - Full multi-statement **transactions exist only on postgres + mysql**. dynamodb has a
    write-only buffered transaction. mongo/mssql/sqlite/redis return `NotImplemented` for `begin()`
    (sqlite/mssql still give atomic single-Batch). A feature that needs cross-request transactions
    cannot be promised on those four engines.
  - dynamodb is opt-in (Cargo feature), not part of the default 7.
- **`tenant_owned` isolation is not yet wired on mongo** — works on the SQL engines; the mongo
  adapter does not honour it yet (§4).
- **ABAC depth is shallow.** Owner-scoping + tier-capability gating are enforced and gated, but
  attribute **conditions are effectively inert** and the API-key path is the single authority — there
  is no condition-level attribute PDP yet. This is the **ABAC closure workstream** (separate, tracked
  slice; `.claude/plans/STATUS.md`). Do not claim condition-level ABAC today.
- **No fine-grained dynamic builder yet.** Today the product ships **static editions** (lean, query,
  realtime, analytics, prod, full) and **5 named tiers** (nano / basic / essential / pro / max, from
  `config/packages/packages.json`). A self-service **dynamic builder** (operator- and tenant-driven
  composition of engines × isolation × capabilities into an arbitrary custom shape) is a **separate
  workstream**, not part of this substrate yet.
- **mongo lacks cross-request transactions** specifically because session-threading is a pending
  refactor — its single-document atomicity holds, but multi-document multi-request transactions do
  not (named in `mongo.rs`).

---

## 8. How to reproduce

All commands run with the BaaS stack up (Docker-first). Milestone wrappers come from the **repo-root**
Makefile (`make baas-verify-mN`); the verify scripts also run directly.

| Claim (section) | Gate script | Wrapper / make target | Artifact |
|---|---|---|---|
| Engine × op matrix, capability honesty (§1) | `scripts/verify/m25-oltp-matrix.sh` | `make baas-verify-m25` | `artifacts/oltp-matrix.json` |
| Per-engine `SUPPORTED_OPS` (§1) | (read source) | — | `…/data-plane-pool/src/<engine>.rs` |
| BYO Vault-ref credential (§2) | `scripts/verify/m121-credref-vault-enforce.sh` | — | — |
| BYO CMEK / BYOK envelope (§2) | `scripts/verify/m123-cmek-envelope.sh` | — | — |
| Multi-DB / cross-engine multi-mount + tier cap (§3) | `scripts/verify/m46-share-pools-isolation.sh`, `scripts/verify/m28-packages.sh` | `make baas-verify-m28` | `bench/multitenant-10000-sharepools.json` |
| 4 isolation models, cross-tenant isolation (§4) | `scripts/verify/m46-share-pools-isolation.sh` | — | — |
| Per-request RLS / tenant isolation (§5) | `scripts/verify/m12-tenancy.sh`, `scripts/verify/m46-share-pools-isolation.sh` | `make baas-verify-m12` | — |
| Operation-level capability masking → 403 (§5) | `scripts/verify/m28-packages.sh` | `make baas-verify-m28` | — |
| Footprint moat (§6) | `scripts/verify/m32-footprint.sh` | `make bench-footprint` / `make baas-verify-m32` | `artifacts/footprint-{essential,basic}.json`, `bench/grobase-vs-supabase.json`, `bench/supabase-footprint-breakdown.txt` |
| Read p50/p95 vs Supabase (§6) | (vs-Supabase bench run) | — | `bench/grobase-vs-supabase.json` |
| 24,887-tenant density (§6) | (live probe, documented inline) | — | `artifacts/scale/footprint-live-24887.json` |
| Engine conformance battery (cross-cutting) | `scripts/verify/m27-conformance.sh` | `make conformance` / `make conformance-<engine>` | — |

To run a single gate directly:

```bash
bash mini-baas-infra/scripts/verify/m25-oltp-matrix.sh
SHARE_POOLS_PROBE=1 SHARE_POOLS_EXPECT=1 bash mini-baas-infra/scripts/verify/m46-share-pools-isolation.sh
make -C ../.. baas-verify-m32        # footprint moat
```

---

*Last updated: 2026-06-15. Every numeric value and capability claim in this document cites a gate
script under `mini-baas-infra/scripts/verify/` or an artifact under `mini-baas-infra/artifacts/`
that exists at the time of writing. If a cited gate or artifact is removed, this doc is stale —
re-confirm before re-citing.*
