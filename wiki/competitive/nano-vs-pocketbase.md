# binocle vs PocketBase — the honest comparison

> **Status: FEATURE PARITY REACHED (2026-06-12).** Every row carries evidence — a verify
> gate (m37, m40–m45), a bench artifact, or a PB docs link. The build program (phases
> A→G) is complete; the three remaining GAPs at the bottom are deliberate roadmap, not
> debt. Sources: [PocketBase v0.39 docs](https://pocketbase.io/docs/), `make verify-m4x`,
> `scripts/bench/nano-one-pb-load.sh` artifacts.

## The two offers

| Offer | What it is | Size / idle RAM | Status |
|---|---|---|---|
| **binocle-nano** | The ultra-minimal headless data plane: CRUD + filters + aggregates + graph + scoped keys + SSE | **5.16 MB / 2.1 MiB** (m37) | ✅ shipped |
| **binocle-one** | *Our PocketBase*: nano + accounts (password, OAuth2 matrix, OTP, TOTP MFA) + typed collections + files + filtered realtime + embedded admin dashboard | **6.41 MB / 2.2 MiB** (m45) | ✅ shipped |
| PocketBase v0.39.3 | The reference competitor | 30.1 MB / ~12 MiB (measured) | — |

One binary each, FROM scratch images, same engine underneath (group-commit SQLite writer).
binocle-one is **4.7× smaller** than PocketBase with the dashboard embedded.

## Feature matrix (every row gate-proven)

| Capability | binocle-one | PocketBase | Evidence |
|---|---|---|---|
| Email/password auth + JWT + rotating refresh | ✅ argon2id, single-use refresh | ✅ | m40 |
| **OAuth2 providers** | ✅ ONE PKCE flow + presets (Google, GitHub, GitLab, Discord, Microsoft, Facebook, Twitch, Spotify, LinkedIn, Notion, Apple/ES256) + **any OIDC issuer** via discovery | ✅ 30+ presets | m41 (mock-OIDC e2e, S256 verified by the issuer) |
| OTP (email code) login | ✅ | ✅ | m42 |
| **TOTP MFA + recovery codes** | ✅ RFC 6238, challenge-token flow, factor-gated disable | ✅ | m42 |
| Email verification + password reset (SMTP) | ✅ lettre/rustls; reset revokes sessions; no-enumeration | ✅ | m42 (Mailpit) |
| Typed collections (create via API/UI) | ✅ `/data/v1/schema/ddl` — same contract as the cloud tiers | ✅ | m37 §typed, m45 |
| **Per-user data isolation** | ✅ owner-scoping on the same `/data/v1` door + ABAC masks | ✅ rules | m40 §4, m41 §5 |
| File storage (multipart, thumbnails, protected links) | ✅ `?thumb=WxH`, signed 5-min tokens, type allowlist (html/svg out) | ✅ | m43 |
| Realtime filtering | ✅ `?topics=table:/db:` + **owner-filtered delivery** for user JWTs | ✅ rules | m44 |
| `fields` projection | ✅ engine-neutral, on all 9 engines | ✅ | m44 (live on PostgreSQL too) |
| **Admin dashboard** | ✅ embedded at `/_/` (27 KB hand-rolled; collections, grid, users, keys, files, SSE tail) | ✅ Svelte | m45 |
| **Server-side aggregation** (count/sum/avg/min/max + group_by) | ✅ `op=aggregate` | **❌ none** | [PB records API](https://pocketbase.io/docs/api-records/) |
| Filter DSL | ✅ injection-safe AST incl. `$in/$between/$null` | comparable sugar | `data-plane-core/src/filter.rs` |
| Graph / relationship subgraphs | ✅ `/data/v1/graph` (BFS ≤3, multi-mount) | ❌ (`expand` ≤6 levels is their shape) | m34 |
| Scoped machine keys | ✅ mint/revoke read/write/admin | superuser tokens only | m37, m45 |
| **Engine graduation** — same API onto Postgres/MySQL/Mongo/… cloud tiers | ✅ 9 engines, conformance-gated | ❌ SQLite forever | m27, `service-tiers.md` |

## Concurrent load — MEASURED, three columns (oha, same box, official PB binary, 8 s/run)

| | **nano** | **one** | PocketBase | one vs PB |
|---|---|---|---|---|
| insert @ c=1 (RPS / p99 ms) | 4,961 / 0.3 | 3,209 / 0.3 | 2,357 / 0.8 | **1.4× / 2.7×** |
| insert @ c=16 | 11,705 / 3.2 | 5,473 / 4.3 | 2,497 / 90.9 | **2.2× / 21×** |
| insert @ c=64 | 11,435 / 69.7 | **9,283 / 71.9** | 2,463 / 208.1 | **3.8× / 2.9×** |
| **100k-row insert @ c=64** | 11,803 | **9,461** | 2,578 | **3.7×** |
| list 30 @ c=64 (RPS / p99 ms) | 14,495 / 8.0 | 13,790 / 8.3 | **17,490** / 29.5 | PB 1.27× RPS (honest loss) / **we 3.6× tail** |
| **RSS under c=64 load** | 11.2 MiB | **15.4 MiB** | 406.3 MiB | **26×** |
| disk after 100k rows | 13.7 MB | **11.7 MB** | 261.9 MB | **22×** |
| boot → first 200 | 6 ms | **5 ms** | 120 ms | **24×** |

The full app backend (accounts, OAuth, MFA, files, dashboard) costs binocle-one **~19% of
nano's peak insert throughput and ~4 MiB of RSS** — the engine (single-writer group commit:
≤128 queued writes per transaction, savepoint-per-job) is shared. **Honest loss kept on the
board:** PocketBase serves ~1.3× more list RPS at high concurrency; our list p99 is 3.6×
better. Artifacts: `mini-baas-infra/artifacts/nano-one-pb-load.json` (+ the original
two-column `nano-vs-pocketbase-load.json`).

## Remaining gaps — deliberate roadmap, not debt

| # | Capability | PocketBase | binocle | Plan |
|---|---|---|---|---|
| G8 | Hooks/extending (JS VM, Go framework, cron) | ✅ | ❌ in nano/one (cloud tiers have server automations) | declarative automations first, WASM later |
| G10 | Migration files/versioning | ✅ | `/data/v1/schema/ddl` + raw | post-launch |
| G11 | Backups API | ✅ | volume copy (no API) | post-launch |

Also: S3 file backends stay a **cloud-tier** concern (MinIO) — documented, deliberately not
in the single binary. Relation `expand` remains a shape difference: our graph endpoint is
the answer, documented as such.

## Benchmark method (kept honest)

- Same box, all three systems in containers, official PB release binary, identical driver
  (`oha`), identical 8 s windows, c=1/16/64 + a 100k-row run.
- Reported: RPS + p50/p95/p99, RSS sampled mid-load, disk-after, boot-to-first-200.
- The FIRST run of this bench (Phase A) measured our naive pooled writes collapsing to
  48 RPS @ c=64 — the engine work was earned, not assumed.

*Last updated: 2026-06-12 (Phase G — program complete).*
