//! Shared application state: the engine registry, caches, rate limiter, metering
//! sets, and the in-process transaction registry. The `AppState` struct + its
//! constructor live here; the construction helpers are in `state_build`, the
//! runtime-operation methods in `state_ops`, and the tx registry in
//! `txregistry`. The per-resource handler modules read its `pub(super)` fields.
use crate::abac::Evaluator;
use crate::config::ServerConfig;
use crate::metrics::Metrics;
use crate::ratelimit::RateLimiter;
use crate::usage::Usage;
use data_plane_core::{DataOperation, DatabaseMount, PoolRegistry, RequestIdentity};
use data_plane_pool::{DefaultPoolRegistry, EnvMountResolver};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use super::health::EngineDescriptor;
use super::health::default_engines;
use super::state_build::{build_adapters, build_evaluator, build_honor_refreshers, build_resolver};
// `TransactionRegistry` now lives in the sibling `txregistry` module; re-export
// it here so its `super::state::TransactionRegistry` path (used by the tests in
// `mod.rs`) is unchanged.
pub(super) use super::txregistry::TransactionRegistry;

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
    /// Build the full state. Each concern is one named builder (resolver,
    /// adapter registry, ABAC evaluator, honor-set refreshers — see
    /// `state_build`); the per-field rationale lives on the struct fields above.
    /// Behaviour is identical to the previously-inlined body: same env reads,
    /// same cfg-gated adapter set, same flag-gated `Some`/`None` refreshers.
    // ponytail: exhaustive struct initializer — one line per AppState field, data not logic
    #[must_use]
    pub fn new(config: ServerConfig) -> Self {
        let evaluator = build_evaluator(&config);
        let resolver = build_resolver(&config);
        let registry = Arc::new(DefaultPoolRegistry::with_config(
            build_adapters(&resolver),
            config.max_pools,
            config.share_pools,
        ));
        // metrics is built first: the background outbox worker (D-write-tail)
        // records enqueue/write/drop counters onto it.
        let metrics = Arc::new(Metrics::default());
        // Metering aggregate (B1a/B1b): flusher spawned ONLY when metering is ON
        // (OFF → never spawned, `record` never called = byte-parity).
        let usage = Arc::new(Usage::new().with_stream_url(&config.metering_redis_url));
        if config.metering {
            usage.spawn_flusher(config.metering_flush_ms);
        }
        // Honor-set snapshots (always built, empty at parity); their Redis
        // refreshers are flag-gated `Some`/`None` in `build_honor_refreshers`.
        let quota_over = Arc::new(crate::quota::QuotaSet::new());
        let spend_over = Arc::new(crate::quota::QuotaSet::new());
        let suspended = Arc::new(crate::quota::QuotaSet::new());
        let refreshers = build_honor_refreshers(&config);
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
            quota_refresher: refreshers.quota,
            spend_over,
            spend_refresher: refreshers.spend,
            suspended,
            suspend_refresher: refreshers.suspend,
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
        if let Some(hit) = self.mount_cache_get(&ckey, ttl) {
            return Ok(hit);
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
        self.mount_cache_put(ckey, &mount, ttl);
        Ok(mount)
    }

    /// Fresh-enough cached bypass mount for `ckey`, recording the cache HIT.
    /// `None` (and no record) when caching is disabled (`ttl==0`), the lock is
    /// poisoned, the key is absent, or the entry is stale — the caller then
    /// records the MISS and resolves.
    fn mount_cache_get(
        &self,
        ckey: &str,
        ttl: std::time::Duration,
    ) -> Option<crate::auth::ResolvedMount> {
        if ttl.is_zero() {
            return None;
        }
        let cache = self.mount_cache.lock().ok()?;
        let (at, m) = cache.get(ckey)?;
        if at.elapsed() < ttl {
            self.metrics.record_mount_cache(true);
            Some(m.clone())
        } else {
            None
        }
    }

    /// Insert a freshly-resolved bypass mount under `ckey` (no-op when caching is
    /// disabled or the lock is poisoned). Bounds the map at 4096 entries so a
    /// key-spray can't grow it unboundedly.
    fn mount_cache_put(&self, ckey: String, mount: &crate::auth::ResolvedMount, ttl: std::time::Duration) {
        if ttl.is_zero() {
            return;
        }
        if let Ok(mut cache) = self.mount_cache.lock() {
            if cache.len() >= 4096 {
                cache.clear();
            }
            cache.insert(ckey, (std::time::Instant::now(), mount.clone()));
        }
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
