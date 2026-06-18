# data-plane-server

The axum HTTP binary (`data-plane-router`) that sits on top of `data-plane-core` and `data-plane-pool`: it authenticates a request, builds a `RequestIdentity`, authorizes it (ABAC), resolves the target mount, runs a `DataOperation` through the planner + pool adapter, and returns JSON — plus rate-limiting, quotas, usage metering, observability, and two single-binary product editions (`nano` and `one`).

## Role in the workspace

`data-plane-router` is the Rust **data plane** of the mini-baas / Grobase BaaS. It is the only crate in the `data-plane-router` cargo workspace that produces a binary (`[[bin]] name = "data-plane-router"`, `src/main.rs`); the other three crates are libraries it composes:

- **`data-plane-core`** — pure domain vocabulary and traits: `RequestIdentity`, `DatabaseMount`, `DataOperation`/`DataOperationKind`, `EngineAdapter`, `EngineCapabilities`, `PoolRegistry`, `TxHandle`, `DataPlaneError`, the capability-aware `plan(...)`/`tier_gate(...)` planner, and the `ports` traits. This crate consumes those types verbatim (the request/response JSON shapes are core types).
- **`data-plane-pool`** — concrete engine adapters (`PostgresEngineAdapter`, `MongoEngineAdapter`, `MysqlEngineAdapter`, `RedisEngineAdapter`, `SqliteEngineAdapter`, `MssqlEngineAdapter`, `HttpEngineAdapter`, optional `DynamoEngineAdapter`) plus `DefaultPoolRegistry`, `EnvMountResolver`, `ProviderConfig`, and the SSRF guard (`guard_and_resolve`) / `service_auth` HMAC helpers. This crate wires one `Arc<dyn EngineAdapter>` per engine into a registry and dispatches through it.

The binary's job, end to end: take an HTTP request → authenticate it → build a `RequestIdentity` → authorize (ABAC field masks) → resolve the mount (DSN + tier mask) → run the `DataOperation` through the planner and the pool adapter → return JSON. It also hosts the cross-cutting machinery (metering, quotas, rate-limits, metrics, audit) and the product editions.

`main.rs` picks the runtime by compile-time feature: `one::run` (checked first, since `one` implies `nano`), else `nano::run`, else `server::run` (the full multi-engine router). `--healthcheck` is a TCP-connect probe used by the container healthcheck.

## Request lifecycle

A data request entering the **default (full-router)** build flows like this:

1. **Boot.** `main.rs` reads `ServerConfig::from_env()` (`config.rs`) and calls `server::run`. `server::run` binds the listener, builds `routes::AppState::new(config)` — which constructs the `EnvMountResolver`, pushes one `Arc<dyn EngineAdapter>` per compiled engine into a `Vec`, runs the boot-time `assert_capability_honesty` self-check, and builds the `DefaultPoolRegistry`, `Metrics`, `RateLimiter`, `Usage`, and the optional honor-set snapshots. It spawns a 15-second background reaper (`AppState::reap_once`) that drains idle pools, rolls back + unpins expired transactions, evicts idle rate-limit buckets, and refreshes the honor sets; a second loop refreshes honor-set snapshots when any are enabled. Finally `routes::router(state)` assembles the axum `Router` and `axum::serve` runs it with graceful shutdown (`signal::shutdown_signal`).

2. **Ingress + metrics.** Every request passes the `track_metrics` middleware (`routes.rs`), which captures the inbound `traceparent` / `x-request-id` for cross-tier tracing, runs the handler, then records the status class onto `Metrics` and logs one structured line (skipping `/metrics` and `/v1/health`). A `TraceLayer` and a deny-by-default `cors_layer` wrap the whole router.

3. **Authentication + identity.** On the internal `POST /v1/query` the identity is already trusted (the TS query-router authenticated and sends the full `{identity, mount, operation}` envelope). On the additive Phase-7 `POST /data/v1/query` bypass, Rust authenticates itself: `bypass_verify` reads `X-Baas-Api-Key`, checks a short-TTL `verify_cache`, then calls `auth::verify_key` → tenant-control `POST /v1/keys/verify` (Go still performs the Argon2id compare and stays the identity authority), yielding a `VerifiedIdentity { tenant_id, key_id, scopes, principal, source }`. `resolve_bypass_mount` → `auth::resolve_mount` → adapter-registry `GET /databases/{id}/connect` resolves the engine + DSN + tier mask (tenant-scoped, so a cross-tenant id is a 404). `bypass_envelope` then builds the same `RequestIdentity` + `DatabaseMount` the query-router would, stamping the principal (`api-key:<id>` or `user:<id>`).

4. **Authorization + gates.** Both doors funnel into `run_query` → `run_query_inner`. It calls `validate_identity_mount` (tenant-scoped, identity tenant == mount tenant, engine is mounted), checks the engine is executable in this build, then applies (in order) the per-tenant token-bucket **rate limit** (`tier_rate` → 429), the **quota** / **spend-cap** / **suspend** honor-set checks (402/402/403), the capability **`tier_gate`** (403 for a masked-off op), and the capability-aware **planner** `data_plane_core::plan(...)` (422 for an op the engine cannot serve, or a clean 501 for a not-yet-wired federation). On the bypass, `api_key_scope_gate` enforces admin/read/write scope first.

5. **Execution + post-processing.** `tier_max_rows` clamps `operation.limit` to the tier cap, then `state.registry.get_or_create(mount)` returns the pooled `EnginePool` and `pool.execute(operation, identity)` runs the operation through the adapter. On success the handler audits mutations (and optionally reads), records usage metering, fires the outbox emit + automations (bypass write path only, `control-pg`) or the nano SSE fan-out (`nano`), applies ABAC field masks (`apply_masks`), applies the `fields` projection, and returns `200 OK` with the `DataResult` JSON. Errors are mapped to HTTP status by `map_data_plane_error` (400/402/403/404/409/422/501/502).

## File-by-file

### `src/main.rs`
**Purpose:** Binary entrypoint and edition selector.
**Key functions:** `main` (installs the `tracing_subscriber` `EnvFilter`, reads `ServerConfig::from_env`, dispatches to the edition's `run`), `healthcheck` (a `TcpStream::connect_timeout` against `DATA_PLANE_ROUTER_HEALTH_HOST:DATA_PLANE_ROUTER_PORT`, used by `--healthcheck`).
**How it connects:** Feature-gates the three runtimes: `one::run` first (since `one` implies `nano`), then `nano::run`, else `server::run`.

### `src/lib.rs`
**Purpose:** Crate root: module declarations, crate-wide clippy allows, and feature gates.
**Key items:** declares `abac`, `auth`, `config`, `graph`, `metrics`, `quota`, `ratelimit`, `routes`, `server`, `signal`, `usage` unconditionally; `automations` + `outbox` under `control-pg`; `nano` under `nano`; `one`, `one_admin`, `one_email`, `one_files`, `one_oauth`, `one_totp` under `one`. Crate-wide `#![allow]`s for `too_many_arguments`, `large_enum_variant`, `result_large_err`, `doc_lazy_continuation`.

### `src/server.rs`
**Purpose:** Server/router bootstrap for the default (non-nano) build.
**Key functions:** `run(config)` — binds the listener, builds `routes::AppState::new`, spawns the `REAPER_INTERVAL` (15s) reaper task calling `reap_once`, conditionally spawns the honor-set refresh loop (`refresh_honor_sets` at `quota_refresh_ms`) when `honor_sets_enabled()`, serves the `routes::router(state)` with graceful shutdown, and calls `flush_usage()` on exit.
**How it connects:** The single place the registry, reaper, and honor-set loops are wired; everything else is in `routes::AppState`.

### `src/signal.rs`
**Purpose:** Graceful-shutdown signal handling.
**Key functions:** `shutdown_signal()` — selects over `ctrl_c` and (on Unix) `SIGTERM`.

### `src/config.rs`
**Purpose:** Env-driven configuration, the single env-reader for the server.
**Key types:** `ServerConfig` (all tunables: host/port, `product_mode`, `adapter_registry_url`, permission bundle, `max_pools`, `share_pools` (B4-pools), credential-provider knobs (adapter-registry token, Vault addr/token/prefix/field, cache TTL), `security_mode`/`tls_ca_file`, the Phase-7 bypass knobs (`tenant_control_url`, `internal_service_token`, `bypass_enabled`, `apply_masks`, `verify_cache_ttl_ms`, `audit_reads`), Track-B metering (`metering`, `metering_flush_ms`, `metering_redis_url`), the three honor sets (`quota_enforcement`, `spend_caps`, `suspend_reader`, `quota_refresh_ms`, `quota_redis_url`), and B5 observability (`tenant_obs`, `tenant_obs_counter`)).
**Key functions:** `from_env()` (defaults every flag OFF → byte-parity; metering/quota/spend/suspend each require BOTH `METERING_ENABLED` AND their per-emitter flag), `is_max_security()`, and a redacting `Debug` impl (`redact` masks `adapter_registry_token`/`vault_token`/`internal_service_token`/the Redis URLs so a stray `{:?}` never leaks a secret).
**How it connects:** Consumed by `AppState::new` and every cross-cutting module's hot-path flag check.

### `src/routes.rs`
**Purpose:** THE main router — `AppState`, the axum route table, and every data-plane HTTP handler. This is the heart of the crate.
**Key types:**
- `AppState` (cloneable Arc-bag): `config`, `engines` (`Vec<EngineDescriptor>`), `registry` (`DefaultPoolRegistry`), `resolver` (`EnvMountResolver`), `transactions` (`TransactionRegistry`), `evaluator` (optional ABAC `Evaluator`), `metrics`, `ratelimiter`, `usage`, the three honor-set snapshots + refreshers (`quota_over`/`spend_over`/`suspended`), `http_client`, `verify_cache` + `mount_cache`, and (feature-gated) `outbox`, `automations`, `nano`, `one`.
- `TransactionRegistry` / `TransactionEntry` — keyed by `tx_id`, pins the pool against eviction while a tx is open, with TTL-based expiry (`reap_expired`).
- `EngineDescriptor`, `RouterDescriptor`, `CapabilitiesResponse`, `HealthResponse`, `ApiError`, request structs (`QueryRequest`, `DataQueryRequest`, `DescribeSchemaRequest`, `SchemaDdlEnvelope`, `AdminRawRequest`, `AdminMigrateRequest`, `AdminRotateRequest`, `AdminEvictVerifyRequest`, `DecideRequest`).

**Key routes** (assembled in `router(state)`):
- `GET /v1/health` → `health`; `GET /metrics` → `metrics_handler` (dependency-free Prometheus `baas_*` exposition: service_up, uptime, request classes, per-tenant counter, pool lifecycle/open, verify/mount cache, ratelimit-tracked, outbox stages, per-mount pool connections); `GET /v1/capabilities` → `capabilities`.
- **Data:** `POST /v1/query` → `execute_query` (internal, trusted envelope; `emit_outbox=false`). Both `execute_query` and the bypass route into `run_query` → `run_query_inner`.
- **Schema:** `POST /v1/schema` → `describe_schema` (gated on the `introspect` capability); `POST /v1/schema/ddl` → `apply_schema_ddl` (gated on `schema_ddl`).
- **Transactions:** `POST /v1/transactions` → `begin_transaction`; `POST /v1/transactions/:tx_id/execute` → `execute_in_transaction` (cross-tenant guard); `POST /v1/transactions/:tx_id/commit` → `commit_transaction`; `POST /v1/transactions/:tx_id/rollback` → `rollback_transaction`. Default tx TTL `DEFAULT_TX_TTL_SECS = 30`.
- **Admin** (gated `service_role`/`admin` via `is_admin`): `POST /v1/admin/raw` → `execute_raw_admin`; `POST /v1/admin/migrate` → `apply_migration_admin` (gated on `ddl`); `POST /v1/admin/rotate` → `rotate_credential_admin` (evicts resolver DSN cache + drains the registry pool via `AppState::rotate`); `POST /v1/admin/evict-verify` → `evict_verify_admin` (B3 revoked-key hook).
- **Permissions:** `POST /v1/permissions/decide` → `decide_permission` (in-Rust PDP; 503 if no bundle).
- **Phase-7 bypass** (mounted only when `bypass_enabled`): `POST /data/v1/query` → `data_query`, `POST /data/v1/schema` → `data_describe_schema`, `POST /data/v1/schema/ddl` → `data_apply_schema_ddl`, `POST /data/v1/graph` → `graph::data_graph`, `POST /data/v1/graph/overview` → `graph::data_graph_overview`. Shared helpers: `bypass_verify`, `bypass_auth`, `bypass_envelope`, `api_key_scope_gate`/`require_scope`, `bypass_ratelimit`, `scope_denied`.
- Fallback `not_found` returns a JSON 404.

**How it connects:** Imports `Evaluator`/`PolicyBundle` from `abac`, `Metrics` from `metrics`, `RateLimiter`/`tier_rate`/`tier_max_rows` from `ratelimit`, `Usage` from `usage`, the honor sets from `quota`, and the bypass `VerifiedIdentity`/`ResolvedMount` from `auth`. `run_query_inner` is the single enforcement funnel for both doors. `map_data_plane_error` is the canonical `DataPlaneError` → HTTP mapping.

### `src/auth.rs`
**Purpose:** Phase-7 Rust-native authentication for the `/data/v1` front door (Go stays the identity authority; Rust never hashes/stores keys).
**Key types:** `AuthError` (`Unauthorized`→401, `Upstream`→502, `NotFound`→404), `VerifiedIdentity` (`tenant_id`, `key_id`, `scopes`, `principal`, `source`), `ResolvedMount` (`engine`, `connection_string`, `isolation`, `capability_overrides`).
**Key functions:** `verify_key` (POST tenant-control `/v1/keys/verify`, optional HMAC via `service_auth`), `resolve_mount` (GET adapter-registry `/databases/{id}/connect`).
**How it connects:** Called by `routes::bypass_verify` / `resolve_bypass_mount`; the nano/one editions short-circuit this with their in-process verifiers.

### `src/abac.rs`
**Purpose:** In-Rust ABAC/RBAC policy evaluator mirroring the SQL `public.has_permission(...)` and the NestJS field-mask resolution, so the data plane can decide locally instead of HTTP round-tripping the permission-engine.
**Key types:** `PermissionMode` (`Abac`/`Rbac`), `PolicyBundle` (`user_roles` + `policies`), `UserRole`, `Policy`, `PolicyEffect`, `FieldMask` (`hide`/`redact`), `Decision`, `Evaluator`.
**Key functions:** `Evaluator::decide` (priority DESC, deny-before-allow, default deny; ABAC mode resolves the highest-priority allow's `mask`), `apply_field_mask` (in-place hide/redact on JSON object rows).
**How it connects:** Built by `routes::build_evaluator` from `DATA_PLANE_PERMISSION_BUNDLE`; backs `POST /v1/permissions/decide` and the `apply_masks` response-masking path in `run_query_inner`.

### `src/graph.rs`
**Purpose:** Phase-D node-graph assembly for the `/data/v1/graph` bypass — a port of the query-router's `GraphService`, composing owner-scoped `list` reads into a node-link subgraph (no cross-DB join).
**Key types:** `GraphNode`, `EdgeRecord`, `GraphGuarantee` (`PerNodeAtomic`/`SubgraphEventual`), `GraphResponse`, request types (`GraphRequest`, `GraphOverviewRequest`, `ResourceRef`, `EdgeGenerators`, `TagGenConfig`, `ReferenceGenConfig`), and the BFS engine `GraphEngine`.
**Key functions/routes:** `data_graph` (BFS from a focus node, `MAX_DEPTH=3`, `MAX_GRAPH_NODES=5000` DoS bound) and `data_graph_overview`; helpers `parse_node_id`, `to_edge_record`, `row_to_node`, and the secondary edge generators `note_edges` (`[[wikilinks]]`), `tag_edges`, `reference_edges`.
**How it connects:** Uses `routes::{bypass_verify, require_scope, scope_denied, bypass_ratelimit}` for auth + read-scope + rate-limit, and `AppState::{resolve_bypass_mount, execute_read}` for each owner-scoped read.

### `src/metrics.rs`
**Purpose:** Dependency-free Prometheus metrics (std atomics + `PoolRegistry::stats()`), consistent with the Go control plane's `baas_*` exposition.
**Key types:** `Metrics` (request class counters, verify/mount cache counters, outbox stage counters, and the bounded per-tenant `tenant_requests` map).
**Key functions:** `record`, `record_verify_cache`/`record_mount_cache`, `record_outbox_*`, `record_tenant_request` (B5 Pillar 3, hard-capped at `TENANT_COUNTER_CAP=512` + a `_over_cap` sentinel), the `*_snapshot` readers, and `escape_label`.
**How it connects:** Held in `AppState`; written by `track_metrics`, the cache/bypass paths, and the outbox worker; read by `metrics_handler`.

### `src/quota.rs`
**Purpose:** Control-plane honor-set machinery (Track-B), reused verbatim for THREE Redis sets: `quota:over` (402), `spend:over` (402 `spend_capped`), `tenant:suspended` (403). Fail-OPEN, flag-gated OFF = byte-parity.
**Key types:** `QuotaSet` (in-memory `RwLock<HashSet>` snapshot, hot-path `is_over`), `QuotaRefresher` (lazy Redis client doing `SMEMBERS <set_key>` per refresh tick, only real under `ratelimit-redis`). Constants `QUOTA_OVER_SET`, `SPEND_OVER_SET`, `SUSPENDED_SET`.
**How it connects:** Snapshots live in `AppState`; refreshed on the reaper tick / honor-set loop (`refresh_honor_sets`); checked in `run_query_inner`.

### `src/ratelimit.rs`
**Purpose:** Per-tenant token-bucket rate limiting (Phase-4 tiering), keyed on the trusted envelope tenant.
**Key types:** `RateLimiter` enum (`InProcess(TenantRateLimiter)` default | `Redis(RedisRateLimiter)` under `ratelimit-redis`), `TenantRateLimiter`, `RedisRateLimiter` (atomic Lua token bucket, fail-open).
**Key functions:** `refill_and_take` (the shared pure bucket math mirrored by the Lua script), `RateLimiter::{from_env, allow, evict_idle, tracked}`, and the tier-mask extractors `tier_rate` (`(rps, burst)`, burst defaults `2×rps`) and `tier_max_rows`.
**How it connects:** `AppState.ratelimiter`; `tier_rate`/`tier_max_rows` are imported into `routes.rs`; idle buckets evicted on the reaper tick.

### `src/usage.rs`
**Purpose:** Track-B metering (B1a tracing + B1b durable stream) — per-tenant usage counters (`query.count`, `query.rows`, `write.rows`).
**Key types:** `UsageAggregate` (`Mutex<HashMap<(tenant, metric), u64>>`), `UsageEnvelope` (the frozen `usage.events` wire contract: `tenant_id`/`metric`/`qty`/`ts`/`window_ms`/`idempotency_key`), `Usage` (the `AppState` handle), `UsageStream` (the B1b Redis `XADD` producer, under `ratelimit-redis`). Constant `USAGE_STREAM_KEY = "usage.events"`.
**Key functions:** `Usage::{record, spawn_flusher, flush_now, with_stream_url}`, `window_start_ms`, `idempotency_key` (sha256 of `tenant|metric|window_start_ms`), `drain_and_trace`.
**How it connects:** `record` is called from `run_query_inner` only when `config.metering` is ON; the flusher is spawned by `AppState::new`/`server::run`; `flush_usage` drains on shutdown.

### `src/automations.rs` (feature `control-pg`)
**Purpose:** Phase-D server-backed automations on the bypass write path — a port of the query-router's `AutomationsService`, reading `automation_rules` from the control Postgres and firing follow-ups after a successful bypass mutation.
**Key types:** `AutomationEngine` (pool + 30s rules cache + redirect-free HTTP client), `Rule`/`Condition`/`Action`.
**Key functions:** `from_env` (built only when `DATA_PLANE_OUTBOX_DSN` is set), `run_for_write`, and the action handlers `fire_set_property` (direct `pool.execute` follow-up — loop-safe, never re-triggers), `fire_notify` (realtime publish), `fire_webhook` (https-only + `data_plane_pool::guard_and_resolve` SSRF guard + pinned IPs). Helpers `trigger_matches`, `evaluate_condition`.
**How it connects:** `AppState.automations`; fired from `run_query_inner` when `emit_outbox && is_mutation`.

### `src/outbox.rs` (feature `control-pg`)
**Purpose:** Phase-7d transactional outbox emission for `/data/v1` writes — emits the same `public.outbox_events` row shape the query-router would, so realtime/webhooks/projections keep firing post-cutover.
**Key types:** `OutboxRow` (materialized off the DB path; skips the `outbox_events` table to avoid looping the relay), `OutboxEmitter` (the Postgres pool), `BackgroundOutbox` (the request-path handle: a bounded `mpsc` channel drained by a batching worker, `DEFAULT_QUEUE_CAP=4096`, `BATCH_MAX=64`).
**Key functions:** `OutboxRow::build`, `OutboxEmitter::{from_env, into_background, emit_mutation}`, `BackgroundOutbox::enqueue` (non-blocking `try_send`, drops + counts on a full queue).
**How it connects:** `AppState.outbox`; enqueued from `run_query_inner` on the bypass write path; metrics surface enqueued/written/dropped/failed.

### `src/nano.rs` (feature `nano`) — the **nano** edition

**Purpose:** The single-binary, PocketBase-class runtime: one static process serving the `/data/v1` data plane over embedded SQLite, with in-process auth (a SQLite API-key store), static mounts, and SSE realtime — no control-plane round-trips.
**Key types:** `NanoState` (the `AppState.nano` field: `keys: KeyStore`, `mounts: HashMap<String, ResolvedMount>`, `events: broadcast::Sender<MutationEvent>`), `KeyStore` (SQLite `nano_keys` table at `<data_dir>/nano_meta.db`), `KeyInfo`, `NanoMountSpec`, `MutationEvent`, `Topic`. Constants `NANO_TENANT="local"`, `VALID_SCOPES=["admin","read","write"]`.
**Key functions:** `run(config)` (the nano boot entrypoint: resolves `NANO_DATA_DIR`, attaches `NanoState`, spawns the reaper, serves), `NanoState::{open, load_mounts, verify_headers, resolve_mount, publish_mutation}`, `KeyStore::{mint, verify, list, revoke}`, `authorize`, and `router`/`routes`.
**Routes:** reuses `GET /v1/health`, `GET /v1/capabilities`, and the `POST /data/v1/{query,schema,schema/ddl,graph,graph/overview}` surface, plus `GET /nano/v1/info`, `POST /nano/v1/keys`, `GET /nano/v1/keys`, `DELETE /nano/v1/keys/:id`, `POST /nano/v1/raw`, and `GET /nano/v1/realtime` (SSE, topic + owner filtered). The trusted-envelope `/v1/query` family is deliberately NOT mounted (no query-router to trust).
**How it connects:** `NanoState` short-circuits `routes::bypass_verify`/`resolve_bypass_mount`; committed mutations fan out to the SSE bus via `publish_mutation`. The `one` edition merges `nano::routes()` on top of its own.

### `src/one*.rs` (feature `one`) — the **one** edition ("our PocketBase")

> These six modules form the `one` edition: the nano runtime **plus** user accounts (email/password with argon2id + HS256 JWT sessions), OAuth, MFA, email flows, file storage, and an admin UI. `one::router()` is the master router — it merges `nano::routes()` with the `auth_routes` and all five sibling `one_*` route sets, so the `one` binary exposes the full surface of all of them. `one::run` is selected first by `main.rs` (since `one` implies `nano`) and attaches BOTH `AppState.nano` and `AppState.one`.

- **`one.rs`** — Edition core. `OneState` (the `AppState.one` field: `UserStore` on the shared `nano_meta.db`, `jwt_secret`/`jwt_ttl`, `allow_signup`, the `OAuthRuntime`, the optional `Mailer`, `data_dir`). `UserStore` owns the `one_users`/`one_refresh`/`one_config`/`one_user_identities`/`one_codes`/`one_totp`/`one_recovery`/`one_files` tables. Key functions: `verify_jwt` (→ principal `user:<id>`, `IdentitySource::Jwt`, scopes `[read, write]`), `issue_session` (JWT + rotating opaque refresh), `finish_login` (returns an MFA challenge when TOTP is enabled), `oauth_login`, `hash_password`/`verify_password` (argon2id), `bearer_token`. Routes: `POST /one/v1/auth/{register,login,refresh,logout}`, `GET /one/v1/auth/me`. `run(config)` is the binocle-one boot entrypoint.
- **`one_admin.rs`** — Embedded admin dashboard (`GET /_/` serves `include_str!("../ui/admin.html")`; `GET /_` redirects to `/_/`) plus admin-scope API: `GET /one/v1/admin/users`, `DELETE /one/v1/admin/users/:id`, `GET /one/v1/admin/files`. Gated via `nano::authorize(&state, &headers, "admin")`. The nano image never mounts this (headless is its SKU identity).
- **`one_oauth.rs`** — OAuth2/OIDC authorization-code grant (PKCE S256, `state` CSRF, single-use pending store) with a compiled-in 11-provider `PRESETS` table (google, github, gitlab, discord, microsoft, facebook, twitch, spotify, linkedin, apple, notion) plus a generic discovery-driven `oidc`. `OAuthRuntime` is a field of `OneState`. Routes: `GET /one/v1/auth/oauth/providers`, `GET /one/v1/auth/oauth/:provider/start`, `GET|POST /one/v1/auth/oauth/:provider/callback`. Providers enabled per-deployment via `ONE_OAUTH_*` env vars.
- **`one_totp.rs`** — RFC 6238 TOTP MFA (HMAC-SHA1, 6 digits, 30s, ±1 step) plus eight single-use recovery codes; two-step enrolment. Routes: `POST /one/v1/auth/totp/{enroll,confirm,verify,disable}`. `verify` upgrades the 5-minute `mfa_token` challenge (from `finish_login`) to a full session.
- **`one_email.rs`** — One SMTP sender (`Mailer`, lettre + rustls, a field of `OneState`, `None` when `ONE_SMTP_HOST` unset) driving three code flows over `one_codes`: verification, password reset (revokes all refresh tokens), and passwordless OTP login. Routes: `POST /one/v1/auth/{request-verification,confirm-verification,request-reset,confirm-reset,request-otp,login-otp}` (request-reset/request-otp always answer 202 — no account enumeration).
- **`one_files.rs`** — PocketBase-style file fields: files attach to a `(table, record, field)` coordinate, bytes stored under `{NANO_DATA_DIR}/storage/...` with server-minted names, metadata in `one_files` (owner-stamped). Thumbnails (`?thumb=WxH` via the `image` crate) and 5-minute signed file tokens. A content-type allowlist deliberately excludes html/svg (stored-XSS). Routes: `POST /one/v1/files/:table/:record/:field` (upload), `GET /one/v1/files/:table/:record` (list), `GET|DELETE /one/v1/file/:id` (serve/delete), `POST /one/v1/file/:id/token`.

## Product editions

`main.rs` and `Cargo.toml` select among three build shapes via features:

| Build | Features | What it is |
|-------|----------|------------|
| **Default (full router)** | `default = ["engines-full", "control-pg", "ratelimit-redis"]` | The full production / self-host / SaaS data plane: all seven engines (postgres, mongodb, mysql, redis, sqlite, mssql, http — plus cockroachdb/mariadb dialects), control-Postgres integrations (outbox + automations), and the multi-node Redis rate limiter compiled in (runtime-selected). Byte-equivalent to the pre-feature build. Runs `server::run`. |
| **nano** | `--no-default-features --features nano` | The single static binary, PocketBase-class: embedded SQLite only, a local SQLite key store (`rusqlite`), SHA-256 key digests, `uuid v4` key material, and SSE realtime. No control-plane round-trips. Runs `nano::run`. Adds the `nano/v1/*` surface. |
| **one** ("our PocketBase") | `--no-default-features --features one` | `nano` plus full user accounts: argon2id email/password, HS256 JWT sessions, the OAuth2/OIDC provider matrix, SMTP mail codes, RFC 6238 TOTP MFA, file storage, and the admin UI at `/_/`. Runs `one::run` (checked first in `main.rs` because `one` implies `nano`). Adds the `one/v1/*` and `/_/` surfaces. |

The optional **`dynamodb`** feature (NOT in `default`/`engines-full`) adds an 8th DynamoDB-compatible adapter; the shipped router image is byte-identical without it.

## Cross-cutting concerns

These layer onto every served request; all default OFF for byte-parity.

- **Authentication.** The internal `/v1/query` trusts the envelope (the query-router authenticated). The `/data/v1` bypass authenticates in Rust (`auth.rs`: `verify_key` → tenant-control; nano/one verify in-process). A short-TTL `verify_cache` + `mount_cache` amortize the verify/resolve round-trips; `/v1/admin/evict-verify` and `/v1/admin/rotate` flush them on credential events.
- **ABAC (`abac.rs`).** Backs `/v1/permissions/decide` (in-Rust PDP, 503 without a bundle) and, when `apply_masks` is ON, response-masks (`apply_field_mask`) and 403-denies user (non-`api-key:`) callers inside `run_query_inner` — applied AFTER outbox emit so server-side events keep the full row.
- **Rate limit (`ratelimit.rs`).** Per-tenant token bucket from the mount's tier mask (`tier_rate` → 429 `Retry-After: 1`); untiered tenants are unlimited (parity). In-process by default; authoritative cross-replica via Redis under `ratelimit-redis` + `DATA_PLANE_RATELIMIT_BACKEND=redis` (fail-open).
- **Quotas / spend / suspend (`quota.rs`).** Three Redis honor sets refreshed off the request path; a listed tenant is rejected with 402 (`quota_exceeded`), 402 (`spend_capped`), or 403 (`tenant_suspended`). Each is a single `HashSet::contains` on the hot path, gated by a `bool` short-circuit (fail-open).
- **Usage metering (`usage.rs`).** When `metering` is ON, the read arm records `query.count`/`query.rows` and the mutation arm `write.rows` into an in-memory aggregate, drained by a background flusher into a `usage` tracing event (B1a) and optionally an `XADD usage.events` durable stream (B1b).
- **Metrics / observability (`metrics.rs`).** `GET /metrics` is a dependency-free `baas_*` Prometheus exposition (request classes, pool lifecycle/saturation, cache hit/miss, ratelimit-tracked, outbox stages). B5 adds an optional `tenant_id` log field (`tenant_obs`) and a hard-capped per-tenant counter (`tenant_obs_counter`, ceiling N+1 series).
- **Audit.** Mutations are audited unconditionally to the `audit` tracing target; reads optionally under `audit_reads`; every denial (rate-limit, quota, spend, suspend, capability gate, ABAC, scope) emits an audited `warn`.

## Feature flags

| Feature | In `default`? | Adds / enables |
|---------|---------------|----------------|
| `engines-full` | yes | The seven-engine set: `postgres`, `mongodb`, `mysql`, `redis`, `sqlite`, `mssql`, `http` |
| `postgres` | via `engines-full` | `data-plane-pool/postgres` (Postgres + CockroachDB dialect) |
| `mongodb` | via `engines-full` | `data-plane-pool/mongodb` |
| `mysql` | via `engines-full` | `data-plane-pool/mysql` (MySQL + MariaDB dialect) |
| `redis` | via `engines-full` | `data-plane-pool/redis` |
| `sqlite` | via `engines-full` | `data-plane-pool/sqlite` |
| `mssql` | via `engines-full` | `data-plane-pool/mssql` |
| `http` | via `engines-full` | `data-plane-pool/http` |
| `dynamodb` | no | 8th adapter: `data-plane-pool/dynamodb` (AWS DynamoDB / DynamoDB-Local / ScyllaDB Alternator) — AWS SDK never compiled unless enabled |
| `control-pg` | yes | Outbox emission + server-backed automations (`deadpool-postgres`, `tokio-postgres`, `data-plane-pool/http` for the SSRF guard) |
| `ratelimit-redis` | yes | Authoritative cross-replica rate limiting + B1b/honor-set Redis (`redis-rl`, the `redis` crate renamed to avoid the `redis` engine-feature collision); runtime-selected, fail-open |
| `nano` | no | Nano edition: embedded SQLite + local key store (`rusqlite`) + `uuid/v4` + `futures` (SSE) |
| `one` | no | binocle-one: `nano` + `argon2` + `jsonwebtoken` + `lettre` + `hmac` + `sha1` + `image` + `axum/multipart` |
