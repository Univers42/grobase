//! Shared application state: the engine registry, caches, rate limiter, metering
//! sets, and the in-process transaction registry. Construction + boot self-check
//! live here; the per-resource handler modules read its `pub(super)` fields.
use crate::abac::{Evaluator, PermissionMode, PolicyBundle};
use crate::config::ServerConfig;
use crate::metrics::Metrics;
use crate::ratelimit::RateLimiter;
use crate::usage::Usage;
use data_plane_core::{
    DataOperation, DatabaseMount, EngineAdapter, PoolRegistry, RequestIdentity, TxHandle,
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
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime};
use tokio::sync::Mutex;

use super::health::EngineDescriptor;
use super::health::default_engines;

/// Lives inside `AppState`. Owns active multi-statement transaction handles
/// keyed by `tx_id`. Concurrent calls to the same `tx_id` are serialised by
/// the per-handle internal `Mutex` (see `PgTxHandle`), but the registry-level
/// map itself uses a tokio `Mutex` because we mutate it across `.await`.
#[derive(Default)]
pub(super) struct TransactionRegistry {
    pub(super) map: Mutex<HashMap<String, TransactionEntry>>,
}

pub(super) struct TransactionEntry {
    pub(super) handle: Arc<dyn TxHandle>,
    pub(super) tenant_id: String,
    /// `pool_key` of the pool this tx's connection was checked out from. Used to
    /// pin that pool against eviction/reaping while the tx is open, and to
    /// unpin it on commit/rollback.
    pub(super) pool_key: String,
    // Kept for diagnostics — `#[allow(dead_code)]` documents the intent.
    #[allow(dead_code)]
    pub(super) mount_id: String,
    #[allow(dead_code)]
    pub(super) opened_at: SystemTime,
    /// When the tx pin expires. The reaper (`reap_expired`) best-effort rolls
    /// back + unpins entries past this, and `get` refuses an expired entry, so a
    /// begun-but-never-finalised tx cannot pin its pool forever.
    pub(super) expires_at: SystemTime,
}

impl TransactionRegistry {
    pub(super) async fn register(
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
    pub(super) async fn get(&self, tx_id: &str) -> Option<(Arc<dyn TxHandle>, String)> {
        let now = SystemTime::now();
        let map = self.map.lock().await;
        map.get(tx_id)
            .filter(|e| e.expires_at > now)
            .map(|e| (e.handle.clone(), e.tenant_id.clone()))
    }

    /// Remove the entry, returning both the handle and the `pool_key` so the
    /// caller can unpin the pool after finalising the tx.
    pub(super) async fn take(&self, tx_id: &str) -> Option<(Arc<dyn TxHandle>, String)> {
        let mut map = self.map.lock().await;
        map.remove(tx_id).map(|e| (e.handle, e.pool_key))
    }

    /// Remove every entry past its `expires_at`, returning their (handle,
    /// pool_key) so the caller can best-effort roll back the handle and unpin its
    /// pool OUTSIDE the lock (both are async). A begun-but-never-committed tx
    /// otherwise pins its pool forever (never evictable / reapable). Idempotent;
    /// safe to call on a timer.
    pub(super) async fn reap_expired(&self) -> Vec<(Arc<dyn TxHandle>, String)> {
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
    pub(super) config: Arc<ServerConfig>,
    pub(super) engines: Arc<Vec<EngineDescriptor>>,
    pub(super) registry: Arc<DefaultPoolRegistry>,
    /// The DSN resolver, shared (same `Arc`) with every engine adapter so a
    /// rotation can evict its credential cache. Holding it here lets ONE handler
    /// (`/v1/admin/rotate`) perform BOTH halves of a rotation atomically: drain
    /// the registry pool AND evict the resolver's cached DSN. Without both, a
    /// stale cached DSN would survive a pool drain (gap G8 / S2).
    pub(super) resolver: Arc<EnvMountResolver>,
    pub(super) transactions: Arc<TransactionRegistry>,
    /// Optional in-Rust ABAC evaluator. Populated when
    /// `DATA_PLANE_PERMISSION_BUNDLE` env is a valid JSON bundle; otherwise
    /// `/v1/permissions/decide` returns 503 and callers fall back to the
    /// permission-engine HTTP path.
    pub(super) evaluator: Option<Arc<Evaluator>>,
    /// Process-wide request/uptime counters exposed at `/metrics`.
    pub(super) metrics: Arc<Metrics>,
    /// Per-tenant token-bucket rate limiter (Phase 4 tiering). Limits arrive per
    /// request in the mount's tier mask (`capability_overrides`); a tenant with
    /// no mask is unlimited, so this is a no-op until packages are assigned.
    pub(super) ratelimiter: Arc<RateLimiter>,
    /// Track-B metering (B1a): per-tenant usage aggregate. The read/write hot
    /// path calls `record` ONLY when `config.metering` is ON (a flag short-
    /// circuit before any extra field access), so at parity this stays empty and
    /// its background flusher is never spawned — byte-parity with today.
    pub(super) usage: Arc<Usage>,
    /// Track-B quota enforcement (B2): in-memory snapshot of the over-quota tenant
    /// ids the control-plane QuotaGuard published to Redis (`quota:over`). The hot
    /// path consults it ONLY when `config.quota_enforcement` is ON (a flag short-
    /// circuit before any field access), so at parity this stays empty and is never
    /// touched — byte-parity with today. Refreshed off the request path on the
    /// reaper tick via [`quota::QuotaRefresher`].
    pub(super) quota_over: Arc<crate::quota::QuotaSet>,
    /// Track-B quota enforcement (B2): the Redis snapshot refresher. `Some` only
    /// when `config.quota_enforcement` is ON; the reaper calls `refresh` each tick.
    /// `None` at parity → no refresh task touches Redis.
    pub(super) quota_refresher: Option<Arc<crate::quota::QuotaRefresher>>,
    /// Track-B spend-cap enforcement: in-memory snapshot of the over-spend tenant
    /// ids the control-plane spend-cap guard published to Redis (`spend:over`).
    /// Mirrors `quota_over` exactly — consulted on the hot path ONLY when
    /// `config.spend_caps` is ON (a `bool` short-circuit before any field access),
    /// so at parity it stays empty and is never touched (byte-parity).
    pub(super) spend_over: Arc<crate::quota::QuotaSet>,
    /// Track-B spend-cap enforcement: the Redis snapshot refresher for `spend:over`.
    /// `Some` only when `config.spend_caps` is ON; `None` at parity → no refresh
    /// task touches Redis for it.
    pub(super) spend_refresher: Option<Arc<crate::quota::QuotaRefresher>>,
    /// Track-B abuse/KYC suspension: in-memory snapshot of the suspended tenant ids
    /// the control-plane abuse guard published to Redis (`tenant:suspended`).
    /// Mirrors `quota_over` exactly — consulted on the hot path ONLY when
    /// `config.suspend_reader` is ON (a `bool` short-circuit before any field
    /// access), so at parity it stays empty and is never touched (byte-parity).
    pub(super) suspended: Arc<crate::quota::QuotaSet>,
    /// Track-B abuse/KYC suspension: the Redis snapshot refresher for
    /// `tenant:suspended`. `Some` only when `config.suspend_reader` is ON; `None`
    /// at parity → no refresh task touches Redis for it.
    pub(super) suspend_refresher: Option<Arc<crate::quota::QuotaRefresher>>,
    /// Shared HTTP client for the Phase-7 bypass front door (`/data/v1`): calls
    /// tenant-control `/v1/keys/verify` + adapter-registry `/connect`. Cheap to
    /// clone (Arc inside); only used when the bypass is enabled.
    pub(super) http_client: reqwest::Client,
    /// Phase 7d / D-write-tail: background outbox emitter (row-change events on
    /// the bypass write path). `None` unless `DATA_PLANE_OUTBOX_DSN` is set — the
    /// bypass works without it, but realtime/webhooks only fire post-cutover once
    /// it's wired. The INSERT runs on a spawned worker (batched), OFF the request
    /// path, so the write tail no longer pays a second DB round-trip.
    #[cfg(feature = "control-pg")]
    pub(super) outbox: Option<Arc<crate::outbox::BackgroundOutbox>>,
    /// Phase D — server-backed automations on the bypass write path. `None`
    /// unless `DATA_PLANE_OUTBOX_DSN` is set (the control Postgres holding the
    /// `automation_rules`); fires `set_property` follow-ups after bypass writes.
    #[cfg(feature = "control-pg")]
    pub(super) automations: Option<Arc<crate::automations::AutomationEngine>>,
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
    pub(super) verify_cache: Arc<std::sync::Mutex<HashMap<String, (std::time::Instant, crate::auth::VerifiedIdentity)>>>,
    /// Companion cache for the bypass mount resolution (`(tenant,db_id) → DSN/
    /// engine/tier`), same TTL as `verify_cache` — mirrors the query-router DSN
    /// cache so the cutover door doesn't re-hit adapter-registry per request.
    pub(super) mount_cache: Arc<std::sync::Mutex<HashMap<String, (std::time::Instant, crate::auth::ResolvedMount)>>>,
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
