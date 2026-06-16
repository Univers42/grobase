# Nano Edition — the single-binary, PocketBase-class tier

The floor below [`basic`](./service-tiers.md): **one static Rust binary, embedded SQLite, no
separate processes.** This is the tier for a landing page, a prototype, a single small app — the
people who reach for PocketBase. The goal is to **match PocketBase's rock-bottom cost and single-file
simplicity, beat its performance, and add the features it structurally can't have** — while keeping a
non-dead-end path up to the cloud tiers (`basic → max`) on the *same codebase*.

Every number below is grounded in a live measurement or a cited source; projections are labelled as
such. "Real, not marketing" is the bar.

---

## 1. What we're up against (measured reality, not slogans)

**PocketBase** ([pocketbase.io](https://pocketbase.io/faq/)): Go + `modernc.org/sqlite` — a
**pure-Go SQLite** (C transpiled to Go, no cgo). One binary: REST + SQLite + auth + file storage +
realtime (SSE) + an embedded Svelte admin. A `goja` JS VM powers hooks.

| PocketBase | Figure |
|---|---|
| Binary (standalone) | **30.1 MB measured** (v0.39.3 unzipped; the oft-quoted "~15 MB" is the zip / older releases — [faq](https://pocketbase.io/faq/)) |
| Binary (as a Go framework + your code) | ~50 MB |
| RAM idle | **~12 MB measured** (v0.39.3; "~20 MB" commonly reported) |
| RAM under load (100k-row bench) | 90–150 MB |
| SQLite driver | **pure-Go (`modernc`)** — portable, but slower than C SQLite |
| Engines | **SQLite only, forever** |

**TrailBase** ([trailbase.io](https://trailbase.io/reference/benchmarks/)) — the honest prior art:
it is *already* a Rust + **C-SQLite** PocketBase alternative, and it proves the thesis that the
language/driver choice is worth real money:

| TrailBase vs PocketBase (their bench) | Result |
|---|---|
| Insert throughput (100k) | **~11× faster** |
| Read / insert latency | **~5× lower**, "sub-millisecond reads" |
| RAM under load | 90–150 MB (same class as PocketBase) |
| Stack | **Rust + C SQLite + WASM** |

**The honest takeaway:** "Rust + C-SQLite beats Go + pure-Go-SQLite" is *settled* — TrailBase already
demonstrates ~10× on micro-benchmarks. So our nano edition does **not** get to claim "we invented the
fast SQLite backend." Our edge over **both** PocketBase and TrailBase is the **feature set and the
graduation path** (below), riding the same Rust performance class — not a novel speed claim.

---

## 2. Why this is mostly *assembly*, not *invention*

The expensive part already exists and is measured:

- **The data plane is built and tiny.** `data-plane-router-rust` serves the full `/data/v1` surface —
  CRUD, schema, DDL, **graph/subgraph**, **ABAC + field masks**, owner-scoping, per-tenant
  token-bucket rate limits — and idles at **3.3 MiB RSS** (measured, `make bench-footprint`).
- **The SQLite engine is in-process already.** `rusqlite` with `bundled` (real C SQLite, WAL,
  file-per-mount) runs *inside* that 3.3 MiB process — **0 MiB of its own**, no server.
- **Today's compiled binary is 29 MB** (`30,326,296` bytes), and that's the *un-optimized ceiling*:
  it links **all nine** engine drivers (mongodb, tiberius/MSSQL, mysql, redis, postgres, http, …) and
  builds with **default release flags** — the workspace has **no `[profile.release]`** block at all
  (no `strip`, no `lto`, no opt tuning), dynamically linked to glibc.

So "nano" is: **take what's shipped, feature-gate it down to SQLite, absorb auth in-process, embed a
UI, and compile it small.** That's an integration + packaging job, not a green-field backend.

---

## 3. Architecture — one process, four parts

```
┌─────────────────────────────────────────────────────────┐
│  binocle-nano   (one static musl binary, FROM scratch)   │
│                                                          │
│  axum HTTP ──► /data/v1  (CRUD · schema · ddl · graph)   │  ← reuse data-plane-server
│            ──► /auth     (Argon2id verify · JWT issue)   │  ← absorb, in-process
│            ──► /_/        (embedded admin UI, brotli)     │  ← served from memory
│                                                          │
│  rusqlite (bundled C SQLite, WAL, file-per-mount)        │  ← 0 extra process
│  [optional] tokio-postgres feature ─► external Postgres  │  ← the graduation hook
└─────────────────────────────────────────────────────────┘
        one file · one port · one SQLite file on a volume
```

- **HTTP + data:** reuse `crates/data-plane-server` (`run_query`, `run_describe_schema`,
  `run_apply_schema_ddl`, `graph.rs`) behind axum — already the `/data/v1` handlers.
- **Auth absorbed:** today `auth.rs` *calls* Go `tenant-control` over HTTP for the Argon2id key
  verify. Nano swaps that one reqwest hop for an **in-process** `argon2`-crate verify against a local
  `_keys` table + `jsonwebtoken` for JWT. No gotrue, no Go control plane, no network hop.
- **Admin UI embedded:** ship a *small* SPA as `include_bytes!` brotli blobs, served from memory
  (PocketBase does exactly this with Svelte). **This is the main size variable — see the caveat.**
- **Engine-agnostic by feature flag:** default build = `sqlite`. A `--features postgres` build (or a
  runtime mount DSN) lets the *same binary* point a mount at external Postgres/MySQL. This is the
  graduation hook PocketBase can never have.

---

## 4. MEASURED — built, gated, benchmarked (2026-06-11)

The recipe was: feature-gate to sqlite-only + `[profile.nano]` (`opt-level="s"`, fat LTO, 1 CGU,
`panic="abort"`, strip) + static musl → `FROM scratch`. It is now **built** (`make nano-build`,
`Dockerfile.nano`) and gated (`make verify-m37`). Head-to-head against the **official PocketBase
v0.39.3 release binary**, same box, same curl loop (`scripts/bench/nano-vs-pocketbase.sh`):

| Measured | **binocle-nano** | PocketBase v0.39.3 | Factor |
|---|---|---|---|
| Binary / image | **5.1 MB** (scratch image 5.11 MB) | 30.1 MB binary | **6.1× smaller** |
| RSS idle | **2.0 MiB** | ~12 MiB | **~6× lighter** |
| RSS after load | 2.0 MiB | 13.1 MiB | 6.5× lighter |
| insert (ms/req, sequential N=100) | **4.9** | 5.0 | par |
| list 30 (ms/req, sequential N=100) | **5.2** | 5.6 | par |

The ask was "<50 MB like them" — delivered **10× under that bar** and 6× under PocketBase itself,
with full CRUD + schema introspection + raw-SQL migrations + graph + scoped keys + SSE realtime in
the binary (`m37` proves all of it against the scratch image, including 403/401 fail-closed and
live SSE delivery).

> **Latency honesty:** the ms/req numbers are dominated by the curl process spawn — both servers
> answer in well under a millisecond internally. The honest claim is *"at parity under identical
> measurement, at a sixth of the footprint"*, not "N× faster". (TrailBase's load harness shows what
> Rust + C-SQLite does under real concurrency; we inherit that class.)
>
> One real engine fix fell out of the bench: the SQLite adapter ran WAL with the default
> `synchronous=FULL` (a ~10 ms fsync per commit — inserts were 2.7× slower than PB). The standard
> WAL pairing `synchronous=NORMAL` (what PocketBase ships) closed it: 13.4 → 4.9 ms/insert. That
> fix benefits every tier's SQLite engine, not just nano.

---

## 4b. binocle-one — the second SKU, SHIPPED (2026-06-12)

Nano stays the headless minimal offer. **binocle-one** is *our PocketBase*: the same engine +
accounts (argon2id passwords, JWT + rotating refresh), the **full OAuth2 matrix** (one
PKCE flow, 11 presets incl. Apple/ES256, any-OIDC via discovery), email verification /
password reset / OTP login over SMTP, **TOTP MFA** with recovery codes, **file storage**
(multipart, thumbnails, signed links), **topic+owner-filtered SSE**, `fields` projection,
and an **embedded admin dashboard** at `/_/` — all in one **6.41 MB** scratch image idling
at **2.2 MiB**. Gates m40–m45 prove every claim live; the three-column load bench
(`scripts/bench/nano-one-pb-load.sh`) shows one at **9,283 RPS insert @ c=64 (3.8×
PocketBase) on 15.4 MiB under load (26× lighter)**. Full comparison + honest losses:
[`nano-vs-pocketbase.md`](./nano-vs-pocketbase.md).

---

## 5. What nano does that PocketBase (and TrailBase) don't

| Capability | Nano | PocketBase | TrailBase |
|---|---|---|---|
| Single binary, embedded SQLite, ~$2/mo | ✅ | ✅ | ✅ |
| Real C SQLite + Rust (no-GC, sub-ms reads) | ✅ | ❌ pure-Go SQLite | ✅ |
| **Engine-agnostic** — same app on SQLite *or* external Postgres/MySQL | ✅ (feature/mount) | ❌ SQLite-only forever | ❌ SQLite-focused |
| **ABAC + field-level masking** (hide/redact per column) | ✅ (`abac.rs`, shipped) | ❌ row rules only | ❌ row ACLs |
| **Graph / relationship subgraph** (Obsidian-style) | ✅ (`graph.rs`, shipped) | ❌ | ❌ |
| **Multi-tenant DNA in single-tenant clothes** — owner-stamping + scopes + capability mask already there | ✅ | ❌ | ❌ |
| **Graduate to a cloud stack with no rewrite** (nano → basic → … → max, one codebase) | ✅ | ❌ (migrate off) | ❌ |
| Tiering / rate-limits / capability honesty in the same core | ✅ (shipped) | ❌ | partial |

The pitch is not "a faster SQLite box" (TrailBase has that). It's **"the lightest backend that already
has cloud-grade authorization (ABAC + masks), graph, and a real upgrade path — so you never have to
migrate off it."**

---

## 6. Honest caveats & gaps

- **The admin UI is the size risk.** Our existing osionos editor is far too heavy to embed; nano needs
  a *purpose-built minimal* admin SPA (collections, auth, logs). Until that exists, nano ships
  "headless" (API + a JSON/`curl` admin) and the embedded UI is a follow-up. PocketBase's polished UI
  is a real advantage we'd be matching over time, not on day one.
- **No JS hooks VM.** PocketBase embeds `goja` so users script hooks in JS. Nano's equivalent is
  either *nothing* (declarative automations — which we already have server-side) or a **WASM** hook
  runtime later. Day one: declarative automations + webhooks, not arbitrary JS.
- **Realtime:** the Rust realtime crate exists but adding it to nano grows the binary; an SSE-only
  minimal realtime (PocketBase-style) is the lean default, full event-bus is an upgrade.
- **TrailBase exists.** We are not first to "Rust + SQLite BaaS." Position on features + graduation,
  and benchmark *honestly* against both PB and TrailBase rather than implying we invented the class.
- **musl + rusqlite-bundled** compiles fine (C SQLite under musl is well-trodden); dropping
  mongodb/tiberius actually *removes* the drivers that most complicate a static build.

---

## 7. Build roadmap — steps 1–4 + 6 SHIPPED (branch `feat/baas-nano`)

1. ✅ **Per-engine cargo features** on pool + server (`--no-default-features --features nano`);
   default build = all nine engines, byte-equivalent (235 workspace tests green).
2. ✅ **`[profile.release]`** strip+thin-LTO (full router binary 29 → 25 MB, free win) +
   **`[profile.nano]`** (opt-level=s, fat LTO, 1 CGU, panic=abort).
3. ✅ **Nano runtime** (`crates/data-plane-server/src/nano.rs`): in-process key store
   (`nbk_<id>.<secret>`, SHA-256 digests + constant-time compare — a memory-hard KDF defends
   low-entropy *passwords*, which 256-bit random keys are not), static mount map (`NANO_MOUNTS`),
   SSE realtime (`/nano/v1/realtime`), admin key mint/list/revoke + raw-SQL migrations
   (`/nano/v1/{keys,raw,info}`); first boot prints the admin key once (or hashes `NANO_ADMIN_KEY`).
   Single-tenant owner stamping (`api-key:local`) so key rotation never orphans data.
4. ✅ **Static musl → `FROM scratch`** (`Dockerfile.nano`, target-specific `crt-static` so
   proc-macros still build): `make nano-build` / `nano-up` / `nano-down`; gate `make verify-m37`
   (size ≤15 MB, boot, migrate→CRUD→aggregate→introspect, scope gate, fail-closed 401/404, SSE
   delivery, revoke, idle ≤25 MiB).
5. ⏳ **Minimal embedded admin UI** (brotli `include_bytes!`) — the deliberate day-2 piece; nano
   ships headless (the admin surface is the API).
6. ✅ **Bench vs PocketBase** — official binary, same box: table in §4
   (`scripts/bench/nano-vs-pocketbase.sh`, artifact `artifacts/nano-vs-pocketbase.json`).

**No TS was deleted** and no cloud tier changed (m31/m32/m33/m36 all re-verified green; the live
app stayed on count=5000 through every router rebuild). JWT user-identity (ABAC masks in nano) is a
follow-up alongside the UI.

---

## 8. Cost (see [`cost-analysis.md`](./cost-analysis.md) for the full model)

A single small binary on Fly's floor preset (`shared-cpu-1x`, 256 MB = $2.02/mo) + a small SQLite
volume:

- **Always-on:** ~$2.02 compute + ~$0.15–0.45 volume ≈ **~$2–3 / month**.
- **Scale-to-zero** (a landing page that sleeps): compute → ~0, just the volume ≈ **< $1 / month**.

**This is the same infra floor as self-hosting PocketBase** — you can't undercut a single small binary
by much. So nano's cost story is *"PocketBase's price, with cloud-grade auth + graph + a real upgrade
path,"* and it's **~3× cheaper than our own `basic` tier** (463 MiB, ~$6/mo) for anyone who doesn't
need the multi-container flexibility yet.

> **Tier-ladder correction:** `basic` was previously called "PocketBase-class." More precisely:
> **nano = PocketBase-class (one binary, ~15 MB)**; **`basic` = the lean *microservice* step above it**
> (11 containers, 463 MiB) — more moving parts, but horizontally scalable and a stepping stone to the
> cloud tiers. Nano trades that flexibility for radical size/simplicity, exactly like PocketBase.

**Sources:** [PocketBase](https://pocketbase.io/faq/) · [TrailBase benchmarks](https://trailbase.io/reference/benchmarks/)
· live `data-plane-router` binary (29 MB) + image (54 MB) + 3.3 MiB idle (`make bench-footprint`, 2026-06-11).
