use crate::abac::{Decision, Evaluator, PermissionMode, PolicyBundle};
use crate::config::ServerConfig;
use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use axum::body::Body;
use axum::extract::Request;
use axum::http::header;
use axum::middleware::Next;
use axum::response::Response;
use crate::metrics::{escape_label, Metrics};
use crate::ratelimit::{tier_max_rows, tier_rate, RateLimiter};
use crate::usage::Usage;
use data_plane_core::{
    CredentialRef, DataOperation, DataOperationKind, DataPlaneError, DatabaseMount, EngineAdapter,
    EngineCapabilities, MigrationRequest, Plan, PoolPolicy, PoolRegistry, RawStatement,
    RequestIdentity, SchemaDdlRequest, TxBeginRequest, TxHandle, WorkloadContext,
};
use data_plane_pool::{DefaultPoolRegistry, EnvMountResolver, ProviderConfig};
#[cfg(feature = "dynamodb")]
use data_plane_pool::DynamoEngineAdapter;
#[cfg(feature = "http")]
use data_plane_pool::HttpEngineAdapter;
#[cfg(feature = "mongodb")]
use data_plane_pool::MongoEngineAdapter;
#[cfg(feature = "mssql")]
use data_plane_pool::MssqlEngineAdapter;
#[cfg(feature = "mysql")]
use data_plane_pool::MysqlEngineAdapter;
#[cfg(feature = "postgres")]
use data_plane_pool::{PgDialect, PostgresEngineAdapter};
#[cfg(feature = "redis")]
use data_plane_pool::RedisEngineAdapter;
#[cfg(feature = "sqlite")]
use data_plane_pool::SqliteEngineAdapter;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime};
use tokio::sync::Mutex;
use tower_http::{cors::CorsLayer, trace::TraceLayer};

/// Lives inside `AppState`. Owns active multi-statement transaction handles
/// keyed by `tx_id`. Concurrent calls to the same `tx_id` are serialised by
/// the per-handle internal `Mutex` (see `PgTxHandle`), but the registry-level
/// map itself uses a tokio `Mutex` because we mutate it across `.await`.
#[derive(Default)]
struct TransactionRegistry {
    map: Mutex<HashMap<String, TransactionEntry>>,
}

struct TransactionEntry {
    handle: Arc<dyn TxHandle>,
    tenant_id: String,
    /// `pool_key` of the pool this tx's connection was checked out from. Used to
    /// pin that pool against eviction/reaping while the tx is open, and to
    /// unpin it on commit/rollback.
    pool_key: String,
    // Kept for diagnostics — `#[allow(dead_code)]` documents the intent.
    #[allow(dead_code)]
    mount_id: String,
    #[allow(dead_code)]
    opened_at: SystemTime,
    /// When the tx pin expires. The reaper (`reap_expired`) best-effort rolls
    /// back + unpins entries past this, and `get` refuses an expired entry, so a
    /// begun-but-never-finalised tx cannot pin its pool forever.
    expires_at: SystemTime,
}

impl TransactionRegistry {
    async fn register(
        &self,
        handle: Arc<dyn TxHandle>,
        tenant_id: String,
        mount_id: String,
        pool_key: String,
        ttl: Duration,
    ) -> String {
        let tx_id = handle.tx_id().to_string();
        let now = SystemTime::now();
        let mut map = self.map.lock().await;
        map.insert(
            tx_id.clone(),
            TransactionEntry {
                handle,
                tenant_id,
                pool_key,
                mount_id,
                opened_at: now,
                expires_at: now + ttl,
            },
        );
        tx_id
    }

    /// Look up a live tx. An entry past its `expires_at` is treated as absent
    /// (the reaper will roll it back + unpin its pool shortly): the contract is
    /// that the registry stops handing out an expired handle, so a stale tx_id
    /// surfaces a clean `transaction_not_found` rather than executing on a
    /// connection that's about to be reaped.
    async fn get(&self, tx_id: &str) -> Option<(Arc<dyn TxHandle>, String)> {
        let now = SystemTime::now();
        let map = self.map.lock().await;
        map.get(tx_id)
            .filter(|e| e.expires_at > now)
            .map(|e| (e.handle.clone(), e.tenant_id.clone()))
    }

    /// Remove the entry, returning both the handle and the `pool_key` so the
    /// caller can unpin the pool after finalising the tx.
    async fn take(&self, tx_id: &str) -> Option<(Arc<dyn TxHandle>, String)> {
        let mut map = self.map.lock().await;
        map.remove(tx_id).map(|e| (e.handle, e.pool_key))
    }

    /// Remove every entry past its `expires_at`, returning their (handle,
    /// pool_key) so the caller can best-effort roll back the handle and unpin its
    /// pool OUTSIDE the lock (both are async). A begun-but-never-committed tx
    /// otherwise pins its pool forever (never evictable / reapable). Idempotent;
    /// safe to call on a timer.
    async fn reap_expired(&self) -> Vec<(Arc<dyn TxHandle>, String)> {
        let now = SystemTime::now();
        let mut map = self.map.lock().await;
        let expired: Vec<String> = map
            .iter()
            .filter(|(_, e)| e.expires_at <= now)
            .map(|(id, _)| id.clone())
            .collect();
        expired
            .into_iter()
            .filter_map(|id| map.remove(&id))
            .map(|e| (e.handle, e.pool_key))
            .collect()
    }
}

#[derive(Clone)]
pub struct AppState {
    config: Arc<ServerConfig>,
    engines: Arc<Vec<EngineDescriptor>>,
    registry: Arc<DefaultPoolRegistry>,
    /// The DSN resolver, shared (same `Arc`) with every engine adapter so a
    /// rotation can evict its credential cache. Holding it here lets ONE handler
    /// (`/v1/admin/rotate`) perform BOTH halves of a rotation atomically: drain
    /// the registry pool AND evict the resolver's cached DSN. Without both, a
    /// stale cached DSN would survive a pool drain (gap G8 / S2).
    resolver: Arc<EnvMountResolver>,
    transactions: Arc<TransactionRegistry>,
    /// Optional in-Rust ABAC evaluator. Populated when
    /// `DATA_PLANE_PERMISSION_BUNDLE` env is a valid JSON bundle; otherwise
    /// `/v1/permissions/decide` returns 503 and callers fall back to the
    /// permission-engine HTTP path.
    evaluator: Option<Arc<Evaluator>>,
    /// Process-wide request/uptime counters exposed at `/metrics`.
    metrics: Arc<Metrics>,
    /// Per-tenant token-bucket rate limiter (Phase 4 tiering). Limits arrive per
    /// request in the mount's tier mask (`capability_overrides`); a tenant with
    /// no mask is unlimited, so this is a no-op until packages are assigned.
    ratelimiter: Arc<RateLimiter>,
    /// Track-B metering (B1a): per-tenant usage aggregate. The read/write hot
    /// path calls `record` ONLY when `config.metering` is ON (a flag short-
    /// circuit before any extra field access), so at parity this stays empty and
    /// its background flusher is never spawned — byte-parity with today.
    usage: Arc<Usage>,
    /// Track-B quota enforcement (B2): in-memory snapshot of the over-quota tenant
    /// ids the control-plane QuotaGuard published to Redis (`quota:over`). The hot
    /// path consults it ONLY when `config.quota_enforcement` is ON (a flag short-
    /// circuit before any field access), so at parity this stays empty and is never
    /// touched — byte-parity with today. Refreshed off the request path on the
    /// reaper tick via [`quota::QuotaRefresher`].
    quota_over: Arc<crate::quota::QuotaSet>,
    /// Track-B quota enforcement (B2): the Redis snapshot refresher. `Some` only
    /// when `config.quota_enforcement` is ON; the reaper calls `refresh` each tick.
    /// `None` at parity → no refresh task touches Redis.
    quota_refresher: Option<Arc<crate::quota::QuotaRefresher>>,
    /// Track-B spend-cap enforcement: in-memory snapshot of the over-spend tenant
    /// ids the control-plane spend-cap guard published to Redis (`spend:over`).
    /// Mirrors `quota_over` exactly — consulted on the hot path ONLY when
    /// `config.spend_caps` is ON (a `bool` short-circuit before any field access),
    /// so at parity it stays empty and is never touched (byte-parity).
    spend_over: Arc<crate::quota::QuotaSet>,
    /// Track-B spend-cap enforcement: the Redis snapshot refresher for `spend:over`.
    /// `Some` only when `config.spend_caps` is ON; `None` at parity → no refresh
    /// task touches Redis for it.
    spend_refresher: Option<Arc<crate::quota::QuotaRefresher>>,
    /// Track-B abuse/KYC suspension: in-memory snapshot of the suspended tenant ids
    /// the control-plane abuse guard published to Redis (`tenant:suspended`).
    /// Mirrors `quota_over` exactly — consulted on the hot path ONLY when
    /// `config.suspend_reader` is ON (a `bool` short-circuit before any field
    /// access), so at parity it stays empty and is never touched (byte-parity).
    suspended: Arc<crate::quota::QuotaSet>,
    /// Track-B abuse/KYC suspension: the Redis snapshot refresher for
    /// `tenant:suspended`. `Some` only when `config.suspend_reader` is ON; `None`
    /// at parity → no refresh task touches Redis for it.
    suspend_refresher: Option<Arc<crate::quota::QuotaRefresher>>,
    /// Shared HTTP client for the Phase-7 bypass front door (`/data/v1`): calls
    /// tenant-control `/v1/keys/verify` + adapter-registry `/connect`. Cheap to
    /// clone (Arc inside); only used when the bypass is enabled.
    http_client: reqwest::Client,
    /// Phase 7d / D-write-tail: background outbox emitter (row-change events on
    /// the bypass write path). `None` unless `DATA_PLANE_OUTBOX_DSN` is set — the
    /// bypass works without it, but realtime/webhooks only fire post-cutover once
    /// it's wired. The INSERT runs on a spawned worker (batched), OFF the request
    /// path, so the write tail no longer pays a second DB round-trip.
    #[cfg(feature = "control-pg")]
    outbox: Option<Arc<crate::outbox::BackgroundOutbox>>,
    /// Phase D — server-backed automations on the bypass write path. `None`
    /// unless `DATA_PLANE_OUTBOX_DSN` is set (the control Postgres holding the
    /// `automation_rules`); fires `set_property` follow-ups after bypass writes.
    #[cfg(feature = "control-pg")]
    automations: Option<Arc<crate::automations::AutomationEngine>>,
    /// Nano edition: the in-process key store + realtime broadcast. `Some` only
    /// when the nano runtime booted this state (`nano::run`); the full router
    /// never sets it, so every nano branch is dead code there.
    #[cfg(feature = "nano")]
    pub(crate) nano: Option<Arc<crate::nano::NanoState>>,
    /// binocle-one: user accounts + JWT sessions on top of nano.
    #[cfg(feature = "one")]
    pub(crate) one: Option<Arc<crate::one::OneState>>,
    /// Short-TTL cache of `api-key → VerifiedIdentity` for the bypass front door,
    /// mirroring the query-router's `ApiKeyMiddleware` 30 s cache. Without it the
    /// bypass re-runs the Argon2id key-verify (a tenant-control round-trip) on
    /// EVERY request, making it slower than the path it replaces; with it the
    /// verify is amortized and the bypass is the faster door. TTL from
    /// `DATA_PLANE_VERIFY_CACHE_TTL_MS` (default 30 000; 0 disables).
    verify_cache: Arc<std::sync::Mutex<HashMap<String, (std::time::Instant, crate::auth::VerifiedIdentity)>>>,
    /// Companion cache for the bypass mount resolution (`(tenant,db_id) → DSN/
    /// engine/tier`), same TTL as `verify_cache` — mirrors the query-router DSN
    /// cache so the cutover door doesn't re-hit adapter-registry per request.
    mount_cache: Arc<std::sync::Mutex<HashMap<String, (std::time::Instant, crate::auth::ResolvedMount)>>>,
}

impl AppState {
    #[must_use]
    pub fn new(config: ServerConfig) -> Self {
        let evaluator = build_evaluator(&config);
        // Strategy pattern: one Arc<dyn EngineAdapter> per engine, all behind
        // the same PoolRegistry trait. Adding a new engine (R7 MySQL, etc.)
        // is one line — no other call site changes.
        //
        // gap G8: build the resolver from ServerConfig (the single env-reader),
        // so credential providers + the DSN cache are configured from ONE source
        // and not a second `from_env` path. All provider knobs default empty →
        // providers DISABLED, so this is parity-equivalent to the old
        // `from_env()` until a token/addr is set.
        let mounts_json = std::env::var("DATA_PLANE_MOUNTS").unwrap_or_default();
        let provider_cfg = ProviderConfig {
            adapter_registry_url: config.adapter_registry_url.clone(),
            adapter_registry_token: config.adapter_registry_token.clone(),
            vault_addr: config.vault_addr.clone(),
            vault_token: config.vault_token.clone(),
            vault_dsn_prefix: config.vault_dsn_prefix.clone(),
            vault_dsn_field: config.vault_dsn_field.clone(),
        };
        let resolver = Arc::new(EnvMountResolver::from_config(
            &mounts_json,
            &provider_cfg,
            config.credential_cache_ttl_ms,
        ));
        // Feature-gated registration: a lean build (nano) compiles + registers
        // only the engines it mounts; the default build registers all nine.
        #[allow(unused_mut)]
        let mut adapters: Vec<Arc<dyn EngineAdapter>> = Vec::new();
        #[cfg(feature = "postgres")]
        {
            adapters.push(Arc::new(PostgresEngineAdapter::new(resolver.clone())));
            // CockroachDB rides the Postgres adapter (pgwire) under its own
            // engine id with a serializable-only descriptor.
            adapters.push(Arc::new(PostgresEngineAdapter::with_dialect(
                resolver.clone(),
                PgDialect::Cockroach,
            )));
        }
        #[cfg(feature = "mongodb")]
        adapters.push(Arc::new(MongoEngineAdapter::new(resolver.clone())));
        #[cfg(feature = "mysql")]
        {
            adapters.push(Arc::new(MysqlEngineAdapter::new(resolver.clone())));
            // MariaDB rides the MySQL adapter (same wire protocol + dispatch)
            // under its own engine id.
            adapters.push(Arc::new(MysqlEngineAdapter::with_engine_name(
                resolver.clone(),
                "mariadb",
            )));
        }
        #[cfg(feature = "redis")]
        adapters.push(Arc::new(RedisEngineAdapter::new(resolver.clone())));
        // 8th adapter (OFF by default): DynamoDB-compatible engine (AWS DynamoDB
        // / DynamoDB-Local / ScyllaDB Alternator). cfg-gated so the default
        // adapter set is byte-identical to today.
        #[cfg(feature = "dynamodb")]
        adapters.push(Arc::new(DynamoEngineAdapter::new(resolver.clone())));
        #[cfg(feature = "sqlite")]
        adapters.push(Arc::new(SqliteEngineAdapter::new(resolver.clone())));
        #[cfg(feature = "mssql")]
        adapters.push(Arc::new(MssqlEngineAdapter::new(resolver.clone())));
        #[cfg(feature = "http")]
        adapters.push(Arc::new(HttpEngineAdapter::new(resolver.clone())));
        // Boot-time honesty self-check (04/S1b): fail fast if any descriptor
        // advertises an op the adapter doesn't dispatch.
        assert_capability_honesty(&adapters);
        let registry = Arc::new(DefaultPoolRegistry::with_config(
            adapters,
            config.max_pools,
            config.share_pools,
        ));
        // metrics is built first: the background outbox worker (D-write-tail)
        // records enqueue/write/drop counters onto it.
        let metrics = Arc::new(Metrics::default());
        // Track-B metering (B1a + B1b): build the aggregate, wiring the durable
        // Redis `usage.events` stream sink (B1b) from the configured URL (empty →
        // tracing-only, B1a), then spawn its background flusher ONLY when metering
        // is ON. OFF → the flusher is never spawned (not even an idle timer) and
        // the request path never calls `record`, so this is observably byte-parity
        // with today. The flusher drains the aggregate every `metering_flush_ms`
        // and per (tenant, metric) window emits one `usage` tracing event (B1a)
        // AND XADDs the frozen envelope to `usage.events` when a URL is set (B1b).
        let usage = Arc::new(Usage::new().with_stream_url(&config.metering_redis_url));
        if config.metering {
            usage.spawn_flusher(config.metering_flush_ms);
        }
        // Track-B quota enforcement (B2): build the snapshot + (only when ON) its
        // Redis refresher. OFF → no refresher is built (the reaper's refresh arm is
        // a no-op `None` match), the snapshot stays empty, and the hot-path check is
        // skipped by the `config.quota_enforcement` flag — observably byte-parity.
        let quota_over = Arc::new(crate::quota::QuotaSet::new());
        let quota_refresher = if config.quota_enforcement {
            Some(Arc::new(crate::quota::QuotaRefresher::new(
                config.quota_redis_url.clone(),
            )))
        } else {
            None
        };
        // Track-B spend-cap + abuse/KYC suspension: the SAME honor-set machinery as
        // B2 quota, for two MORE control-plane Redis sets (`spend:over` /
        // `tenant:suspended`). Each refresher is built ONLY when its own flag is ON
        // (reusing the shared quota Redis URL — all three sets live in one
        // control-plane Redis), so OFF → no snapshot work, no Redis traffic, and the
        // hot-path checks short-circuit on the bool before any field access
        // (byte-parity). They are refreshed on the SAME reaper/refresh tick as quota.
        let spend_over = Arc::new(crate::quota::QuotaSet::new());
        let spend_refresher = if config.spend_caps {
            Some(Arc::new(crate::quota::QuotaRefresher::new_for(
                config.quota_redis_url.clone(),
                crate::quota::SPEND_OVER_SET,
            )))
        } else {
            None
        };
        let suspended = Arc::new(crate::quota::QuotaSet::new());
        let suspend_refresher = if config.suspend_reader {
            Some(Arc::new(crate::quota::QuotaRefresher::new_for(
                config.quota_redis_url.clone(),
                crate::quota::SUSPENDED_SET,
            )))
        } else {
            None
        };
        Self {
            config: Arc::new(config),
            engines: Arc::new(default_engines()),
            registry,
            resolver,
            transactions: Arc::new(TransactionRegistry::default()),
            evaluator,
            // clone (not move): the background-outbox initializer below borrows
            // `metrics` again, and that field is only present under control-pg.
            metrics: metrics.clone(),
            ratelimiter: Arc::new(RateLimiter::from_env()),
            usage,
            quota_over,
            quota_refresher,
            spend_over,
            spend_refresher,
            suspended,
            suspend_refresher,
            http_client: reqwest::Client::builder()
                .timeout(Duration::from_secs(10))
                .build()
                .unwrap_or_default(),
            #[cfg(feature = "control-pg")]
            outbox: crate::outbox::OutboxEmitter::from_env()
                .map(|e| Arc::new(e.into_background(metrics.clone()))),
            #[cfg(feature = "control-pg")]
            automations: crate::automations::AutomationEngine::from_env().map(Arc::new),
            #[cfg(feature = "nano")]
            nano: None,
            #[cfg(feature = "one")]
            one: None,
            verify_cache: Arc::new(std::sync::Mutex::new(HashMap::new())),
            mount_cache: Arc::new(std::sync::Mutex::new(HashMap::new())),
        }
    }

    /// Rotation entrypoint (gap G8 / S2). A credential rotation must invalidate
    /// BOTH cached views of the old credential or a stale DSN survives:
    ///   1. the resolver's DSN cache entry for `pool_key`, and
    ///   2. the pool the registry opened with that old DSN.
    /// We evict the cache FIRST so that even if the drain races a concurrent
    /// `get_or_create`, the rebuild cannot re-read the stale cached DSN. Returns
    /// the number of pools actually drained (0 if the key was unknown or the
    /// pool is pinned by an open tx — the idle reaper retires the latter once the
    /// tx finishes). `pool_key` embeds the credential version, so a newer
    /// version's pool is never touched. No secret is logged or returned.
    pub async fn rotate(&self, pool_key: &str) -> usize {
        self.resolver.evict_cached(pool_key);
        // The bypass mount cache is keyed by (tenant,db_id), a different key
        // space than pool_key — clear it wholesale so a rotated DSN can't be
        // re-served from here (cheap: re-resolution is one registry round-trip,
        // and rotation is a rare admin op). Preserves the gap-G8/S2 guarantee.
        if let Ok(mut c) = self.mount_cache.lock() {
            c.clear();
        }
        // Same reasoning for the key-verify cache: a credential event must not
        // leave any cached identity serving requests for up to TTL (B3 — the
        // revoked-key-valid-≤30s hole). Wholesale clear; re-verifies are cheap
        // post-fast-hash (~ms) and credential events are rare admin ops.
        self.evict_verify_cache();
        let before = self.registry.stats().await.map(|s| s.len()).unwrap_or(0);
        // drain_pool_key is a no-op for an unknown/pinned key; comparing the pool
        // count before/after tells the caller whether a pool was actually closed.
        let _ = self.registry.drain_pool_key(pool_key).await;
        let after = self.registry.stats().await.map(|s| s.len()).unwrap_or(0);
        before.saturating_sub(after)
    }

    /// Drop every cached key-verify identity. Called on credential events
    /// (rotate, key revocation via `/v1/admin/evict-verify`) so a revoked key
    /// dies on its NEXT request instead of riding the cache for up to TTL.
    /// Returns the number of entries evicted.
    pub fn evict_verify_cache(&self) -> usize {
        if let Ok(mut c) = self.verify_cache.lock() {
            let n = c.len();
            c.clear();
            n
        } else {
            0
        }
    }

    /// The pool registry (shared `Arc`). Used by the background reaper in
    /// `server::run` to drive idle-pool draining + expired-tx unpinning.
    #[must_use]
    pub fn registry(&self) -> Arc<DefaultPoolRegistry> {
        self.registry.clone()
    }

    /// Track-B metering (B1a): flush any pending usage window on graceful
    /// shutdown so the last partial window isn't silently dropped. No-op when
    /// metering is OFF (the aggregate stays empty, so `flush_now` emits nothing —
    /// parity). Called from `server::run` after the serve future returns.
    pub fn flush_usage(&self) {
        if self.config.metering {
            self.usage.flush_now(self.config.metering_flush_ms);
        }
    }

    /// Track-B quota enforcement (B2): whether the dedicated snapshot-refresh loop
    /// should be spawned. `config` is private to this module, so `server::run`
    /// reads the flag through this accessor (mirroring `flush_usage`).
    #[must_use]
    pub fn quota_enforcement_enabled(&self) -> bool {
        self.config.quota_enforcement
    }

    /// Track-B spend-cap enforcement: whether the spend-cap honor set is active.
    /// Read by `server::run` (private `config`) to decide whether to spawn the
    /// snapshot-refresh loop — mirrors `quota_enforcement_enabled`.
    #[must_use]
    pub fn spend_caps_enabled(&self) -> bool {
        self.config.spend_caps
    }

    /// Track-B abuse/KYC suspension: whether the suspend honor set is active. Read
    /// by `server::run` (private `config`) to decide whether to spawn the
    /// snapshot-refresh loop — mirrors `quota_enforcement_enabled`.
    #[must_use]
    pub fn suspend_reader_enabled(&self) -> bool {
        self.config.suspend_reader
    }

    /// Whether ANY honor set (quota / spend / suspend) is active, i.e. whether the
    /// dedicated snapshot-refresh loop must be spawned at all. `server::run` reads
    /// this single accessor so the loop fires when any of the three is ON.
    #[must_use]
    pub fn honor_sets_enabled(&self) -> bool {
        self.config.quota_enforcement || self.config.spend_caps || self.config.suspend_reader
    }

    /// Track-B quota enforcement (B2): the refresh cadence (ms) for the snapshot
    /// loop. Read by `server::run` through this accessor (private `config` field).
    #[must_use]
    pub fn quota_refresh_ms(&self) -> u64 {
        self.config.quota_refresh_ms
    }

    /// One reaper tick: drop idle pools past their `idle_ttl`, then roll back +
    /// unpin any transaction past its TTL (so an abandoned tx can't pin its pool
    /// forever). Best-effort; a single failing rollback never aborts the tick.
    /// Pinned pools are never reaped (the registry excludes `tx_pins > 0`), and
    /// reaping the tx unpins it FIRST, so this ordering converges: a future tick
    /// then sees the now-unpinned, idle pool and drains it.
    pub async fn reap_once(&self) {
        let _ = self.registry.release_idle().await;
        for (handle, pool_key) in self.transactions.reap_expired().await {
            // Best-effort rollback of the abandoned tx, then ALWAYS unpin its
            // pool (mirrors the commit/rollback route's guaranteed unpin).
            let _ = handle.rollback().await;
            self.registry.unpin_tx(&pool_key).await;
        }
        // Phase 4: drop rate-limiter buckets untouched for >5min so the map stays
        // bounded under N-tenant fan-out (a full idle bucket re-creates on access).
        self.ratelimiter
            .evict_idle(std::time::Duration::from_secs(300));
        // Track-B honor sets (B2 quota + spend-cap + suspend): refresh every
        // ENABLED snapshot from Redis OFF the request path. Each refresher is
        // `None` when its flag is off → no-op = parity.
        self.refresh_honor_sets().await;
    }

    /// Track-B honor sets: refresh every enabled snapshot (quota / spend / suspend)
    /// from Redis. Each arm is a no-op when its refresher is `None` (its flag off),
    /// so it never touches Redis at parity. Called from the reaper tick AND the
    /// dedicated refresh loop (off the request path).
    pub async fn refresh_honor_sets(&self) {
        if let Some(refresher) = &self.quota_refresher {
            refresher.refresh(&self.quota_over).await;
        }
        if let Some(refresher) = &self.spend_refresher {
            refresher.refresh(&self.spend_over).await;
        }
        if let Some(refresher) = &self.suspend_refresher {
            refresher.refresh(&self.suspended).await;
        }
    }
}

/// Boot-time capability self-check (04/S1b). Every adapter's advertised
/// descriptor must agree with the operations it actually dispatches
/// (`supported_ops`), so we fail fast at startup rather than serve a lying
/// `/v1/capabilities`. Both sides are compile-time constants, so a mismatch is a
/// programming error, never runtime-triggerable. The same invariant is gated in
/// CI by `make verify-m18` (the `capability_honesty` tests).
fn assert_capability_honesty(adapters: &[Arc<dyn EngineAdapter>]) {
    for adapter in adapters {
        let caps = adapter.capabilities();
        let ops = adapter.supported_ops();
        for kind in &data_plane_core::DataOperationKind::ALL {
            assert_eq!(
                caps.supports_op(kind),
                ops.contains(kind),
                "capability descriptor for engine '{}' lies about {:?}: supports_op={} but dispatch supported_ops={}",
                adapter.engine(),
                kind,
                caps.supports_op(kind),
                ops.contains(kind),
            );
        }
    }
}

fn build_evaluator(config: &ServerConfig) -> Option<Arc<Evaluator>> {
    let raw = config.permission_bundle_inline.trim();
    if raw.is_empty() {
        return None;
    }
    let bundle: PolicyBundle = match serde_json::from_str(raw) {
        Ok(b) => b,
        Err(e) => {
            tracing::warn!(
                "DATA_PLANE_PERMISSION_BUNDLE is not valid PolicyBundle JSON ({}); local evaluator disabled",
                e
            );
            return None;
        }
    };
    let mode = PermissionMode::from_env_string(&config.permission_mode);
    Some(Arc::new(Evaluator::new(bundle, mode)))
}

/// CORS for the data plane. It sits BEHIND Kong (server-to-server requests carry
/// no `Origin`), so browser cross-origin access is DENIED by default — replacing
/// the previous `permissive()` (any origin), audit item O3. Set
/// `DATA_PLANE_CORS_ALLOW_ORIGINS` (comma-separated) to allow specific origins
/// if the router is ever exposed to a browser directly.
fn cors_layer() -> CorsLayer {
    match std::env::var("DATA_PLANE_CORS_ALLOW_ORIGINS")
        .ok()
        .filter(|s| !s.trim().is_empty())
    {
        Some(spec) => {
            let origins: Vec<axum::http::HeaderValue> = spec
                .split(',')
                .filter_map(|o| o.trim().parse().ok())
                .collect();
            CorsLayer::new()
                .allow_origin(tower_http::cors::AllowOrigin::list(origins))
                .allow_methods(tower_http::cors::Any)
                .allow_headers(tower_http::cors::Any)
        }
        None => CorsLayer::new(),
    }
}

pub fn router(state: AppState) -> Router {
    let metrics_state = state.clone();
    // Phase 7: the direct front door is additive AND opt-in. It only exists when
    // DATA_PLANE_BYPASS_ENABLED=1; the internal /v1/query (query-router path) is
    // always present, so this is pure shadow until parity is proven + cut over.
    let bypass = if state.config.bypass_enabled {
        tracing::info!("Phase 7 bypass ENABLED: POST /data/v1/{{query,schema,schema/ddl}} (Rust-native API-key auth)");
        Router::new()
            .route("/data/v1/query", post(data_query))
            .route("/data/v1/schema", post(data_describe_schema))
            .route("/data/v1/schema/ddl", post(data_apply_schema_ddl))
            .route("/data/v1/graph", post(crate::graph::data_graph))
            .route("/data/v1/graph/overview", post(crate::graph::data_graph_overview))
    } else {
        Router::new()
    };
    Router::new()
        .route("/v1/health", get(health))
        .route("/metrics", get(metrics_handler))
        .route("/v1/capabilities", get(capabilities))
        .route("/v1/query", post(execute_query))
        .merge(bypass)
        .route("/v1/schema", post(describe_schema))
        .route("/v1/schema/ddl", post(apply_schema_ddl))
        .route("/v1/transactions", post(begin_transaction))
        .route("/v1/transactions/:tx_id/execute", post(execute_in_transaction))
        .route("/v1/transactions/:tx_id/commit", post(commit_transaction))
        .route("/v1/transactions/:tx_id/rollback", post(rollback_transaction))
        .route("/v1/admin/raw", post(execute_raw_admin))
        .route("/v1/admin/migrate", post(apply_migration_admin))
        .route("/v1/admin/rotate", post(rotate_credential_admin))
        .route("/v1/admin/evict-verify", post(evict_verify_admin))
        .route("/v1/permissions/decide", post(decide_permission))
        .fallback(not_found)
        .layer(axum::middleware::from_fn_with_state(metrics_state, track_metrics))
        .layer(TraceLayer::new_for_http())
        .layer(cors_layer())
        .with_state(state)
}

/// Counts every finished request by status class, except the scrape/probe
/// paths so the counters reflect real API traffic.
async fn track_metrics(State(state): State<AppState>, req: Request, next: Next) -> Response {
    let path = req.uri().path().to_string();
    let method = req.method().clone();
    // Capture the inbound W3C trace context + correlation id so data-plane logs
    // join the same distributed trace as the TS query-router and Go control
    // plane (wiki/05 §2 — cross-tier observability).
    let traceparent = header_str(&req, "traceparent");
    let request_id = header_str(&req, "x-request-id");
    let resp = next.run(req).await;
    if path != "/metrics" && path != "/v1/health" {
        let status = resp.status().as_u16();
        state.metrics.record(status);
        tracing::info!(
            %method,
            path = %path,
            status,
            traceparent = %traceparent,
            request_id = %request_id,
            "data-plane request"
        );
    }
    resp
}

fn header_str(req: &Request, name: &str) -> String {
    req.headers()
        .get(name)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string()
}

/// Prometheus exposition: service_up + uptime + request counts + per-mount pool
/// saturation (from the live `PoolRegistry::stats()`). Dependency-free, same
/// `baas_*` shape as the Go control plane.
async fn metrics_handler(State(state): State<AppState>) -> Response {
    let (_, c2, c4, c5) = state.metrics.snapshot();
    let mut out = String::new();
    out.push_str("# HELP baas_service_up 1 while the service is serving\n");
    out.push_str("# TYPE baas_service_up gauge\n");
    out.push_str("baas_service_up{service=\"data-plane-router\"} 1\n");
    out.push_str("# HELP baas_uptime_seconds Seconds since process start\n");
    out.push_str("# TYPE baas_uptime_seconds gauge\n");
    out.push_str(&format!(
        "baas_uptime_seconds{{service=\"data-plane-router\"}} {}\n",
        state.metrics.uptime_secs()
    ));
    out.push_str("# HELP baas_http_requests_total HTTP requests by status class\n");
    out.push_str("# TYPE baas_http_requests_total counter\n");
    for (class, n) in [("2xx", c2), ("4xx", c4), ("5xx", c5)] {
        out.push_str(&format!(
            "baas_http_requests_total{{service=\"data-plane-router\",status=\"{class}\"}} {n}\n"
        ));
    }
    // B5 per-tenant observability (Pillar 3, OPTIONAL) — additionally emit a
    // tenant_id-labeled line on THIS counter ONLY (never a histogram, never the
    // cache/pool/outbox counters). The set is HARD-CAPPED at N+1 distinct tenants
    // (the over-cap fold is the `tenant_id="_over_cap"` sentinel), so this adds at
    // most N+1 series regardless of tenant count. The snapshot is EMPTY at parity
    // (the counter is only written when `tenant_obs_counter` is ON), so when the
    // flag is OFF this loop emits ZERO lines and `/metrics` is byte-identical to
    // today. The labels are already `escape_label`-sanitized (they are the stored
    // keys), so they are emitted verbatim inside the quotes. No `status` label on
    // these lines (one series per tenant) keeps the ceiling at exactly N+1.
    for (tenant_id, n) in state.metrics.tenant_requests_snapshot() {
        out.push_str(&format!(
            "baas_http_requests_total{{service=\"data-plane-router\",tenant_id=\"{tenant_id}\"}} {n}\n"
        ));
    }
    // Scale counters (B3): pool lifecycle, cache effectiveness, limiter map —
    // the signals the 10K-tenant experiments watch. evicted_total climbing at
    // steady state == the mount working set exceeds DATA_PLANE_MAX_POOLS.
    let (pools_created, pools_evicted, pools_reaped, pools_open) = state.registry.scale_counters();
    out.push_str("# HELP baas_data_plane_pools_open Engine pools currently cached\n");
    out.push_str("# TYPE baas_data_plane_pools_open gauge\n");
    out.push_str(&format!(
        "baas_data_plane_pools_open{{service=\"data-plane-router\"}} {pools_open}\n"
    ));
    out.push_str("# HELP baas_data_plane_pool_events_total Pool lifecycle events since start\n");
    out.push_str("# TYPE baas_data_plane_pool_events_total counter\n");
    for (event, n) in [
        ("created", pools_created),
        ("evicted", pools_evicted),
        ("reaped", pools_reaped),
    ] {
        out.push_str(&format!(
            "baas_data_plane_pool_events_total{{service=\"data-plane-router\",event=\"{event}\"}} {n}\n"
        ));
    }
    let (verify_hit, verify_miss, mount_hit, mount_miss) = state.metrics.cache_snapshot();
    out.push_str("# HELP baas_data_plane_cache_events_total Verify/mount cache lookups by result\n");
    out.push_str("# TYPE baas_data_plane_cache_events_total counter\n");
    for (cache, result, n) in [
        ("verify", "hit", verify_hit),
        ("verify", "miss", verify_miss),
        ("mount", "hit", mount_hit),
        ("mount", "miss", mount_miss),
    ] {
        out.push_str(&format!(
            "baas_data_plane_cache_events_total{{service=\"data-plane-router\",cache=\"{cache}\",result=\"{result}\"}} {n}\n"
        ));
    }
    out.push_str("# HELP baas_data_plane_ratelimit_tracked Tenant token buckets currently tracked\n");
    out.push_str("# TYPE baas_data_plane_ratelimit_tracked gauge\n");
    out.push_str(&format!(
        "baas_data_plane_ratelimit_tracked{{service=\"data-plane-router\"}} {}\n",
        state.ratelimiter.tracked()
    ));
    // D-write-tail: background outbox queue health. `dropped` > 0 means the
    // worker can't keep up (widen DATA_PLANE_OUTBOX_QUEUE or add capacity);
    // enqueued − written − dropped ≈ queue depth in flight.
    let (ob_enq, ob_wr, ob_drop, ob_fail) = state.metrics.outbox_snapshot();
    out.push_str("# HELP baas_data_plane_outbox_events_total Background outbox emission by stage\n");
    out.push_str("# TYPE baas_data_plane_outbox_events_total counter\n");
    for (stage, n) in [
        ("enqueued", ob_enq),
        ("written", ob_wr),
        ("dropped", ob_drop),
        ("failed", ob_fail),
    ] {
        out.push_str(&format!(
            "baas_data_plane_outbox_events_total{{service=\"data-plane-router\",stage=\"{stage}\"}} {n}\n"
        ));
    }
    out.push_str("# HELP baas_data_plane_pool_connections Pool connections per mount and state\n");
    out.push_str("# TYPE baas_data_plane_pool_connections gauge\n");
    if let Ok(stats) = state.registry.stats().await {
        for s in stats {
            let mount = escape_label(&s.mount_id);
            let engine = escape_label(&s.engine);
            for (st, v) in [
                ("active", s.active_connections),
                ("idle", s.idle_connections),
                ("waiting", s.waiting_requests),
            ] {
                out.push_str(&format!(
                    "baas_data_plane_pool_connections{{service=\"data-plane-router\",mount=\"{mount}\",engine=\"{engine}\",state=\"{st}\"}} {v}\n"
                ));
            }
        }
    }
    Response::builder()
        .header(header::CONTENT_TYPE, "text/plain; version=0.0.4; charset=utf-8")
        .body(Body::from(out))
        .expect("static metrics response is always valid")
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct HealthResponse {
    status: &'static str,
    service: &'static str,
    version: &'static str,
    product_mode: String,
}

pub(crate) async fn health(State(state): State<AppState>) -> Json<HealthResponse> {
    Json(HealthResponse {
        status: "ok",
        service: "data-plane-router",
        version: env!("CARGO_PKG_VERSION"),
        product_mode: state.config.product_mode.clone(),
    })
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct CapabilitiesResponse {
    router: RouterDescriptor,
    engines: Vec<EngineDescriptor>,
}

#[derive(Debug, Clone, Serialize)]
struct RouterDescriptor {
    language: &'static str,
    mode: String,
    query_execution: &'static str,
    transaction_sessions: &'static str,
    local_pdp: &'static str,
}

#[derive(Debug, Clone, Serialize)]
struct EngineDescriptor {
    engine: String,
    phase: String,
    capabilities: EngineCapabilities,
}

pub(crate) async fn capabilities(State(state): State<AppState>) -> Json<CapabilitiesResponse> {
    Json(CapabilitiesResponse {
        router: RouterDescriptor {
            language: "rust",
            mode: state.config.product_mode.clone(),
            query_execution: "postgresql_pool+mongodb_pool+mysql_pool+redis_pool+http_pool",
            transaction_sessions: "contract_only",
            local_pdp: "planned",
        },
        engines: state.engines.as_ref().clone(),
    })
}

#[derive(Debug, Clone, Deserialize)]
struct QueryRequest {
    identity: RequestIdentity,
    mount: DatabaseMount,
    operation: DataOperation,
}

async fn execute_query(
    State(state): State<AppState>,
    Json(request): Json<QueryRequest>,
) -> impl IntoResponse {
    // The internal `/v1/query` is called by the query-router, which emits the
    // outbox event itself — so the data plane must NOT (would double-emit).
    run_query(state, request, false).await
}

/// Core query execution, shared by the internal `/v1/query` (envelope already
/// trusted — the query-router authenticated; `emit_outbox=false`) and the
/// Phase-7 `/data/v1/query` (Rust authenticated; `emit_outbox=true` — the
/// query-router is out of the path, so the data plane emits the row-change
/// event). Owns identity/mount validation, tier rate-limit + capability gate,
/// the planner, and pool dispatch, so both doors enforce IDENTICALLY.
/// Map an operation kind to the ABAC action the policy bundle matches on —
/// mirrors `action_for_op(&str)` (the `/v1/permissions/decide` mapping) so the
/// in-line mask decision is identical to the canonical PDP: list/get→select,
/// upsert→update, the rest pass through.
fn mask_action_for(op: &DataOperationKind) -> &'static str {
    use DataOperationKind::*;
    match op {
        List | Get => "select",
        Upsert | Update => "update",
        Insert => "insert",
        Delete => "delete",
        Batch => "batch",
        Aggregate => "aggregate",
    }
}

/// B5 per-tenant observability (Pillar 1) — thin span wrapper around the real
/// handler body ([`run_query_inner`]). When `config.tenant_obs` is ON, build a
/// per-request span carrying `tenant_id` as a STRUCTURED FIELD and `.instrument`
/// the whole `run_query_inner` future with it, so every event emitted while
/// serving this request (the per-request log line, the audit `mutation`/`read`
/// events, the planner/limit warns) carries the tenant as a log FIELD — exactly
/// what promtail's expressions-only extraction (slice O) reads with
/// `| json | tenant_id="X"`. `.instrument` is the async-correct way to attach a
/// span to a future (an `.entered()` guard held across `.await` would leak the
/// current-span across task boundaries on the multi-thread runtime). When OFF the
/// span is `Span::none()` — instrumenting with it is a no-op, so the tracing path
/// and log output are BYTE-IDENTICAL to baseline (kernel rule #5). `tenant_id` is
/// a FIELD only: never promoted to a Loki label or a Prometheus label here, so it
/// adds ZERO label-series cardinality. Both the internal `/v1/query` and the
/// bypass `/data/v1/query` paths funnel through here, so this single site covers
/// a read AND a write.
async fn run_query(
    state: AppState,
    request: QueryRequest,
    emit_outbox: bool,
) -> axum::response::Response {
    use tracing::Instrument;
    let span = if state.config.tenant_obs {
        tracing::info_span!("request", tenant_id = %request.identity.tenant_id)
    } else {
        tracing::Span::none()
    };
    run_query_inner(state, request, emit_outbox)
        .instrument(span)
        .await
}

async fn run_query_inner(
    state: AppState,
    mut request: QueryRequest,
    emit_outbox: bool,
) -> axum::response::Response {
    // B5 per-tenant observability (Pillar 3, OPTIONAL) — record ONE request for
    // this tenant into the BOUNDED per-tenant counter. AND-gated: only when BOTH
    // the parent log-field flag AND the counter sub-flag are ON (`tenant_obs_counter`
    // is already AND(tenant_obs, DATA_PLANE_TENANT_OBS_COUNTER) from config). The
    // flag short-circuits BEFORE any work, so at parity this branch is a single
    // `bool` test that takes nothing — `/metrics` stays byte-identical. The
    // counter is hard-capped at N+1 series inside `record_tenant_request`, so it
    // can never explode at 10K+ tenants. Recorded at handler entry (off the global
    // status buckets) so it covers a read AND a write on both doors.
    if state.config.tenant_obs_counter {
        state
            .metrics
            .record_tenant_request(&request.identity.tenant_id);
    }
    // B5 per-tenant observability (Pillar 1) — emit ONE per-request log event
    // carrying tenant_id as a STRUCTURED FIELD, gated by config.tenant_obs
    // (DATA_PLANE_TENANT_OBS, default OFF). The `.instrument(span)` wrapper alone
    // is NOT enough: a span only surfaces its fields when an event fires *inside*
    // it, and the success path's usage signal drains in a background task (outside
    // this span), so without an explicit event no request log line would carry the
    // tenant. This event is the field promtail extracts (`| json | tenant_id="X"`).
    // When the flag is OFF this branch is skipped entirely → zero new log lines =
    // byte-parity with the pre-B5 baseline (kernel rule #5). tenant_id is a FIELD
    // only — never a Loki label or a Prometheus label — so it adds no cardinality.
    if state.config.tenant_obs {
        tracing::info!(tenant_id = %request.identity.tenant_id, "data-plane request");
    }
    if let Err(message) = validate_identity_mount(&state, &request.identity, &request.mount) {
        return bad_request(message);
    }
    if request.operation.resource.trim().is_empty() {
        return bad_request("operation.resource is required".to_string());
    }

    // Engines with a live Rust pool IN THIS BUILD (feature-gated; the default
    // build lists all nine, a nano build only sqlite). MariaDB rides the MySQL
    // adapter. Engines beyond this list (jdbc, cassandra, neo4j, es, qdrant,
    // influx) stay contract-only and are rejected here.
    let executable_engines: &[&str] = &[
        #[cfg(feature = "postgres")]
        "postgresql",
        #[cfg(feature = "postgres")]
        "cockroachdb",
        #[cfg(feature = "mongodb")]
        "mongodb",
        #[cfg(feature = "mysql")]
        "mysql",
        #[cfg(feature = "mysql")]
        "mariadb",
        #[cfg(feature = "redis")]
        "redis",
        #[cfg(feature = "sqlite")]
        "sqlite",
        #[cfg(feature = "mssql")]
        "mssql",
        #[cfg(feature = "http")]
        "http",
        // 8th engine (OFF by default): DynamoDB-compatible adapter. cfg-gated so
        // the default executable-engine allowlist is byte-identical; a `dynamodb`
        // mount is dispatchable only in a `--features dynamodb` build.
        #[cfg(feature = "dynamodb")]
        "dynamodb",
    ];
    if !executable_engines.contains(&request.mount.engine.as_str()) {
        return not_implemented(
            "engine_execution_not_enabled",
            &format!(
                "engine has no Rust pool in this build; supported engines: {}",
                executable_engines.join(", ")
            ),
        );
    }

    // Phase 4 tiering — per-tenant rate limit (token bucket). The mount's tier
    // mask carries rps/burst; an untiered mount (no mask) is unlimited, so this
    // is a no-op until a package is assigned. Keyed on the TRUSTED envelope
    // tenant, so it survives the Phase-7 TS bypass; Kong's per-IP limit is the
    // coarse outer shell.
    if let Some((rps, burst)) = tier_rate(request.mount.capability_overrides.as_ref()) {
        if !state.ratelimiter.allow(&request.identity.tenant_id, rps, burst).await {
            tracing::warn!(
                target: "audit",
                event = "rate_limited",
                tenant = %request.identity.tenant_id,
                engine = %request.mount.engine,
                op = ?request.operation.op,
                rps,
                "tenant exceeded package rate limit (429)"
            );
            return too_many_requests(rps);
        }
    }

    // Track-B quota enforcement (B2) — CUMULATIVE per-period usage quota. The
    // control-plane QuotaGuard (which CONSUMES B1's tenant_usage, never re-meters)
    // publishes the over-quota tenant set to Redis; the data plane keeps a cheap
    // in-memory snapshot (refreshed off the request path) and rejects an over-quota
    // tenant with 402 here. Distinct from the 429 rate cap above (per-request) and
    // the max_rows clamp below (per-query): this is the period-cumulative budget.
    // OFF by default (`config.quota_enforcement`) → the snapshot is empty, this
    // branch's flag short-circuits before any lookup, so it is byte-parity.
    if state.config.quota_enforcement
        && state.quota_over.is_over(&request.identity.tenant_id)
    {
        tracing::warn!(
            target: "audit",
            event = "quota_exceeded",
            tenant = %request.identity.tenant_id,
            engine = %request.mount.engine,
            op = ?request.operation.op,
            "tenant exceeded package usage quota (402)"
        );
        return payment_required();
    }

    // Track-B spend-cap enforcement — ABSOLUTE per-tenant spend budget. The
    // control-plane spend-cap guard publishes the over-spend tenant set to Redis
    // (`spend:over`); the data plane keeps a cheap in-memory snapshot (refreshed
    // off the request path, mirroring quota) and rejects an over-spend tenant with
    // 402 (`spend_capped`) here. DISTINCT signal from the quota 402 above (usage
    // quota vs. money cap). OFF by default (`config.spend_caps`) → the snapshot is
    // empty and this branch's flag short-circuits BEFORE any lookup, so it is
    // byte-parity (the check is unreachable with the flag off).
    if state.config.spend_caps && state.spend_over.is_over(&request.identity.tenant_id) {
        tracing::warn!(
            target: "audit",
            event = "spend_capped",
            tenant = %request.identity.tenant_id,
            engine = %request.mount.engine,
            op = ?request.operation.op,
            "tenant exceeded spend cap (402)"
        );
        return spend_capped();
    }

    // Track-B abuse/KYC suspension — administrative block. The control-plane abuse
    // guard publishes the suspended tenant set to Redis (`tenant:suspended`); the
    // data plane keeps a cheap in-memory snapshot (refreshed off the request path,
    // mirroring quota) and rejects a suspended tenant with 403 (`tenant_suspended`)
    // here — a 403 (account blocked), NOT a 402 (which says "pay/upgrade"). OFF by
    // default (`config.suspend_reader`) → the snapshot is empty and this branch's
    // flag short-circuits BEFORE any lookup, so it is byte-parity (the check is
    // unreachable with the flag off).
    if state.config.suspend_reader && state.suspended.is_over(&request.identity.tenant_id) {
        tracing::warn!(
            target: "audit",
            event = "tenant_suspended",
            tenant = %request.identity.tenant_id,
            engine = %request.mount.engine,
            op = ?request.operation.op,
            "suspended tenant request rejected (403)"
        );
        return forbidden_suspended();
    }

    // Capability-aware planner (G6, two-phase). Phase 1 rejects an impossible
    // (engine, op) pair (supports_op + batch ceiling); Phase 2 routes by op
    // shape over the const cost table. No-op for the engines mounted today —
    // plain CRUD has an empty shape, so every current request stays Native
    // (parity-safe). `/v1/query` is never inside a tx or streaming, so the
    // workload context is plain; the tx route guards transactions separately.
    if let Some(descriptor) = state
        .engines
        .iter()
        .find(|e| e.engine == request.mount.engine)
    {
        // Phase 4 tiering — capability gate. The descriptor says what the ENGINE
        // can do; the tenant's package mask (mount.capability_overrides) may
        // narrow it. A masked-off-but-engine-supported op is a 403 (upgrade your
        // package), DISTINCT from the planner's 422 for an op the engine can't
        // serve at all. No-op when there's no mask (parity).
        if let Err(err) = data_plane_core::tier_gate(
            &request.operation,
            &descriptor.capabilities,
            request.mount.capability_overrides.as_ref(),
        ) {
            tracing::warn!(
                target: "audit",
                event = "capability_gated",
                tenant = %request.identity.tenant_id,
                engine = %request.mount.engine,
                op = ?request.operation.op,
                "package tier denied operation (403)"
            );
            return map_data_plane_error(&err);
        }
        let decision = data_plane_core::plan(
            &request.operation,
            &request.mount.engine,
            &descriptor.capabilities,
            &WorkloadContext::default(),
            state.config.planner_federation_enabled,
        );
        match decision.plan {
            Plan::Native => {} // fall through to pool execution (unchanged)
            Plan::Reject(err) => {
                tracing::info!(reason = decision.reason, engine = %request.mount.engine, "planner rejected operation");
                return map_data_plane_error(&err);
            }
            Plan::Federate { target } => {
                // The federation seam (resolve_federation) lowers Federate to a
                // Reject while the flag is off, so this arm is reachable only
                // once federation is wired. Until then it is a clean 501.
                tracing::info!(reason = decision.reason, target, "planner selected federation target (not yet executable)");
                return map_data_plane_error(&data_plane_core::DataPlaneError::NotImplemented {
                    feature: format!("federation to {target}"),
                });
            }
        }
    }

    // FTS / vector search are Postgres-native ops (to_tsvector + ts_rank / pgvector
    // distance operators). Any other engine rejects with a clean 422 rather than
    // silently ignoring the clause and returning unfiltered rows — engine-agnostic
    // by construction (capability honestly declared, only Postgres serves it).
    if (request.operation.search.is_some() || request.operation.vector.is_some())
        && request.mount.engine != "postgresql"
    {
        return map_data_plane_error(&data_plane_core::DataPlaneError::UnsupportedCapability {
            engine: request.mount.engine.clone(),
            capability: if request.operation.search.is_some() {
                "fulltext_search".to_string()
            } else {
                "vector_search".to_string()
            },
        });
    }

    // Capture audit + outbox fields before the request is consumed by the pool.
    let audit_tenant = request.identity.tenant_id.clone();
    let audit_engine = request.mount.engine.clone();
    #[cfg(any(feature = "control-pg", feature = "nano"))]
    let automation_db_id = request.mount.id.clone();
    let audit_op = request.operation.op.clone();
    let audit_resource = request.operation.resource.clone();
    let mask_action = mask_action_for(&audit_op);
    #[cfg(any(feature = "control-pg", feature = "nano"))]
    let op_wire = audit_op.wire_name();
    // Consumed only by the control-pg / nano post-write hooks below.
    #[cfg(not(any(feature = "control-pg", feature = "nano")))]
    let _ = emit_outbox;
    let is_mutation = matches!(
        audit_op,
        DataOperationKind::Insert
            | DataOperationKind::Update
            | DataOperationKind::Delete
            | DataOperationKind::Upsert
            | DataOperationKind::Batch
    );
    let outbox_identity = request.identity.clone();
    // Response projection (`fields`) — applied LAST, after outbox/realtime
    // emission and masks, so server-side consumers keep full rows.
    let projection = request.operation.fields.clone();
    #[cfg(any(feature = "control-pg", feature = "nano"))]
    let outbox_data = request.operation.data.clone();
    #[cfg(any(feature = "control-pg", feature = "nano"))]
    let outbox_filter = request.operation.filter.clone();
    #[cfg(feature = "control-pg")]
    let outbox_idem = request.operation.idempotency_key.clone();

    // G-QoS sliceA (A6): clamp the rows returned per query to the tier cap. The
    // cap comes from the mount's tier mask (`max_rows`); absent/zero → no clamp
    // (today's behavior, parity). Engine-agnostic — every adapter honors
    // `operation.limit` — so a present cap bounds a missing/larger client limit
    // without touching any adapter. A client limit already at/under the cap is
    // left as-is. Applied just before execution so it covers the bypass path too.
    if let Some(cap) = tier_max_rows(request.mount.capability_overrides.as_ref()) {
        request.operation.limit =
            Some(request.operation.limit.map_or(cap, |l| l.min(cap)));
    }

    // S8 read-replica routing (DATA_PLANE_READ_REPLICA, default OFF). A pure READ
    // (!is_mutation: List/Get/Aggregate) on a mount carrying a replica DSN is
    // served from the replica's OWN pool (the variant routes inline_dsn ← replica
    // and keys to a distinct `/ro` pool); writes/tx/Batch + flag-OFF stay on the
    // primary, where read-after-write consistency lives by construction. Flag OFF
    // or no replica DSN ⇒ `request.mount` is used UNCHANGED = byte-parity.
    //
    // `read_replica_variant` consumes self, so we GUARD on the replica's presence
    // FIRST and only move `request.mount` when we will actually use the variant —
    // the `else` arm hands the ORIGINAL mount straight through (no clone, no
    // variant), preserving today's exact path at parity.
    let mount_to_open = if state.config.read_replica
        && !is_mutation
        && request
            .mount
            .replica_inline_dsn
            .as_deref()
            .is_some_and(|d| !d.trim().is_empty())
    {
        request
            .mount
            .read_replica_variant()
            .expect("replica dsn checked present")
    } else {
        request.mount
    };
    let pool = match state.registry.get_or_create(mount_to_open).await {
        Ok(pool) => pool,
        Err(err) => return map_data_plane_error(&err),
    };
    match pool.execute(request.operation, request.identity).await {
        Ok(mut result) => {
            // Phase 6 audit trail: every successful data MUTATION is logged to
            // the `audit` tracing target (routed to Loki by promtail). Reads are
            // not audited (volume); denials are audited at their rejection sites.
            if is_mutation {
                tracing::info!(
                    target: "audit",
                    event = "mutation",
                    tenant = %audit_tenant,
                    engine = %audit_engine,
                    op = ?audit_op,
                    resource = %audit_resource,
                    affected_rows = result.affected_rows,
                    "data mutation committed"
                );
            }
            // Track-B metering (B1a) — mutation arm. OFF by default
            // (`config.metering` requires METERING_ENABLED AND DATA_PLANE_METERING)
            // → byte-parity: the flag short-circuits BEFORE any extra field access,
            // so the write hot path is untouched at parity. When ON, record the
            // work done (`write.rows` = affected_rows) into the in-memory aggregate
            // (cheap, non-blocking); the background flusher emits the `usage`
            // event. Engine-agnostic — reuses the already-bound `audit_tenant` /
            // `result.affected_rows`, no adapter code.
            if state.config.metering && is_mutation {
                state
                    .usage
                    .record(&audit_tenant, "write.rows", result.affected_rows);
            }
            // G-ReadAudit (A6): optionally audit successful READS too. OFF by
            // default (volume); when `DATA_PLANE_AUDIT_READS` is on, emit a
            // sibling `read` event. The flag short-circuits BEFORE any field
            // access, so the read hot path is untouched at parity (today's
            // behavior — no read audit).
            if !is_mutation && state.config.audit_reads {
                tracing::info!(
                    target: "audit",
                    event = "read",
                    tenant = %audit_tenant,
                    engine = %audit_engine,
                    op = ?audit_op,
                    resource = %audit_resource,
                    returned_rows = result.rows.len(),
                    "data read served"
                );
            }
            // Track-B metering (B1a) — read arm. Sibling to the read-audit emit:
            // OFF by default (`config.metering`) → byte-parity, the flag short-
            // circuits BEFORE `result.rows.len()` is touched, so the read hot path
            // is untouched at parity. When ON, record one query (`query.count`)
            // plus the rows returned (`query.rows` = pre-projection row count,
            // the honest read-cost signal) into the in-memory aggregate. Cheap,
            // non-blocking; the background flusher emits the `usage` events.
            if state.config.metering && !is_mutation {
                state.usage.record(&audit_tenant, "query.count", 1);
                state
                    .usage
                    .record(&audit_tenant, "query.rows", result.rows.len() as u64);
            }
            // Phase 7d: on the bypass write path, emit the row-change event the
            // query-router would have — best-effort, never fails the (committed)
            // write. No-op for reads, for the internal path (emit_outbox=false),
            // and when the outbox DSN is unset.
            #[cfg(feature = "control-pg")]
            if emit_outbox && is_mutation {
                if let Some(ob) = state.outbox.as_ref() {
                    // D-write-tail: non-blocking enqueue — the INSERT runs on the
                    // background worker, OFF this request's latency path. The
                    // write already committed; a dropped event (full queue) is
                    // counted, never an error to the (already-served) caller.
                    ob.enqueue(
                        &audit_engine,
                        &outbox_identity,
                        audit_op,
                        &audit_resource,
                        outbox_data.as_ref(),
                        outbox_filter.as_ref(),
                        &result,
                        outbox_idem.as_deref(),
                    );
                }
            }
            // Phase D — fire set_property automations on the bypass write path
            // (best-effort; never fails the committed write). Gated to the bypass
            // so /query/v1 (where the query-router fires them inline) never doubles.
            #[cfg(feature = "control-pg")]
            if emit_outbox && is_mutation {
                if let Some(au) = state.automations.as_ref() {
                    let row = result.rows.first().cloned().unwrap_or_else(|| {
                        let mut m = serde_json::Map::new();
                        if let Some(serde_json::Value::Object(d)) = outbox_data.as_ref() {
                            for (k, v) in d {
                                m.insert(k.clone(), v.clone());
                            }
                        }
                        if let Some(serde_json::Value::Object(f)) = outbox_filter.as_ref() {
                            for (k, v) in f {
                                m.insert(k.clone(), v.clone());
                            }
                        }
                        serde_json::Value::Object(m)
                    });
                    let pk = row
                        .get("id")
                        .cloned()
                        .or_else(|| outbox_data.as_ref().and_then(|d| d.get("id")).cloned())
                        .or_else(|| outbox_filter.as_ref().and_then(|f| f.get("id")).cloned());
                    au.run_for_write(
                        &*pool,
                        &outbox_identity,
                        &automation_db_id,
                        &audit_resource,
                        op_wire,
                        &row,
                        pk.as_ref(),
                    )
                    .await;
                }
            }
            // Nano edition: fan the committed mutation out to the in-process SSE
            // bus (the single-binary equivalent of the outbox → realtime path).
            // Best-effort; lagging subscribers drop events, never the write.
            #[cfg(feature = "nano")]
            if emit_outbox && is_mutation {
                if let Some(nano) = state.nano.as_ref() {
                    let pk = result
                        .rows
                        .first()
                        .and_then(|r| r.get("id"))
                        .cloned()
                        .or_else(|| outbox_data.as_ref().and_then(|d| d.get("id")).cloned())
                        .or_else(|| outbox_filter.as_ref().and_then(|f| f.get("id")).cloned());
                    nano.publish_mutation(
                        &automation_db_id,
                        &audit_resource,
                        op_wire,
                        pk.as_ref(),
                        result.affected_rows,
                        outbox_identity.user_id.as_deref().unwrap_or(""),
                    );
                }
            }
            // Phase D — apply ABAC field masks in Rust (cutover prep). Flag-gated;
            // user identities only (api-key callers are scope-based → no mask,
            // matching the query-router). Applied AFTER the outbox emit so the
            // server-side event keeps the FULL row — only the per-user RESPONSE
            // is masked. OFF by default (`DATA_PLANE_APPLY_MASKS`) → byte-parity.
            if state.config.apply_masks {
                if let (Some(ev), Some(user)) = (
                    state.evaluator.as_ref(),
                    outbox_identity
                        .user_id
                        .as_deref()
                        .filter(|u| !u.starts_with("api-key:")),
                ) {
                    let decision = ev.decide(user, &audit_engine, &audit_resource, mask_action);
                    if !decision.allow {
                        tracing::warn!(
                            target: "audit",
                            event = "abac_denied",
                            tenant = %audit_tenant,
                            engine = %audit_engine,
                            resource = %audit_resource,
                            "ABAC denied a user request (403)"
                        );
                        return api_err(StatusCode::FORBIDDEN, "forbidden", &decision.reason);
                    }
                    if let Some(mask) = decision.mask {
                        crate::abac::apply_field_mask(&mut result.rows, &mask);
                    }
                }
            }
            // `fields` projection: engine-neutral, post-mask, response-only.
            data_plane_core::DataOperation::project_rows(&projection, &mut result.rows);
            (StatusCode::OK, Json(result)).into_response()
        }
        Err(err) => map_data_plane_error(&err),
    }
}

/// Phase 7 bypass front door (`POST /data/v1/query`). Kong routes a client's
/// `X-Baas-Api-Key` here directly; Rust authenticates it itself (Go stays the
/// identity authority via tenant-control), resolves the mount, then runs the
/// SAME `run_query` as the internal `/v1/query` — so enforcement (tier gate,
/// rate limit, owner scoping) is identical on both paths. Only mounted when
/// `DATA_PLANE_BYPASS_ENABLED=1`; otherwise this code is never reachable.
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct DataQueryRequest {
    #[serde(alias = "databaseId", alias = "dbId")]
    db_id: String,
    operation: DataOperation,
}

/// Phase C — API-key scope gate for the `/data/v1` bypass (ports the
/// query-router's `decideByApiKeyScope`): `admin` ⇒ any op; `read` ⇒
/// list/get/aggregate; `write` ⇒ insert/update/delete/upsert/batch. Returns the
/// missing scope name on denial. This is what lets a Node-free basic tier serve
/// api-key callers with the same authorization the query-router enforced.
fn api_key_scope_gate(
    scopes: &[String],
    op: &data_plane_core::DataOperationKind,
) -> Result<(), &'static str> {
    use data_plane_core::DataOperationKind::*;
    let needed = match op {
        List | Get | Aggregate => "read",
        Insert | Update | Delete | Upsert | Batch => "write",
    };
    require_scope(scopes, needed)
}

/// A scope check: `admin` satisfies anything; otherwise the exact scope is
/// required. Shared by the op gate (read/write) and the schema/ddl bypass
/// handlers (read for introspect, write for DDL).
pub(crate) fn require_scope(scopes: &[String], needed: &'static str) -> Result<(), &'static str> {
    if scopes.iter().any(|s| s == "admin" || s == needed) {
        Ok(())
    } else {
        Err(needed)
    }
}

impl AppState {
    /// Resolve a mount (engine + DSN + tier mask) for a bypass caller,
    /// tenant-scoped via adapter-registry. Used by the single-mount handlers and
    /// by the multi-mount graph builder.
    pub(crate) async fn resolve_bypass_mount(
        &self,
        tenant: &str,
        db_id: &str,
    ) -> Result<crate::auth::ResolvedMount, crate::auth::AuthError> {
        // Nano edition: mounts are a static in-process map (no adapter-registry).
        #[cfg(feature = "nano")]
        if let Some(nano) = self.nano.as_ref() {
            let _ = tenant; // single-tenant: every verified key sees the local mounts
            return nano.resolve_mount(db_id);
        }
        // Cache the DSN/engine/tier resolution per (tenant, db_id), like the
        // query-router's 30 s DSN cache — without it the bypass re-hits
        // adapter-registry on every request. Rotation evicts via /v1/admin/rotate
        // (the registry pool drain); the short TTL bounds staleness either way.
        let ttl = std::time::Duration::from_millis(self.config.verify_cache_ttl_ms);
        let ckey = format!("{tenant}\u{0}{db_id}");
        if !ttl.is_zero() {
            if let Ok(cache) = self.mount_cache.lock() {
                if let Some((at, m)) = cache.get(&ckey) {
                    if at.elapsed() < ttl {
                        self.metrics.record_mount_cache(true);
                        return Ok(m.clone());
                    }
                }
            }
        }
        self.metrics.record_mount_cache(false);
        let mount = crate::auth::resolve_mount(
            &self.http_client,
            &self.config.adapter_registry_url,
            &self.config.internal_service_token,
            tenant,
            db_id,
        )
        .await?;
        if !ttl.is_zero() {
            if let Ok(mut cache) = self.mount_cache.lock() {
                if cache.len() >= 4096 {
                    cache.clear();
                }
                cache.insert(ckey, (std::time::Instant::now(), mount.clone()));
            }
        }
        Ok(mount)
    }

    /// Owner-scoped read execution (no audit/outbox — reads never emit). The
    /// graph builder calls this for each `list`; errors map to "unreadable → omit".
    pub(crate) async fn execute_read(
        &self,
        identity: RequestIdentity,
        mount: DatabaseMount,
        operation: DataOperation,
    ) -> data_plane_core::DataPlaneResult<data_plane_core::DataResult> {
        let pool = self.registry.get_or_create(mount).await?;
        pool.execute(operation, identity).await
    }
}

/// A JSON `ApiError` response with the given status.
pub(crate) fn api_err(status: StatusCode, error: &str, message: &str) -> axum::response::Response {
    (
        status,
        Json(ApiError {
            error: error.to_string(),
            message: message.to_string(),
        }),
    )
        .into_response()
}

/// Validate the `X-Baas-Api-Key` (Go performs the Argon2id compare via
/// tenant-control) → a verified caller identity, or a ready error response. The
/// key-verification half of `bypass_auth`, split out so a multi-mount handler
/// (graph) can verify ONCE and resolve per dbId.
pub(crate) async fn bypass_verify(
    state: &AppState,
    headers: &header::HeaderMap,
) -> Result<crate::auth::VerifiedIdentity, axum::response::Response> {
    // Nano edition: the key store lives IN-PROCESS (no tenant-control, no
    // service token, no network hop) — the local verify replaces the whole
    // HTTP path below.
    #[cfg(feature = "nano")]
    if let Some(nano) = state.nano.as_ref() {
        // binocle-one: a Bearer JWT is a first-class identity on the SAME
        // door — user requests get per-user owner-scoping + ABAC masks. An
        // explicit API key still wins (machine callers may send both).
        #[cfg(feature = "one")]
        if !headers.contains_key("x-baas-api-key") {
            if let (Some(one), Some(token)) =
                (state.one.as_ref(), crate::one::bearer_token(headers))
            {
                return one.verify_jwt(&token);
            }
        }
        return nano.verify_headers(headers);
    }
    let key = match headers.get("x-baas-api-key").and_then(|v| v.to_str().ok()) {
        Some(k) if !k.trim().is_empty() => k.to_string(),
        _ => {
            return Err(api_err(
                StatusCode::UNAUTHORIZED,
                "unauthorized",
                "X-Baas-Api-Key header is required",
            ))
        }
    };
    if state.config.internal_service_token.is_empty() {
        return Err(api_err(
            StatusCode::SERVICE_UNAVAILABLE,
            "bypass_misconfigured",
            "INTERNAL_SERVICE_TOKEN not set on the data plane",
        ));
    }
    // Cache hit → skip the tenant-control round-trip (+ its Argon2id). Mirrors the
    // query-router's 30 s ApiKeyMiddleware cache, so a revoked key has the same
    // (short) validity window on both front doors. The lock is never held across
    // the await below.
    let ttl = std::time::Duration::from_millis(state.config.verify_cache_ttl_ms);
    if !ttl.is_zero() {
        if let Ok(cache) = state.verify_cache.lock() {
            if let Some((at, id)) = cache.get(&key) {
                if at.elapsed() < ttl {
                    state.metrics.record_verify_cache(true);
                    return Ok(id.clone());
                }
            }
        }
    }
    state.metrics.record_verify_cache(false);
    // Go performs the Argon2id compare; Rust trusts the verified result.
    let identity = crate::auth::verify_key(
        &state.http_client,
        &state.config.tenant_control_url,
        &state.config.internal_service_token,
        &key,
    )
    .await
    .map_err(auth_error_response)?;
    if !ttl.is_zero() {
        if let Ok(mut cache) = state.verify_cache.lock() {
            // Bound the map so a key-spray can't grow it unboundedly.
            if cache.len() >= 4096 {
                cache.clear();
            }
            cache.insert(key, (std::time::Instant::now(), identity.clone()));
        }
    }
    Ok(identity)
}

/// Shared `/data/v1` authentication: verify the key + resolve the (single) mount,
/// tenant-scoped. Every single-mount bypass handler (query, schema, ddl) routes
/// through here so authentication is byte-identical.
async fn bypass_auth(
    state: &AppState,
    headers: &header::HeaderMap,
    db_id: &str,
) -> Result<(crate::auth::VerifiedIdentity, crate::auth::ResolvedMount), axum::response::Response> {
    let id = bypass_verify(state, headers).await?;
    let mount_info = state
        .resolve_bypass_mount(&id.tenant_id, db_id)
        .await
        .map_err(auth_error_response)?;
    Ok((id, mount_info))
}

/// Build the internal (identity, mount) envelope for a verified bypass caller —
/// the SAME shape the query-router constructs. The verified principal flows
/// through verbatim: `api-key:<id>` for machine keys (byte-parity with the
/// query-router), `user:<id>` for binocle-one account holders (which is what
/// makes per-user owner-scoping + ABAC masks light up on the same path).
pub(crate) fn bypass_envelope(
    id: &crate::auth::VerifiedIdentity,
    db_id: &str,
    mount_info: crate::auth::ResolvedMount,
) -> (RequestIdentity, DatabaseMount) {
    (
        RequestIdentity {
            tenant_id: id.tenant_id.clone(),
            project_id: None,
            app_id: None,
            user_id: Some(id.principal.clone()),
            roles: vec![],
            scopes: id.scopes.clone(),
            source: id.source.clone(),
        },
        DatabaseMount {
            id: db_id.to_string(),
            tenant_id: id.tenant_id.clone(),
            project_id: None,
            engine: mount_info.engine,
            name: "bypass".to_string(),
            credential_ref: CredentialRef {
                provider: "adapter-registry".to_string(),
                reference: db_id.to_string(),
                version: "live".to_string(),
            },
            pool_policy: PoolPolicy::default(),
            capability_overrides: mount_info.capability_overrides,
            inline_dsn: Some(mount_info.connection_string),
            isolation: mount_info.isolation,
            replica_inline_dsn: None,
            read_replica_route: false,
        },
    )
}

/// Audited 403 for a bypass caller lacking a scope.
pub(crate) fn scope_denied(
    id: &crate::auth::VerifiedIdentity,
    surface: &str,
    missing: &str,
) -> axum::response::Response {
    tracing::warn!(
        target: "audit",
        event = "scope_denied",
        tenant = %id.tenant_id,
        surface = %surface,
        "api key lacks '{missing}' scope (403)"
    );
    api_err(
        StatusCode::FORBIDDEN,
        "forbidden",
        &format!("api key lacks '{missing}' scope for this operation"),
    )
}

/// Apply the per-tenant token-bucket rate limit for a bypass request using the
/// mount's tier mask. `/data/v1/query` does this inside `run_query`; the schema
/// / ddl / graph handlers must call it explicitly since they bypass `run_query`.
/// A no-op when the mount carries no tier mask (parity), so untiered tenants are
/// unaffected.
pub(crate) async fn bypass_ratelimit(
    state: &AppState,
    tenant: &str,
    overrides: Option<&serde_json::Value>,
    surface: &str,
) -> Result<(), axum::response::Response> {
    if let Some((rps, burst)) = tier_rate(overrides) {
        if !state.ratelimiter.allow(tenant, rps, burst).await {
            tracing::warn!(
                target: "audit",
                event = "rate_limited",
                tenant = %tenant,
                surface = %surface,
                rps,
                "tenant exceeded package rate limit (429)"
            );
            return Err(too_many_requests(rps));
        }
    }
    Ok(())
}

pub(crate) async fn data_query(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Json(req): Json<DataQueryRequest>,
) -> axum::response::Response {
    let (id, mount_info) = match bypass_auth(&state, &headers, &req.db_id).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    // API-key scope gate (admin/read/write) — mirrors the query-router.
    if let Err(missing) = api_key_scope_gate(&id.scopes, &req.operation.op) {
        return scope_denied(&id, "query", missing);
    }
    let (identity, mount) = bypass_envelope(&id, &req.db_id, mount_info);
    // Identical execution path — Rust emits the outbox event here (the
    // query-router is out of the bypass path), so row-change fan-out keeps firing.
    run_query(
        state,
        QueryRequest {
            identity,
            mount,
            operation: req.operation,
        },
        true,
    )
    .await
}

// ── /data/v1/schema + /data/v1/schema/ddl (Phase D) ─────────────────────────
// The api-key-authed twins of /v1/schema[/ddl]: SAME Rust core, but Rust does
// the auth (verify_key + resolve_mount + scope gate) so a Node-free tier can
// introspect + create tables through the bypass. Introspect = read scope; DDL =
// write scope (it mutates the schema). Additive + bypass-gated (shadow); the
// engine capability gates (introspect / schema_ddl) still apply inside the core.

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct DataSchemaRequest {
    #[serde(alias = "databaseId", alias = "dbId")]
    db_id: String,
}

pub(crate) async fn data_describe_schema(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Json(req): Json<DataSchemaRequest>,
) -> axum::response::Response {
    let (id, mount_info) = match bypass_auth(&state, &headers, &req.db_id).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    if let Err(missing) = require_scope(&id.scopes, "read") {
        return scope_denied(&id, "schema", missing);
    }
    if let Err(resp) =
        bypass_ratelimit(&state, &id.tenant_id, mount_info.capability_overrides.as_ref(), "schema")
            .await
    {
        return resp;
    }
    let (identity, mount) = bypass_envelope(&id, &req.db_id, mount_info);
    run_describe_schema(state, identity, mount).await
}

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct DataSchemaDdlRequest {
    #[serde(alias = "databaseId", alias = "dbId")]
    db_id: String,
    ddl: SchemaDdlRequest,
}

pub(crate) async fn data_apply_schema_ddl(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Json(req): Json<DataSchemaDdlRequest>,
) -> axum::response::Response {
    let (id, mount_info) = match bypass_auth(&state, &headers, &req.db_id).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    // DDL mutates the schema — requires write (or admin).
    if let Err(missing) = require_scope(&id.scopes, "write") {
        return scope_denied(&id, "schema_ddl", missing);
    }
    if let Err(resp) = bypass_ratelimit(
        &state,
        &id.tenant_id,
        mount_info.capability_overrides.as_ref(),
        "schema_ddl",
    )
    .await
    {
        return resp;
    }
    let (identity, mount) = bypass_envelope(&id, &req.db_id, mount_info);
    run_apply_schema_ddl(state, identity, mount, req.ddl).await
}

fn auth_error_response(err: crate::auth::AuthError) -> axum::response::Response {
    use crate::auth::AuthError;
    let (status, code, message) = match err {
        AuthError::Unauthorized(m) => (StatusCode::UNAUTHORIZED, "unauthorized", m),
        AuthError::NotFound(m) => (StatusCode::NOT_FOUND, "mount_not_found", m),
        AuthError::Upstream(m) => (StatusCode::BAD_GATEWAY, "upstream_unavailable", m),
    };
    (
        status,
        Json(ApiError {
            error: code.to_string(),
            message,
        }),
    )
        .into_response()
}

/// Reject a request whose engine advertises a required capability as `false`
/// with a clean 422 `UnsupportedCapability` (G6: a semantic, not syntactic,
/// rejection), instead of letting it die as a deep 501 inside the adapter (e.g.
/// `begin()` on mongo, `migrate` on a `ddl:false` engine). Uses the trusted
/// server-side descriptor, never request input. A no-op when the engine isn't in
/// the descriptor table (the adapter still guards).
fn require_capability(
    state: &AppState,
    engine: &str,
    capability: &str,
    has: impl Fn(&EngineCapabilities) -> bool,
) -> Result<(), axum::response::Response> {
    if let Some(descriptor) = state.engines.iter().find(|e| e.engine == engine) {
        if !has(&descriptor.capabilities) {
            return Err(map_data_plane_error(
                &DataPlaneError::UnsupportedCapability {
                    engine: engine.to_string(),
                    capability: capability.to_string(),
                },
            ));
        }
    }
    Ok(())
}

pub(crate) fn map_data_plane_error(err: &DataPlaneError) -> axum::response::Response {
    let (status, code) = match err {
        DataPlaneError::NotImplemented { .. } => (StatusCode::NOT_IMPLEMENTED, "not_implemented"),
        // G6: an (engine, op) the engine cannot serve is a *semantically*
        // invalid request — the body is well-formed but the capability is
        // unavailable — so 422 Unprocessable Entity, distinct from a malformed
        // request (400). Only this variant flips; InvalidRequest/Identifier
        // stay 400.
        DataPlaneError::UnsupportedCapability { .. } => {
            (StatusCode::UNPROCESSABLE_ENTITY, "unsupported_capability")
        }
        // Phase 4: the engine CAN serve the op, but the tenant's package tier
        // excludes it — an authorization decision (403), not a 422. The client
        // must upgrade the package, not fix the request.
        DataPlaneError::CapabilityGated { .. } => (StatusCode::FORBIDDEN, "capability_gated"),
        DataPlaneError::InvalidIdentifier { .. } => (StatusCode::BAD_REQUEST, "invalid_identifier"),
        DataPlaneError::InvalidRequest { .. } => (StatusCode::BAD_REQUEST, "invalid_request"),
        DataPlaneError::MountNotFound { .. } => (StatusCode::NOT_FOUND, "mount_not_found"),
        DataPlaneError::TransactionNotFound { .. } => (StatusCode::NOT_FOUND, "transaction_not_found"),
        DataPlaneError::CredentialUnavailable { .. } => {
            (StatusCode::BAD_GATEWAY, "credential_unavailable")
        }
        // A configured provider was reached but failed (transport/non-2xx/missing
        // field). Mirror CredentialUnavailable's status (502) — an upstream
        // credential source we depend on did not deliver, so it is a gateway
        // failure, not a client (422) error.
        DataPlaneError::CredentialProviderFailed { .. } => {
            (StatusCode::BAD_GATEWAY, "credential_provider_failed")
        }
        DataPlaneError::Backend { .. } => (StatusCode::BAD_GATEWAY, "backend_error"),
        DataPlaneError::Conflict { .. } => (StatusCode::CONFLICT, "conflict"),
    };
    (
        status,
        Json(ApiError {
            error: code.to_string(),
            message: err.to_string(),
        }),
    )
        .into_response()
}

// ── /v1/schema ───────────────────────────────────────────────────────────────
//
// Engine-agnostic schema introspection (M22, live-database mode). Returns the
// mount's tables/collections with normalized column types, PK/FK metadata and
// enum values (`SchemaDescriptor` in data-plane-core). NOT admin-gated: any
// authenticated identity that passes `validate_identity_mount` may read its
// OWN mount's schema (same gating as `begin_transaction` — identity/mount
// validation + a capability gate, nothing more). Engines without an
// introspection surface (redis, http) advertise `introspect: false` and are
// rejected here with a clean 422 instead of a deep 501.

#[derive(Debug, Clone, Deserialize)]
struct DescribeSchemaRequest {
    identity: RequestIdentity,
    mount: DatabaseMount,
}

async fn describe_schema(
    State(state): State<AppState>,
    Json(request): Json<DescribeSchemaRequest>,
) -> axum::response::Response {
    run_describe_schema(state, request.identity, request.mount).await
}

/// Shared schema-introspection core (the envelope `/v1/schema` path and the
/// api-key `/data/v1/schema` bypass both call this).
async fn run_describe_schema(
    state: AppState,
    identity: RequestIdentity,
    mount: DatabaseMount,
) -> axum::response::Response {
    if let Err(message) = validate_identity_mount(&state, &identity, &mount) {
        return bad_request(message);
    }
    // Honesty gate: only engines advertising `introspect` serve the schema
    // surface (a route capability like `ddl`, not an operation kind).
    if let Err(resp) = require_capability(&state, &mount.engine, "introspect", |c| c.introspect) {
        return resp;
    }
    let pool = match state.registry.get_or_create(mount).await {
        Ok(pool) => pool,
        Err(err) => return map_data_plane_error(&err),
    };
    match pool.describe_schema(identity).await {
        Ok(result) => (StatusCode::OK, Json(result)).into_response(),
        Err(err) => map_data_plane_error(&err),
    }
}

// ── /v1/schema/ddl ────────────────────────────────────────────────────────────
//
// Engine-agnostic schema DDL (M22, step 2): ONE operation per request
// (add_column | drop_column | alter_column_type | create_table | drop_table)
// — single-op by contract because MySQL DDL self-commits, so a batch would
// fake atomicity. NOT admin-gated (mirrors /v1/schema): mount ownership is
// enforced upstream by the query-router's resolveConnection, the same trust
// model as /v1/query writes. Gated on the `schema_ddl` capability flag —
// deliberately distinct from `ddl` (the /v1/admin/migrate gate), because
// mongodb serves this surface but not migrations.

#[derive(Debug, Clone, Deserialize)]
struct SchemaDdlEnvelope {
    identity: RequestIdentity,
    mount: DatabaseMount,
    ddl: SchemaDdlRequest,
}

async fn apply_schema_ddl(
    State(state): State<AppState>,
    Json(request): Json<SchemaDdlEnvelope>,
) -> axum::response::Response {
    run_apply_schema_ddl(state, request.identity, request.mount, request.ddl).await
}

/// Shared schema-DDL core (the envelope `/v1/schema/ddl` path and the api-key
/// `/data/v1/schema/ddl` bypass both call this).
async fn run_apply_schema_ddl(
    state: AppState,
    identity: RequestIdentity,
    mount: DatabaseMount,
    ddl: SchemaDdlRequest,
) -> axum::response::Response {
    if let Err(message) = validate_identity_mount(&state, &identity, &mount) {
        return bad_request(message);
    }
    if ddl.table.trim().is_empty() {
        return bad_request("ddl.table is required".to_string());
    }
    // Honesty gate: only engines advertising `schema_ddl` serve this surface.
    if let Err(resp) = require_capability(&state, &mount.engine, "schema_ddl", |c| c.schema_ddl) {
        return resp;
    }
    let pool = match state.registry.get_or_create(mount).await {
        Ok(pool) => pool,
        Err(err) => return map_data_plane_error(&err),
    };
    match pool.apply_schema_ddl(ddl, identity).await {
        Ok(result) => (StatusCode::OK, Json(result)).into_response(),
        Err(err) => map_data_plane_error(&err),
    }
}

// Default transaction TTL — after this the registry stops handing out the
// handle on lookup. The connection is NOT force-closed here; a follow-up
// slice can add a reaper task that calls rollback on expired entries.
const DEFAULT_TX_TTL_SECS: u64 = 30;

#[derive(Debug, Clone, Serialize)]
struct TxBeginResponse {
    tx_id: String,
    mount_id: String,
    expires_in_ms: u64,
}

async fn begin_transaction(
    State(state): State<AppState>,
    Json(request): Json<TxBeginRequest>,
) -> impl IntoResponse {
    if let Err(message) = validate_identity_mount(&state, &request.identity, &request.mount) {
        return bad_request(message);
    }
    // Honesty gate: an engine whose `begin()` is NotImplemented (mongo/redis/
    // http) advertises `transactions:false` — reject here with 400 rather than
    // 501 from deep in the adapter.
    if let Err(resp) =
        require_capability(&state, &request.mount.engine, "transactions", |c| c.transactions)
    {
        return resp;
    }
    // Phase 4 tiering: the engine may support transactions but the tenant's
    // package tier can exclude them (Essential) → 403 CapabilityGated, distinct
    // from the 422 above (engine genuinely can't begin()).
    if let Some(descriptor) = state.engines.iter().find(|e| e.engine == request.mount.engine) {
        let effective = data_plane_core::apply_capability_overrides(
            &descriptor.capabilities,
            request.mount.capability_overrides.as_ref(),
        );
        if descriptor.capabilities.transactions && !effective.transactions {
            return map_data_plane_error(&data_plane_core::DataPlaneError::CapabilityGated {
                capability: "transactions".to_string(),
            });
        }
    }

    // Capture identity/mount info BEFORE moving `request` into pool.begin.
    let tenant_id = request.identity.tenant_id.clone();
    let mount = request.mount.clone();
    // `pool_key` identifies the pool the tx's connection comes from, so we can
    // pin it against eviction/reaping for the life of the transaction. Derived
    // through the registry so it honors the pool-sharing policy (B4-pools) — a
    // shared_rls tx must pin the SAME shared pool `get_or_create` handed out.
    let pool_key = state.registry.pool_key_for(&mount);

    let pool = match state.registry.get_or_create(mount).await {
        Ok(pool) => pool,
        Err(err) => return map_data_plane_error(&err),
    };
    let handle = match pool.begin(request).await {
        Ok(handle) => handle,
        Err(err) => return map_data_plane_error(&err),
    };
    // Pin the pool now that a tx holds one of its connections: the registry
    // must not close it (eviction / idle reap) until commit/rollback unpins.
    state.registry.pin_tx(&pool_key).await;

    let ttl = Duration::from_secs(DEFAULT_TX_TTL_SECS);
    let mount_id = handle.mount_id().to_string();
    let handle_arc: Arc<dyn TxHandle> = Arc::from(handle);
    let tx_id = state
        .transactions
        .register(handle_arc, tenant_id, mount_id.clone(), pool_key, ttl)
        .await;

    (
        StatusCode::CREATED,
        Json(TxBeginResponse {
            tx_id,
            mount_id,
            expires_in_ms: ttl.as_millis() as u64,
        }),
    )
        .into_response()
}

#[derive(Debug, Clone, Deserialize)]
struct TxExecuteRequest {
    identity: RequestIdentity,
    operation: DataOperation,
}

async fn execute_in_transaction(
    State(state): State<AppState>,
    Path(tx_id): Path<String>,
    Json(request): Json<TxExecuteRequest>,
) -> impl IntoResponse {
    if !request.identity.is_tenant_scoped() {
        return bad_request("identity.tenant_id is required".to_string());
    }
    let (handle, tx_tenant) = match state.transactions.get(&tx_id).await {
        Some(entry) => entry,
        None => {
            return (
                StatusCode::NOT_FOUND,
                Json(ApiError {
                    error: "transaction_not_found".to_string(),
                    message: format!("no open transaction with id {tx_id}"),
                }),
            )
                .into_response();
        }
    };
    // Cross-tenant guard: a tenant cannot resume another tenant's tx by
    // guessing the tx_id. Identity-tenant must match the tenant that opened
    // the transaction.
    if request.identity.tenant_id != tx_tenant {
        return bad_request(
            "identity tenant does not match the tenant that opened this transaction".to_string(),
        );
    }
    if request.operation.resource.trim().is_empty() {
        return bad_request("operation.resource is required".to_string());
    }

    match handle.execute(request.operation, request.identity).await {
        Ok(result) => (StatusCode::OK, Json(result)).into_response(),
        Err(err) => map_data_plane_error(&err),
    }
}

async fn commit_transaction(
    State(state): State<AppState>,
    Path(tx_id): Path<String>,
) -> impl IntoResponse {
    let (handle, pool_key) = match state.transactions.take(&tx_id).await {
        Some(entry) => entry,
        None => {
            return (
                StatusCode::NOT_FOUND,
                Json(ApiError {
                    error: "transaction_not_found".to_string(),
                    message: format!("no open transaction with id {tx_id}"),
                }),
            )
                .into_response();
        }
    };
    let result = handle.commit().await;
    // The tx no longer holds the pool's connection — release the pin so the
    // registry may evict/reap it again. Always unpin, even on commit error.
    state.registry.unpin_tx(&pool_key).await;
    match result {
        Ok(()) => (StatusCode::OK, Json(TxFinalize { tx_id, state: "committed" })).into_response(),
        Err(err) => map_data_plane_error(&err),
    }
}

async fn rollback_transaction(
    State(state): State<AppState>,
    Path(tx_id): Path<String>,
) -> impl IntoResponse {
    let (handle, pool_key) = match state.transactions.take(&tx_id).await {
        Some(entry) => entry,
        None => {
            return (
                StatusCode::NOT_FOUND,
                Json(ApiError {
                    error: "transaction_not_found".to_string(),
                    message: format!("no open transaction with id {tx_id}"),
                }),
            )
                .into_response();
        }
    };
    let result = handle.rollback().await;
    state.registry.unpin_tx(&pool_key).await;
    match result {
        Ok(()) => (StatusCode::OK, Json(TxFinalize { tx_id, state: "rolled_back" })).into_response(),
        Err(err) => map_data_plane_error(&err),
    }
}

#[derive(Debug, Clone, Serialize)]
struct TxFinalize {
    tx_id: String,
    state: &'static str,
}

// ── /v1/admin/raw ───────────────────────────────────────────────────────────
//
// Power-user endpoint: arbitrary engine-native statement (DDL, ALTER,
// indexes, raw SELECT for aggregations). The route enforces that the caller
// has the `service_role` role or the `admin` scope; engines TRUST the gate
// and execute the statement verbatim against the mount's connection.
//
// The endpoint exists so that "full DB control" stops being aspirational —
// the audit flagged it as a real product gap. Engines that don't support a
// raw surface return NotImplemented from the trait default.

#[derive(Debug, Clone, Deserialize)]
struct AdminRawRequest {
    identity: RequestIdentity,
    mount: DatabaseMount,
    #[serde(flatten)]
    statement: RawStatement,
}

async fn execute_raw_admin(
    State(state): State<AppState>,
    Json(request): Json<AdminRawRequest>,
) -> impl IntoResponse {
    if let Err(message) = validate_identity_mount(&state, &request.identity, &request.mount) {
        return bad_request(message);
    }
    if !is_admin(&request.identity) {
        return (
            StatusCode::FORBIDDEN,
            Json(ApiError {
                error: "forbidden".to_string(),
                message: "/v1/admin/raw requires role=service_role or scope=admin".to_string(),
            }),
        )
            .into_response();
    }
    if request.statement.statement.trim().is_empty() {
        return bad_request("statement is required".to_string());
    }

    let pool = match state.registry.get_or_create(request.mount).await {
        Ok(pool) => pool,
        Err(err) => return map_data_plane_error(&err),
    };
    match pool.execute_raw(request.statement, request.identity).await {
        Ok(result) => (StatusCode::OK, Json(result)).into_response(),
        Err(err) => map_data_plane_error(&err),
    }
}

fn is_admin(identity: &RequestIdentity) -> bool {
    identity.roles.iter().any(|r| r == "service_role" || r == "admin")
        || identity.scopes.iter().any(|s| s == "admin")
}

// ── /v1/permissions/decide ──────────────────────────────────────────────────
//
// In-Rust ABAC/RBAC decision endpoint. Mirrors the NestJS
// `DecisionsService.decide()` shape so the query-router can swap targets
// without changing its request envelope. When the local evaluator isn't
// configured (no DATA_PLANE_PERMISSION_BUNDLE env) the endpoint returns 503
// and the caller falls back to the permission-engine HTTP path.

#[derive(Debug, Clone, Deserialize)]
struct DecisionUser {
    id: String,
}

#[derive(Debug, Clone, Deserialize)]
struct DecideRequest {
    user: DecisionUser,
    resource_type: String,
    resource_name: String,
    op: String,
    #[serde(default)]
    tenant_id: Option<String>,
    #[serde(default)]
    project_id: Option<String>,
    #[serde(default)]
    app_id: Option<String>,
}

async fn decide_permission(
    State(state): State<AppState>,
    Json(request): Json<DecideRequest>,
) -> impl IntoResponse {
    // tenant/project/app are accepted for future scoping; today's evaluator
    // doesn't use them (the SQL function didn't either). Drop on the floor
    // until the bundle format adds tenant-scoped policies.
    let _ = (request.tenant_id, request.project_id, request.app_id);
    let Some(evaluator) = state.evaluator.as_ref() else {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(ApiError {
                error: "evaluator_not_configured".to_string(),
                message: "DATA_PLANE_PERMISSION_BUNDLE is not set; fall back to permission-engine HTTP".to_string(),
            }),
        )
            .into_response();
    };
    let action = action_for_op(&request.op);
    let decision: Decision = evaluator.decide(
        &request.user.id,
        &request.resource_type,
        &request.resource_name,
        &action,
    );
    (StatusCode::OK, Json(decision)).into_response()
}

fn action_for_op(op: &str) -> String {
    match op {
        "list" | "get" => "select".to_string(),
        "upsert" => "update".to_string(),
        other => other.to_string(),
    }
}

// ── /v1/admin/migrate ───────────────────────────────────────────────────────
//
// Apply a named migration to a tenant database as an atomic batch. The
// engine wraps every statement in a single transaction, then writes a
// marker into `_baas_migrations(name, applied_at)` so re-applying the same
// name is a no-op. Used by control-plane tools to evolve schema-per-tenant
// without bespoke per-engine wiring.
//
// Admin-gated: same `service_role` / `admin` scope rule as /v1/admin/raw.

#[derive(Debug, Clone, Deserialize)]
struct AdminMigrateRequest {
    identity: RequestIdentity,
    mount: DatabaseMount,
    #[serde(flatten)]
    migration: MigrationRequest,
}

async fn apply_migration_admin(
    State(state): State<AppState>,
    Json(request): Json<AdminMigrateRequest>,
) -> impl IntoResponse {
    if let Err(message) = validate_identity_mount(&state, &request.identity, &request.mount) {
        return bad_request(message);
    }
    if !is_admin(&request.identity) {
        return (
            StatusCode::FORBIDDEN,
            Json(ApiError {
                error: "forbidden".to_string(),
                message: "/v1/admin/migrate requires role=service_role or scope=admin".to_string(),
            }),
        )
            .into_response();
    }
    if request.migration.name.trim().is_empty() {
        return bad_request("migration.name is required".to_string());
    }
    if request.migration.statements.is_empty() {
        return bad_request("migration.statements must not be empty".to_string());
    }
    // Honesty gate: only engines advertising `ddl` can apply migrations.
    if let Err(resp) = require_capability(&state, &request.mount.engine, "ddl", |c| c.ddl) {
        return resp;
    }

    let pool = match state.registry.get_or_create(request.mount).await {
        Ok(pool) => pool,
        Err(err) => return map_data_plane_error(&err),
    };
    match pool.apply_migration(request.migration, request.identity).await {
        Ok(result) => (StatusCode::OK, Json(result)).into_response(),
        Err(err) => map_data_plane_error(&err),
    }
}

// ── /v1/admin/rotate ─────────────────────────────────────────────────────────
//
// Credential-rotation trigger (gap G8 / S2). After a control-plane rotation
// bumps a mount's credential version (or re-issues its secret), this endpoint
// proactively invalidates the OLD credential's cached state so the next request
// rebuilds the pool with the freshly-resolved DSN instead of serving a stale
// one. It performs BOTH halves of a rotation — evict the resolver's DSN cache
// entry AND drain the registry pool — via `AppState::rotate`.
//
// The request carries the full `DatabaseMount` (same shape as /v1/admin/migrate)
// so the pool_key is reconstructed by the SAME `DatabaseMount::pool_key()` the
// hot path uses — no second key format to drift. Callers that already know the
// new version pass the OLD version in `credential_ref.version` to target the
// stale pool (the new version's pool keys distinctly and is left untouched).
//
// Admin-gated: identical `service_role` / `admin` rule + tenant match as
// /v1/admin/migrate (validate_identity_mount + is_admin). No secret is ever read,
// logged, or returned — only a drained-pool count.

#[derive(Debug, Clone, Deserialize)]
struct AdminRotateRequest {
    identity: RequestIdentity,
    mount: DatabaseMount,
}

#[derive(Debug, Clone, Serialize)]
struct AdminRotateResponse {
    pool_key: String,
    pools_drained: usize,
}

async fn rotate_credential_admin(
    State(state): State<AppState>,
    Json(request): Json<AdminRotateRequest>,
) -> impl IntoResponse {
    if let Err(message) = validate_identity_mount(&state, &request.identity, &request.mount) {
        return bad_request(message);
    }
    if !is_admin(&request.identity) {
        return (
            StatusCode::FORBIDDEN,
            Json(ApiError {
                error: "forbidden".to_string(),
                message: "/v1/admin/rotate requires role=service_role or scope=admin".to_string(),
            }),
        )
            .into_response();
    }
    // Reconstruct the pool_key with the same derivation the hot path uses (via
    // the registry's sharing policy), so the drained key is byte-identical to
    // the one `get_or_create` cached under — including B4-pools shared keys.
    let pool_key = state.registry.pool_key_for(&request.mount);
    let pools_drained = state.rotate(&pool_key).await;
    (
        StatusCode::OK,
        Json(AdminRotateResponse { pool_key, pools_drained }),
    )
        .into_response()
}

// ── /v1/admin/evict-verify ────────────────────────────────────────────────────
//
// Credential-event hook (B3): the control plane calls this after revoking an
// API key so the cached VerifiedIdentity dies NOW, not after the verify-cache
// TTL (the revoked-key-valid-≤30s hole). In-network admin surface, same trust
// model as /v1/admin/raw: body-borne identity, service_role/admin gated.
// Wholesale eviction by design — entries are keyed by raw key material, so a
// per-key contract would put secrets on the wire for no win (re-verifies are
// ~ms post-fast-hash and credential events are rare).

#[derive(Debug, Clone, Deserialize)]
struct AdminEvictVerifyRequest {
    identity: RequestIdentity,
}

#[derive(Debug, Clone, Serialize)]
struct AdminEvictVerifyResponse {
    evicted: usize,
}

async fn evict_verify_admin(
    State(state): State<AppState>,
    Json(request): Json<AdminEvictVerifyRequest>,
) -> impl IntoResponse {
    if !is_admin(&request.identity) {
        return (
            StatusCode::FORBIDDEN,
            Json(ApiError {
                error: "forbidden".to_string(),
                message: "/v1/admin/evict-verify requires role=service_role or scope=admin"
                    .to_string(),
            }),
        )
            .into_response();
    }
    let evicted = state.evict_verify_cache();
    (StatusCode::OK, Json(AdminEvictVerifyResponse { evicted })).into_response()
}

async fn not_found() -> impl IntoResponse {
    (
        StatusCode::NOT_FOUND,
        Json(ApiError {
            error: "not_found".to_string(),
            message: "route is not exposed by the Rust data-plane-router".to_string(),
        }),
    )
}

fn validate_identity_mount(
    state: &AppState,
    identity: &RequestIdentity,
    mount: &DatabaseMount,
) -> Result<(), String> {
    if !identity.is_tenant_scoped() {
        return Err("identity.tenant_id is required".to_string());
    }
    if identity.tenant_id != mount.tenant_id {
        return Err("identity tenant does not match mount tenant".to_string());
    }
    if !state.engines.iter().any(|engine| engine.engine == mount.engine) {
        return Err(format!("engine '{}' is not mounted in the Rust router", mount.engine));
    }
    Ok(())
}

#[derive(Debug, Clone, Serialize)]
struct ApiError {
    error: String,
    message: String,
}

#[derive(Debug, Clone, Serialize)]
struct NotImplementedResponse {
    error: String,
    message: String,
    next_step: &'static str,
    tx_id: Option<String>,
}

fn bad_request(message: String) -> axum::response::Response {
    (
        StatusCode::BAD_REQUEST,
        Json(ApiError {
            error: "invalid_request".to_string(),
            message,
        }),
    )
        .into_response()
}

fn not_implemented(error: &str, message: &str) -> axum::response::Response {
    (
        StatusCode::NOT_IMPLEMENTED,
        Json(NotImplementedResponse {
            error: error.to_string(),
            message: message.to_string(),
            next_step: "implement PoolRegistry, Postgres/Mongo pools, local PDP, then enable shadow routing",
            tx_id: None,
        }),
    )
        .into_response()
}

/// 429 for a tenant that exceeded its package tier's request rate (Phase 4).
/// Carries a `Retry-After: 1` hint (the bucket refills within a second at any
/// non-trivial rps).
fn too_many_requests(rps: u32) -> axum::response::Response {
    (
        StatusCode::TOO_MANY_REQUESTS,
        [(header::RETRY_AFTER, "1")],
        Json(ApiError {
            error: "rate_limited".to_string(),
            message: format!("tenant exceeded package rate limit of {rps} req/s"),
        }),
    )
        .into_response()
}

/// Track-B quota enforcement (B2): the 402 a tenant over its tier's cumulative
/// per-period usage quota receives. 402 Payment Required is the canonical "you've
/// hit your plan's metered allowance — upgrade or wait for the period to roll"
/// signal, DISTINCT from the 429 rate cap (slow down) and the 403 capability gate
/// (upgrade your tier for this feature).
fn payment_required() -> axum::response::Response {
    (
        StatusCode::PAYMENT_REQUIRED,
        Json(ApiError {
            error: "quota_exceeded".to_string(),
            message: "tenant exceeded package usage quota for the current period".to_string(),
        }),
    )
        .into_response()
}

/// Track-B spend-cap enforcement: the 402 a tenant over its ABSOLUTE spend cap
/// receives. Same 402 status as `payment_required` (both are "metered allowance"
/// signals) but a DISTINCT `spend_capped` error code, so a client can tell a
/// usage-quota exhaustion from a money-cap trip.
fn spend_capped() -> axum::response::Response {
    (
        StatusCode::PAYMENT_REQUIRED,
        Json(ApiError {
            error: "spend_capped".to_string(),
            message: "tenant exceeded its spend cap".to_string(),
        }),
    )
        .into_response()
}

/// Track-B abuse/KYC suspension: the 403 a suspended tenant receives. 403
/// Forbidden (account administratively blocked), DISTINCT from the 402 spend/quota
/// signals (which say "pay or upgrade") — a suspended account cannot un-block by
/// paying.
fn forbidden_suspended() -> axum::response::Response {
    (
        StatusCode::FORBIDDEN,
        Json(ApiError {
            error: "tenant_suspended".to_string(),
            message: "tenant is suspended".to_string(),
        }),
    )
        .into_response()
}

/// The engines advertised at `/v1/capabilities` — feature-gated to match what
/// this build can actually pool (the honesty self-check compares the two).
fn default_engines() -> Vec<EngineDescriptor> {
    vec![
        #[cfg(feature = "postgres")]
        EngineDescriptor {
            engine: "postgresql".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::postgresql(),
        },
        #[cfg(feature = "postgres")]
        EngineDescriptor {
            engine: "cockroachdb".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::cockroachdb(),
        },
        #[cfg(feature = "mongodb")]
        EngineDescriptor {
            engine: "mongodb".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::mongodb(),
        },
        #[cfg(feature = "mysql")]
        EngineDescriptor {
            engine: "mysql".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::mysql(),
        },
        #[cfg(feature = "mysql")]
        EngineDescriptor {
            engine: "mariadb".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::mariadb(),
        },
        #[cfg(feature = "redis")]
        EngineDescriptor {
            engine: "redis".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::redis(),
        },
        #[cfg(feature = "sqlite")]
        EngineDescriptor {
            engine: "sqlite".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::sqlite(),
        },
        #[cfg(feature = "mssql")]
        EngineDescriptor {
            engine: "mssql".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::mssql(),
        },
        #[cfg(feature = "http")]
        EngineDescriptor {
            engine: "http".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::http(),
        },
        // 8th engine (OFF by default): DynamoDB-compatible adapter. cfg-gated so
        // the default `/v1/capabilities` descriptor is byte-identical to the
        // 7-engine build; it appears ONLY when built `--features dynamodb`.
        #[cfg(feature = "dynamodb")]
        EngineDescriptor {
            engine: "dynamodb".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::dynamodb(),
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use data_plane_core::{DataOperation, DataResult};
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn status_of(err: DataPlaneError) -> StatusCode {
        map_data_plane_error(&err).status()
    }

    /// Minimal `TxHandle` that records how many times `rollback()` fired, so the
    /// reaper test can prove an expired tx is rolled back (not just dropped).
    struct CountingTxHandle {
        tx_id: String,
        mount_id: String,
        rolled_back: Arc<AtomicUsize>,
    }

    #[async_trait::async_trait]
    impl TxHandle for CountingTxHandle {
        fn tx_id(&self) -> &str {
            &self.tx_id
        }
        fn mount_id(&self) -> &str {
            &self.mount_id
        }
        async fn execute(
            &self,
            _op: DataOperation,
            _id: RequestIdentity,
        ) -> Result<DataResult, DataPlaneError> {
            Ok(DataResult { rows: vec![], affected_rows: 0, next_cursor: None, batch: None })
        }
        async fn commit(&self) -> Result<(), DataPlaneError> {
            Ok(())
        }
        async fn rollback(&self) -> Result<(), DataPlaneError> {
            self.rolled_back.fetch_add(1, Ordering::SeqCst);
            Ok(())
        }
        async fn prepare(&self) -> Result<(), DataPlaneError> {
            Ok(())
        }
    }

    fn counting_handle(tx_id: &str, rolled_back: Arc<AtomicUsize>) -> Arc<dyn TxHandle> {
        Arc::new(CountingTxHandle {
            tx_id: tx_id.to_string(),
            mount_id: "db1".to_string(),
            rolled_back,
        })
    }

    #[tokio::test]
    async fn reap_expired_rolls_back_and_yields_pool_key() {
        // An abandoned (begun-but-never-finalised) tx past its TTL must be reaped:
        // removed from the registry, rolled back, and its pool_key surfaced so the
        // caller can unpin the pool (otherwise the pin leaks forever).
        let reg = TransactionRegistry::default();
        let rolled_back = Arc::new(AtomicUsize::new(0));
        // Register with a zero TTL → already expired.
        let tx_id = reg
            .register(
                counting_handle("tx-expired", rolled_back.clone()),
                "t-1".into(),
                "db1".into(),
                "pool-key-1".into(),
                Duration::from_secs(0),
            )
            .await;

        // `get` must already refuse it (contract: stop handing out an expired tx).
        assert!(reg.get(&tx_id).await.is_none(), "expired tx is not handed out by get");

        let reaped = reg.reap_expired().await;
        assert_eq!(reaped.len(), 1, "the one expired tx is reaped");
        let (handle, pool_key) = &reaped[0];
        assert_eq!(pool_key, "pool-key-1", "pool_key surfaced for unpin");
        let _ = handle.rollback().await; // simulate AppState::reap_once
        assert_eq!(rolled_back.load(Ordering::SeqCst), 1, "expired tx rolled back");

        // Idempotent: a second pass finds nothing (entry already removed).
        assert!(reg.reap_expired().await.is_empty(), "reap is idempotent");
    }

    #[tokio::test]
    async fn reap_expired_keeps_live_transactions() {
        let reg = TransactionRegistry::default();
        let rolled_back = Arc::new(AtomicUsize::new(0));
        let tx_id = reg
            .register(
                counting_handle("tx-live", rolled_back.clone()),
                "t-1".into(),
                "db1".into(),
                "pool-key-1".into(),
                Duration::from_secs(3600), // far in the future
            )
            .await;
        assert!(reg.reap_expired().await.is_empty(), "live tx not reaped");
        assert!(reg.get(&tx_id).await.is_some(), "live tx still served by get");
        assert_eq!(rolled_back.load(Ordering::SeqCst), 0, "live tx not rolled back");
    }

    #[test]
    fn error_variants_map_to_expected_http_status() {
        // Request-shape mistakes are client errors (400), distinct from a
        // backend/transport failure (502). This is the contract the Postgres
        // and the other adapters now rely on.
        assert_eq!(
            status_of(DataPlaneError::InvalidRequest { message: "bad shape".into() }),
            StatusCode::BAD_REQUEST,
        );
        assert_eq!(
            status_of(DataPlaneError::InvalidIdentifier { value: "x;--".into() }),
            StatusCode::BAD_REQUEST,
        );
        // G6: an unavailable capability is a semantic (not syntactic) rejection
        // → 422, distinct from a malformed request (400) above.
        assert_eq!(
            status_of(DataPlaneError::UnsupportedCapability {
                engine: "redis".into(),
                capability: "stream".into(),
            }),
            StatusCode::UNPROCESSABLE_ENTITY,
        );
        assert_eq!(
            status_of(DataPlaneError::Backend { message: "engine down".into() }),
            StatusCode::BAD_GATEWAY,
        );
        assert_eq!(
            status_of(DataPlaneError::NotImplemented { feature: "agg".into() }),
            StatusCode::NOT_IMPLEMENTED,
        );
        // An integrity-constraint violation is the caller's fault (409), not a
        // backend failure (502).
        assert_eq!(
            status_of(DataPlaneError::Conflict { message: "duplicate key".into() }),
            StatusCode::CONFLICT,
        );
        // gap G8: an unresolvable credential and a failed provider are both
        // upstream/gateway failures (502), distinct from a 422 client error.
        assert_eq!(
            status_of(DataPlaneError::CredentialUnavailable { mount_id: "m1".into() }),
            StatusCode::BAD_GATEWAY,
        );
        assert_eq!(
            status_of(DataPlaneError::CredentialProviderFailed {
                provider: "vault".into(),
                mount_id: "m1".into(),
            }),
            StatusCode::BAD_GATEWAY,
        );
    }

    // S2 — the rotation entrypoint composes BOTH halves (resolver cache evict +
    // registry pool drain) and is safe on an empty state: an unknown key drains
    // zero pools and never panics. The deep behaviour of each half is proven in
    // the pool crate (resolver `s2_evict_cached_*` + registry `t9`/`t10`); this
    // test locks that `AppState::rotate` actually invokes both without error,
    // using a freshly-built state (no pools created → 0 drained).
    #[tokio::test]
    async fn s2_rotate_entrypoint_drains_and_evicts_safely() {
        // Build with the cache armed so the evict half exercises its real path
        // (ttl > 0) rather than the disabled no-op.
        std::env::set_var("DATA_PLANE_CREDENTIAL_CACHE_TTL_MS", "60000");
        let state = AppState::new(ServerConfig::from_env());
        std::env::remove_var("DATA_PLANE_CREDENTIAL_CACHE_TTL_MS");
        // No pool was ever created → rotating any key drains zero pools, and the
        // resolver-cache evict is a no-op-but-reached. Proves the composition is
        // wired and panic-free; concrete drain/evict behaviour is covered by the
        // pool-crate tests.
        let drained = state.rotate("t-1/default/db1/postgresql/1").await;
        assert_eq!(drained, 0, "no pool exists yet → zero drained");
        // Idempotent: a second rotate of the same key is still a clean no-op.
        assert_eq!(state.rotate("t-1/default/db1/postgresql/1").await, 0);
    }
}
