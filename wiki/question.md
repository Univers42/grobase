# Architecture Q&A — the honest jury walkthrough

This is the document I'd hand a jury (or a curious engineer) who wants to *really*
understand Grobase — not the brochure, the real thing. The house rule everywhere here is
**measured, not claimed**: numbers come with an artifact or a make target, and where
something is unfinished or a genuine weakness, I say so plainly. A jury trusts the person
who volunteers the limitation more than the one who only lists wins.

> **TL;DR of the philosophy:** Grobase is *one* backend that speaks to *any* database, with
> tenant isolation enforced on *every request* instead of by spinning up a server per
> project. That single idea — identity travels with the request, not the connection pool —
> is what lets the same codebase be a 5 MB binary on a Raspberry Pi *and* a 10,000-tenant
> platform, with no rewrite in between.

---

## Part 1 — Positioning & the core idea

### What problem does Grobase solve that the others don't?

Most BaaS platforms give you **one backend per project**. Supabase spins up a Postgres +
PostgREST stack per project; Firebase gives you a Firestore instance; Appwrite a container
set. That's great until you want to host *thousands* of small tenants cheaply, or you
already have a MySQL/Mongo/SQL Server database you can't migrate.

Grobase's bet is different and combines three things none of the big four do together:

1. **Bring-your-own-database, multi-engine.** Eight engine adapters live in
   `data-plane-pool/src/`: `postgres mysql mongo mssql sqlite redis http dynamodb`. You can
   point Grobase at a database you *already* run (`tenant_owned` isolation wraps it) instead
   of migrating into ours. Supabase is Postgres-only; Firebase is Firestore-only.
2. **Dense multi-tenancy on shared infrastructure.** Measured: **~10K `shared_rls` tenants →
   1 pool, 0 evicted, ~30 MiB RSS** (gate m46), and **24,887 tenants held at rest in 2.6 MiB
   with zero standing pools** (`wiki/operations/scale-slo.md`). The competitors' per-project
   model simply can't do that.
3. **One codebase, nano → max, no rewrite.** The same Rust binary compiles to a **5.16 MB**
   SQLite-only "nano" image *or* a full 8-engine platform — feature flags, not forks.

So the honest one-liner: **if you want a self-hostable backend that fronts many databases
and many tenants cheaply, Grobase is built for exactly that.** If you want a polished managed
cloud with a big ecosystem *today*, see the next answer.

### Why choose it over Supabase / Hasura / Appwrite / Firebase — and where they still win

I'll do the part juries respect most: **where we honestly lose.**

- **Supabase** wins today on Studio polish, a mature managed cloud, and the extension
  ecosystem. We're ~3.5× lighter to self-host (`grobase-essential` 821 MiB vs Supabase
  self-host 2,884 MiB) and multi-engine — but their cloud is GA and ours isn't yet.
- **Hasura** wins on GraphQL depth. Our GraphQL is **Postgres-only** (it's `pg_graphql`) and
  ships as an opt-in edition — Hasura's whole identity is richer there.
- **Firebase** wins on mobile-first realtime and offline sync maturity. Our DB-change
  `subscribe()` is currently **Mongo-only** and presence is single-node-authoritative.
- **Appwrite** wins on a batteries-included console + a longer track record.

Where *we* win: multi-engine + BYO-database, isolation **choice** (4 models per mount),
density/cost at idle, and the no-rewrite grow path. That's the `/compare`-style honesty
the roadmap holds us to (`wiki/competitive/competitive-matrix.md`).

### What's the core architectural idea, and why is each component separate?

The core idea is a **three-language, three-plane** split where the planes talk over **HTTP
contracts (JSON envelopes + an HS256 JWT)** — never shared memory, never a shared database.

| Plane | Language | Job |
|---|---|---|
| **Application** | TypeScript / NestJS (`src/apps/*`) | Business rules that change often — query-router, permission-engine, schema-service, email, gdpr… |
| **Control** | Go (`src/control-plane/`, ~30 `internal/` pkgs) | Always-up daemons: tenancy, provisioning, key-verify, webhooks, metering, billing, backup |
| **Data** | Rust (`src/data-plane-router/` + realtime) | Execute the query, own the pools, owner-scope **per request** |

They're separate for one practical reason: **each plane has a different failure mode and a
different change cadence.** Business logic changes weekly (TS, easy to iterate). Control-plane
daemons must never go down (Go, boring and robust). The data path must be fast and
predictable under load (Rust, no GC pauses). Bolting them into one process would force the
slowest-changing, most-safety-critical code to redeploy every time a DTO changes. The HTTP
seam means I can ship the data plane as a 5 MB binary *or* as a shadow alongside the legacy
TS path during migration. **Separation is what makes the no-rewrite grow path possible.**

---

## Part 2 — The language choices (the deep version)

### Why Rust? Which component uses it? Why wasn't Go enough?

**Rust runs the data plane** (`src/data-plane-router/`, the 8 engine adapters) and the
realtime event router. This is the *hot* path — it runs on every single read and write.

Go would have been *fine* here, honestly — it's fast. The reason it "wasn't enough" is the
**tail**, not the median. The data plane holds long-lived connection pools and serves 10K+
tenants from them; under that load a GC pause is a latency spike that lands on a real user's
write. Rust gives us:

- **A predictable tail with no GC.** Measured warm read **p95 ≈ 2.4 ms**, and the density
  numbers above (24,887 tenants at rest in 2.6 MiB) come straight from zero-GC, no-per-tenant
  allocation design.
- **A 5 MB static binary.** The nano edition is `FROM scratch` — a single musl-static Rust
  binary, no libc, no shell. You can't ship that from Go without a much larger runtime.

### What do ownership & memory safety actually buy you here?

Concretely, two things that matter for a multi-tenant data plane:

1. **No tenant data bleeds between requests, enforced by the type system.** The owner-scoping
   identity is *moved* into each operation; you can't accidentally reuse a previous request's
   identity because the borrow checker won't let a value outlive its scope. Isolation bugs are
   the scariest class in multi-tenancy, and ownership turns a whole category of them into
   compile errors.
2. **Pools without data races.** The pool registry pins a connection while a transaction is in
   flight (`registry.rs`: `tx_pins`) and never evicts it — and the compiler guarantees the
   shared state is accessed safely. We get aggressive pool reaping (to hit that 2.6 MiB idle)
   *and* safety, which is exactly the combination that's hard to get right by hand in C.

### Why Go? Why not write everything in Rust? What workload is Go handling?

Go handles the **control plane**: provisioning a tenant, minting/verifying API keys, dispatching
webhooks, running the orchestrator reconcile loop, metering, billing. The shape of that work is
*"lots of small, idempotent HTTP/SQL calls on a service that must always be up."*

Why not all-Rust? Two honest reasons:

- **Development velocity for glue.** The control plane is broad (30 packages) and changes as we
  add cloud/enterprise features. Go's fast compile, goroutines, and batteries-included stdlib
  make that breadth cheap. Rust's strictness is a *tax* you want to pay on the hot path, not on
  every webhook handler.
- **It's not on the latency-critical path.** The control plane is called once per key-verify
  (then cached for 30 s) and once per provision — not per query. Spending Rust's rigor there
  would buy us almost nothing while slowing the team down. Right tool, right plane.

(There *is* a documented plan to fold the 6 Node orchestrators into one Go binary — saving
~359 MiB — which is itself a "Go is the right home for glue" decision.)

### Why TypeScript? Why not a Rust frontend API? What did TS buy you?

TypeScript/NestJS is the **application plane** — the API surface and the business rules. We
chose it for the un-glamorous but real reason: **the rules change constantly and TS lets us
change them safely and fast.** NestJS's DTO/guard/interceptor model expresses
validation/authz/transformation cleanly, the SDKs mirror the same types, and the ecosystem is
enormous.

Why not a Rust frontend API? Because the API layer's bottleneck is *human iteration speed*,
not CPU. A Rust API would make every "add a field to this endpoint" change a fight with the
borrow checker for zero latency benefit (the heavy lifting is already in the Rust data plane
behind it). The split lets each layer optimize for what actually constrains it: TS for change,
Rust for speed.

---

## Part 3 — Schemas & types across engines

### How are schemas represented internally? What's the canonical model?

There's a single **engine-agnostic canonical model**: `SchemaDescriptor` in
`data-plane-core/src/schema.rs`. Every engine maps *to* and *from* it.

```rust
pub struct SchemaDescriptor { pub engine: String, pub tables: Vec<TableSchema> }
pub struct TableSchema { pub name: String, pub primary_key: Vec<String>, pub columns: Vec<ColumnSchema> }

pub enum NormalizedType {            // the 11-type lingua franca
    Text, Integer, Float, Decimal, Boolean, Date, Datetime,
    Json, Uuid, Enum, Array, Objectid, Unknown,
}
```

Every column carries both its **native** type name and the **normalized** type. That's the
canonical model: 11 normalized types that all eight engines translate through.

### How do you map PostgreSQL types to MySQL types?

Not directly — *through the canonical model*. PG → `NormalizedType` → MySQL. So `int4`
normalizes to `Integer`, and `Integer` renders to MySQL `BIGINT`:

```rust
// postgres/ddl.rs        "int2"|"int4"|"int8" => NormalizedType::Integer
// mysql/schema.rs        NormalizedType::Integer => "BIGINT"
// mysql/schema.rs        NormalizedType::Json    => "JSON"   (PG side: "jsonb")
```

The win of going through a canonical type is that adding a 9th engine is *one* normalizer +
one renderer, not an N×N matrix of pairwise mappings.

### What happens when a feature exists in PostgreSQL but not MySQL?

This is the part I'm proudest of, because it's *honest by construction*. Each engine
publishes an `EngineCapabilities` descriptor (`capability.rs`), and the planner gates every
operation against it. The caller gets a **precise, distinct error**:

```rust
UnsupportedCapability { engine, capability }  // → 422  "this engine genuinely can't"
CapabilityGated       { capability }          // → 403  "your tier doesn't include it"
```

So a `transactions` request to Mongo returns **422** ("mongo's `begin()` is NotImplemented"),
while an `aggregate` request on a tier that doesn't include aggregates returns **403**. Two
different problems, two different status codes — the caller always knows whether to upgrade
their plan or change their engine.

And there's a **test that makes the descriptor unable to lie** (`capability_honesty.rs`): it
asserts, for every engine and every op, that what the descriptor *advertises* exactly matches
what the adapter *implements*. Drift is a failing test, not a production surprise.

### How do you handle JSON columns? And enums?

- **JSON:** `jsonb` in PG, `JSON` in MySQL, native BSON `object` in Mongo, TEXT-affinity in
  SQLite — all normalize to `NormalizedType::Json`, and the renderer picks the right native
  type per engine.
- **Enums:** each engine gets its *idiomatic* representation from the same `enum_values` list —
  PG creates a named `CREATE TYPE … AS ENUM`, MySQL emits `ENUM('a','b')`, Mongo writes an
  `{"enum": [...]}` JSON-schema validator, and SQLite uses `TEXT CHECK (col IN (...))`. Same
  intent, four faithful translations.

**Honest gaps:** arrays are `text[]` in PG and fold into `JSON` in MySQL (v1 — element typing
is a follow-up); SQLite can't `ALTER COLUMN` type (it returns a 400 telling you to
copy-and-swap); `Objectid`/`Unknown` are describe-only and rejected at DDL. None of these are
hidden — they're explicit errors with messages that tell you what to do.

---

## Part 4 — Migrations

### What happens on partial success? Do you roll back? Is rollback guaranteed? Can it fail?

The honest answer is **per-engine**, and I won't pretend it's uniform:

- **PostgreSQL:** the modern migrations (015+) wrap their body in `BEGIN … COMMIT`, and
  Postgres DDL is transactional — so a mid-migration failure **rolls back atomically** to the
  previous version, and the runner uses `psql -v ON_ERROR_STOP=1` + a `set -e` loop to stop at
  the first failure. For those, **yes, rollback is guaranteed by Postgres' transactional DDL.**
- **The caveat I'd volunteer:** the *early* migrations (001–014) are bare SQL with no
  `BEGIN/COMMIT`. A crash mid-001 could leave a partial state. They lean on idempotent
  `IF NOT EXISTS` so a re-run recovers — but that's "recoverable by re-run," not "atomic."
  If I'm being self-critical, retrofitting those in a transaction is a real to-do.
- **MongoDB:** no transaction wrapper at all — sequential commands, recovery is by idempotent
  re-run, not rollback. So **rollback can absolutely "fail" on Mongo** in the sense that it
  doesn't exist; we rely on the operations being safe to repeat.

### How do you handle rollback (the schema kind)?

**Migrations are forward-only.** Every modern migration *contains* a `-- DOWN (manual, gated)`
block, but it's **commented out** — there's no `make rollback`. That's a deliberate choice:
the cloud/enterprise migrations are **additive and flag-gated OFF by default** (e.g.
`042_tenant_backups.sql` literally notes it changes *no* existing behavior and the table stays
empty until `TENANT_BACKUP_ENABLED` is flipped), so applying a migration is a no-op on live
behavior until you opt in. The real rollback path for *data* is **per-tenant backup/restore**
(`tenant_backups` ledger + `internal/backup/restore*.go`), not schema reversal. Honest
limitation: there is **no automated schema rollback** — additive-by-design is the mitigation.

### How do you know which migrations ran? Do you store migration state? What if it's corrupted?

PostgreSQL stores state in a **`schema_migrations` table** (`version` PK + name + applied_at),
and every migration self-guards: `IF EXISTS (SELECT 1 FROM schema_migrations WHERE version=N)
THEN RETURN; … INSERT … ON CONFLICT (version) DO NOTHING`. So re-running the whole suite is
safe and ordered (lexicographic by the zero-padded numeric prefix). If the **history were
corrupted**, the idempotent DDL is the safety net — `CREATE TABLE IF NOT EXISTS`,
`DROP POLICY IF EXISTS` mean re-applying is non-destructive; you'd reconcile by re-running and
letting `ON CONFLICT` no-op the already-present rows. **Honest gap:** Mongo and MySQL have *no*
version-tracking table — they rely purely on idempotent operations, so on those engines "which
migrations ran" isn't recorded, just safe to repeat. (Their migration sets are tiny — 4 and 1
files — so the blast radius is small, but it's an asymmetry I'd flag.)

---

## Part 5 — Docker images

### How much smaller? What base image — Alpine, distroless, or scratch? Why?

Different images, different bases, all measured:

| Image | Base | Size | Why |
|---|---|---|---|
| **nano data plane** | **`scratch`** | **5.16 MB** | A single static musl Rust binary *is* the image — no OS, no shell, no package manager. SQLite compiled in via a cargo feature; size-tuned profile (`opt-level=s`, fat LTO, `panic=abort`). |
| **one** (nano + auth) | `scratch` | 6.41 MB | + argon2id/JWT/SMTP/TOTP/thumbnails |
| **full router** | **distroless** `cc-debian12:nonroot` | ~47 MiB | All 8 engines need glibc; distroless gives glibc with no shell/tools |
| **NestJS services** | **Alpine** (`node:20-alpine`) | — | Node needs a base; Alpine is the slim one |

For context, PocketBase is **30.1 MB** — nano is **~5.8× smaller** (`make nano-build` prints
the live size; figures in `wiki/competitive/nano-vs-pocketbase.md`). The base choice is "the
smallest thing that still runs": scratch when we ship a static binary, distroless when we need
glibc, Alpine when we need a Node runtime.

### What did you actually remove (NestJS image)?

In the runtime stage of `src/Dockerfile`: the **npm/npx tree is deleted**
(`rm -rf /usr/local/bin/npm /usr/local/bin/npx /usr/local/lib/node_modules/npm` — *"runtime
doesn't need build tooling, and shipping it ships scanner-visible CVEs"*), dev dependencies are
pruned (`npm prune --omit=dev`), and `apk --no-cache upgrade` patches the base OS CVEs.

### Are containers running as root?

Mostly **no** — the NestJS runtime adds `adduser -S appuser` and runs as it; nano/full run as a
non-root user (distroless `:nonroot`). The honest exceptions are infrastructure images that
*need* root by design: the official Postgres image (its entrypoint drops to the `postgres` user
itself via gosu), promtail (it reads root-owned container logs), and the ephemeral test runner.
Those are documented in-line (`# nosemgrep` with a reason), not silently ignored.

### How are secrets injected, and what prevents credential leakage?

Secrets are **generated, never committed** — `scripts/env/generate-env.sh` mints high-entropy
values into `.env.secrets` (mode 600, gitignored), assembled into `.env` and injected as
container env. Tenant *database* credentials never touch env at all: they're **AES-256-GCM
encrypted at rest** (see Part 7). Leakage prevention: a CI secret-scan (`check-secrets.sh`) +
Semgrep/TruffleHog gates, the cleartext DSN is **never logged** and **never leaves the control
plane**, and under `SECURITY_MODE=max` the service *fails to boot* if the encryption key is a
known placeholder or smells non-Vault.

---

## Part 6 — Scaling: what breaks first?

A strong answer names the bottleneck, so here's mine, in order:

1. **Provisioning, not serving, is the first wall.** The honest #1 historical bottleneck was
   **API-key verification** — it used argon2id (32 MiB + ~50 ms per hash, only 2 concurrent),
   so a 10K-tenant cold fan-out flooded tenant-control into 502s. The serving path was always
   fine; *minting and verifying keys* was the throttle. We fixed it: API keys are 160-bit random
   tokens, so a password hash buys zero security — we switched to **fast SHA-256 + a 30 s verify
   cache**, microseconds and unbounded concurrency (**5.8× faster cold path, 10× fewer 5xx**).
   That's the "the scheduler/verifier breaks before the adapters do" insight in practice.
2. **The write tail is the current named enemy.** Reads are flat (p95 2.4 ms); inserts spike to
   **p99 ≈ 583 ms** because the outbox-CDC write is synchronous. The batched background outbox
   targets it; the at-scale write SLO isn't separately published yet.
3. **Pool thrash if you misconfigure isolation.** We *found* this on 2026-06-15: with
   `SHARE_POOLS` **off** (the parity-safe default), a 9,775-tenant zipf load opens a pool per
   tenant, an LRU caps it at ~256, and requests landing on an evicting pool 5xx. `SHARE_POOLS=1`
   (the scale overlay) collapses them to one pool → `server_errors: 0`. The bottleneck is real;
   the fix is a flag we now document loudly.

What does *not* break first: the engine adapters themselves and read latency. So if a jury
asks "what breaks first," the answer is **the key-verify/provision path and the write tail —
not the data adapters.** "It'll scale" would be the wrong answer; *this* is where it strains.

---

## Part 7 — Reliability, recovery & security (the user-connects-their-DB case)

### What happens if a service crashes mid-migration? If the DB connection dies? Can jobs resume?

- **Crash mid-migration:** for the transactional (015+) migrations, Postgres rolls the
  in-flight one back — you restart at a clean version. (Early migrations: see Part 4's honest
  caveat.)
- **Dead DB connection:** the Rust pool (deadpool) checks out a fresh connection per request;
  a dead one surfaces as a clean backend error and is replaced on next checkout — and the
  registry **never evicts a pool with an in-flight transaction** (`tx_pins`). The pool
  self-heals. Errors are *classified*, too: a constraint violation is a **409** (the caller's
  fault), not a 5xx, so a dead-connection 5xx is distinguishable from a bad-write 409.
- **Resumable jobs:** yes, by design. The **transactional outbox** relays with
  `FOR UPDATE SKIP LOCKED` + a status FSM (`pending→published→failed→dead`), so multiple
  workers never collide and a restart just re-scans. **Backups** record `pending` *before*
  doing work and flip to `completed`/`failed`. The **scheduler** is scan-based (`WHERE next_run
  <= now()`), so a restart re-scans due jobs — no in-memory job state to lose. Nothing
  important lives only in RAM.

### How are tenant DB credentials stored? Encrypted? Who can decrypt?

```sql
-- tenant_databases: connection string never stored in cleartext
connection_enc BYTEA, connection_iv BYTEA, connection_tag BYTEA  -- AES-256-GCM
```

Stored **AES-256-GCM encrypted at rest** (`internal/adapterregistry/crypto.go`), with a
per-record key derived via `scrypt(VAULT_ENC_KEY, salt)`. **Only the Go adapter-registry
decrypts** — the data plane *never* sees the cleartext DSN, and the DSN is never logged. The
master key (`VAULT_ENC_KEY`) comes from Vault, and under `SECURITY_MODE=max` the service
**refuses to boot** with a placeholder/weak/non-Vault key. There's even a stronger mode (CMEK):
the DSN is encrypted under a customer-held KMS key, so **revoking the KMS key crypto-shreds**
the data — the operator literally can't decrypt it.

### Can one tenant affect another? How do you enforce separation?

This is the heart of the design: **isolation is enforced per request, not by pool state.** On
Postgres, every request sets transaction-local GUCs and RLS does the rest:

```rust
// postgres/tx.rs — set on EVERY request, transaction-local
"SELECT set_config('app.current_tenant_id', $tenant, true),
        set_config('app.current_user_id',  $principal, true), ..."
```

```sql
-- RLS policy: a row is only visible to its tenant
CREATE POLICY ... USING (tenant_id::text = auth.current_tenant_id()::text)
```

Plus a defense-in-depth ` AND owner_id = $n` predicate injected into every owner-scoped
write. Because the identity rides the *request*, `SHARE_POOLS` can collapse 10K tenants onto
one connection pool and they're **still** isolated — the pool holds no tenant state. Gate m46
proves cross-tenant denial at 10K; the self-serve API has **no `{id}` in the path**
(`/v1/tenants/me*`), so cross-tenant access is impossible by construction.

**The one honest gap:** `tenant_owned` mounts (a customer's *own* pre-existing DB) skip the
`owner_id` injection — the tables aren't ours, so the guard is at key→mount resolution instead.
If a key were mislabeled to the wrong mount, there's no row-level net beneath it. It's a
deliberate trade (you can't inject a column into someone else's schema), but it's the spot I'd
point a security reviewer at first.

---

## Part 8 — Observability

### How do you debug a production failure? What metrics? What logs matter?

Everything is **structured JSONL** with a `request_id` that threads through every service
(slog in Go, pino in TS) → promtail → Loki, queryable with `| json | tenant_id="X"`. Crucially,
`tenant_id` is a **log field, never a Prometheus/Loki label** — promoting it to a label would
create one stream per tenant and melt at 10K. The same discipline applies to metrics: there's a
per-tenant request counter **hard-capped at 512 distinct series** (`_over_cap` sentinel beyond
that), so cardinality is provably bounded regardless of tenant count.

Metrics that matter: `baas_http_requests_total{status="2xx|4xx|5xx"}`, the outbox health
counters (`enqueued|written|dropped|failed`), pool counts, and verify/mount cache hit rates.
The alert rules (`platform.yml`) fire on **5xx ratio > 5%**, **outbox drops (immediately —
that's data loss)**, pool saturation, and webhook retry storms.

The logs that matter most in practice are exactly the ones tonight's debugging used: the
**auth/verify line** (did the key resolve? did the verify time out?) and the **5xx with the
unhandled-error field** (which gave me `getaddrinfo EAI_AGAIN adapter-registry` — see Part 9).
**Honest gap:** RLS denials surface as SQLSTATE `42P01/42703` folded into "invalid request" —
there's no dedicated `rls_denied` metric yet, which would make isolation debugging easier.

---

## Part 9 — Tradeoffs & the hardest question

### What's the worst design decision? If you had six months, what would you redesign?

The honest worst decision: **carrying the TS data-plane and the Rust data-plane in parallel for
so long.** The shadow→parity→cutover discipline is *correct* — you don't delete working code
until the replacement is proven at m18 + parity + CI-green — but the cost is real
dual-maintenance debt and a forest of feature flags. With six months I'd:

1. **Finish the TS→Rust cutover and delete the legacy path** (it's retained behind the gate
   today, not deleted), and fold the 6 Node orchestrators into the one Go binary (−359 MiB).
2. **Make `SHARE_POOLS=1` and fast-hash the *defaults*, not overlays** — the parity-safe
   defaults are the ones that bit us under load.
3. **Retrofit the early migrations into transactions** and give Mongo/MySQL a real
   `schema_migrations` ledger, closing the asymmetry in Part 4.
4. **Measure the 100K load SLO on a quiet node** and stand up the uptime probe — today those
   are *modeled*, not measured, and I'd rather have the number.

### Tell me about a major failure — how you found it, debugged it, root-caused it, fixed it, and prevented it

This one's fresh, because it happened *building this very document's stack back up*, and it's a
textbook layered failure. The `make tests` Postman suite was failing, and it turned out to be
**four bugs stacked on top of each other**, each hiding the next:

1. **Symptom → 401.** Provisioning a tenant key and immediately using it returned
   `401 invalid_api_key`. **Discovery:** the tenant-control log showed it *minting* the key
   (`201`) and then *rejecting its own key* (`/v1/keys/verify → 401`, `ms:0`) milliseconds
   later. **Debug:** `ms:0` meant it failed *before* the DB lookup — a service-auth rejection,
   not a key mismatch. **Root cause:** an env regeneration had rotated the inter-service HMAC
   token, but only *some* services restarted — query-router signed with the new token while
   tenant-control still verified with the old one. **Fix:** realign every service to one token.
   **Prevention:** the lesson is "after a secret regen, recreate the *whole* service layer, not
   a subset" — now written into our memory notes.

2. **Symptom → 500 `identity_unavailable`.** With the token fixed, the next layer appeared: the
   data path returned `500 identity_unavailable`. **Debug:** grepped the error string to
   `api-key.middleware.ts` → *"identity signing key not configured."* **Root cause:**
   `INTERNAL_IDENTITY_HMAC_KEYS` — the key the middleware uses to *sign* the downstream identity
   envelope — was **never generated**. The whole api-key flow had never been able to sign; JWT
   flows masked it. **Fix:** add it to `generate-env.sh` (so it's minted forever after) and into
   the running env.

3. **Symptom → 500 `getaddrinfo EAI_AGAIN adapter-registry`.** Now the DDL reached a *different*
   500. **Debug:** the unhandled-error log line named the exact failure — query-router couldn't
   resolve the hostname `adapter-registry`. **Root cause:** the lean restructure renamed the
   service to `adapter-registry-go` (the TS one was retired), the compose files were updated to
   default to `adapter-registry-go:3021`, but **`config.env` still pinned the stale
   `adapter-registry:3020`** and overrode the default — wrong host *and* wrong port. **Fix:** one
   line in `config.env`. **Prevention:** the comment now in `config.env` explains exactly why,
   so the next person doesn't re-stale it.

4. **Symptom → 503 verify timeout.** The last layer: a wedged keep-alive connection from all the
   container churn made the cold verify time out at 8 s. **Fix:** a clean restart of the two
   services cleared it, and the DDL finally returned **201**.

What I changed to prevent recurrence: the two missing/stale config values are now in the
*generators and committed config* (not just the running env), each with a comment explaining the
trap, and the debugging itself is captured in project memory. The meta-lesson — and the thing I'd
tell a jury — is that **the structured `request_id` + the unhandled-error log field is what made
a four-layer failure tractable.** Each layer named its own root cause in one log line. That's not
luck; it's the observability design from Part 8 paying for itself.

---

*Reproducibility: perf numbers come from `wiki/operations/scale-slo.md` &
`wiki/competitive/*`; image sizes from `make nano-build`/`one-build`; capability/type behavior
from `data-plane-core/src/{schema,capability}.rs` and the per-engine adapters; the failure
story above from this repo's own service logs and the fixes in `config.env` /
`scripts/env/generate-env.sh`.*
