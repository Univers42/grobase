use crate::credential::{ProviderConfig, ProviderRegistry};
use async_trait::async_trait;
use data_plane_core::{DataPlaneError, DataPlaneResult, DatabaseMount, Isolation};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// Resolves a [`DatabaseMount`] to a concrete connection string (DSN).
///
/// During the shadow phase this is backed by a static env-provided map so that
/// secrets never travel in request bodies. It will later be backed by a call to
/// the Go `adapter-registry` `/databases/{id}/connect` endpoint.
#[async_trait]
pub trait MountResolver: Send + Sync {
    async fn resolve_dsn(&self, mount: &DatabaseMount) -> DataPlaneResult<String>;
}

/// Process-wide DSN cache (gap G8, default OFF). Keyed by
/// [`DatabaseMount::pool_key`] — which already embeds `credential_ref.version`,
/// so a rotation (version bump) keys a NEW entry and a drain of the old key
/// evicts only the stale credential. Disabled unless `ttl > 0`; we never
/// consult nor populate it at `ttl == 0`, and we never log the cached value.
#[derive(Default)]
struct CredentialCache {
    ttl: Duration,
    entries: Mutex<HashMap<String, (String, Instant)>>,
}

impl CredentialCache {
    fn disabled() -> Self {
        Self::default()
    }

    fn enabled(&self) -> bool {
        !self.ttl.is_zero()
    }

    /// Return a still-fresh cached DSN for `pool_key`, or `None`. Always `None`
    /// when the cache is disabled (`ttl == 0`).
    fn get(&self, pool_key: &str) -> Option<String> {
        if !self.enabled() {
            return None;
        }
        let guard = self.entries.lock().expect("credential cache poisoned");
        guard.get(pool_key).and_then(|(dsn, at)| {
            if at.elapsed() < self.ttl {
                Some(dsn.clone())
            } else {
                None
            }
        })
    }

    /// Store a freshly-resolved DSN under `pool_key`. No-op when disabled.
    fn put(&self, pool_key: &str, dsn: &str) {
        if !self.enabled() {
            return;
        }
        let mut guard = self.entries.lock().expect("credential cache poisoned");
        guard.insert(pool_key.to_string(), (dsn.to_string(), Instant::now()));
    }

    /// Evict the cached DSN for `pool_key` (called on rotation drain). No-op
    /// when disabled or absent.
    fn evict(&self, pool_key: &str) {
        if !self.enabled() {
            return;
        }
        let mut guard = self.entries.lock().expect("credential cache poisoned");
        guard.remove(pool_key);
    }
}

/// Resolver backed by a `reference -> dsn` map parsed from the
/// `DATA_PLANE_MOUNTS` env var (JSON object), plus pluggable credential
/// providers (gap G8). Resolution order is fixed in `resolve_dsn` (see there);
/// providers are disabled by default so the inline/env-map behaviour is
/// unchanged until a provider is configured.
#[derive(Default)]
pub struct EnvMountResolver {
    entries: HashMap<String, String>,
    providers: ProviderRegistry,
    cache: CredentialCache,
}

impl EnvMountResolver {
    /// Build from a JSON object string mapping credential references to DSNs.
    /// No providers are registered (empty registry) and the cache is disabled —
    /// used by tests and purely-env deployments.
    #[must_use]
    pub fn from_json(json: &str) -> Self {
        let entries = serde_json::from_str::<HashMap<String, String>>(json).unwrap_or_default();
        Self {
            entries,
            providers: ProviderRegistry::default(),
            cache: CredentialCache::disabled(),
        }
    }

    /// Build from the `DATA_PLANE_MOUNTS` environment variable (empty if unset),
    /// with credential providers built from env ([`ProviderRegistry::from_env`])
    /// and the DSN cache TTL read from `DATA_PLANE_CREDENTIAL_CACHE_TTL_MS`
    /// (default 0 → disabled).
    #[must_use]
    pub fn from_env() -> Self {
        let entries = match std::env::var("DATA_PLANE_MOUNTS") {
            Ok(json) if !json.trim().is_empty() => {
                serde_json::from_str::<HashMap<String, String>>(&json).unwrap_or_default()
            }
            _ => HashMap::new(),
        };
        let ttl_ms = std::env::var("DATA_PLANE_CREDENTIAL_CACHE_TTL_MS")
            .ok()
            .and_then(|v| v.trim().parse::<u64>().ok())
            .unwrap_or(0);
        Self {
            entries,
            providers: ProviderRegistry::from_env(),
            cache: CredentialCache {
                ttl: Duration::from_millis(ttl_ms),
                entries: Mutex::new(HashMap::new()),
            },
        }
    }

    /// Build from explicit, server-owned configuration — the single source path
    /// the server uses so `ServerConfig` (not a second env reader) owns the
    /// provider contract. `mounts_json` is the `DATA_PLANE_MOUNTS` body (may be
    /// empty); `provider_cfg` builds the [`ProviderRegistry`]; `cache_ttl_ms`
    /// arms the DSN cache (0 → disabled).
    #[must_use]
    pub fn from_config(
        mounts_json: &str,
        provider_cfg: &ProviderConfig,
        cache_ttl_ms: u64,
    ) -> Self {
        let entries = if mounts_json.trim().is_empty() {
            HashMap::new()
        } else {
            serde_json::from_str::<HashMap<String, String>>(mounts_json).unwrap_or_default()
        };
        Self {
            entries,
            providers: ProviderRegistry::from_config(provider_cfg),
            cache: CredentialCache {
                ttl: Duration::from_millis(cache_ttl_ms),
                entries: Mutex::new(HashMap::new()),
            },
        }
    }

    /// Test/construction seam: install an explicit provider registry (and keep
    /// the cache disabled). Lets tests assert provider precedence without env.
    #[must_use]
    pub fn with_providers(mut self, providers: ProviderRegistry) -> Self {
        self.providers = providers;
        self
    }

    /// Evict any cached DSN for `pool_key` (rotation drain hook). No-op when the
    /// cache is disabled.
    ///
    /// Rotation (gap G8) has two automatic + two proactive parts. A version bump
    /// changes `credential_ref.version`, which changes [`DatabaseMount::pool_key`],
    /// so a rotated mount automatically keys a NEW pool + cache entry (the old
    /// version's are simply no longer reached). The proactive hooks retire the
    /// STALE state immediately: this `evict_cached` drops the resolver's cached
    /// DSN, and [`crate::registry::DefaultPoolRegistry::drain_pool_key`] closes
    /// the old pool. A rotation MUST call BOTH or a stale cached DSN survives the
    /// pool drain; the single caller that does so is the server's
    /// `AppState::rotate` (exposed over `POST /v1/admin/rotate`).
    ///
    /// [`DatabaseMount::pool_key`]: data_plane_core::DatabaseMount::pool_key
    pub fn evict_cached(&self, pool_key: &str) {
        self.cache.evict(pool_key);
    }
}

#[async_trait]
impl MountResolver for EnvMountResolver {
    async fn resolve_dsn(&self, mount: &DatabaseMount) -> DataPlaneResult<String> {
        // 1. Inline DSN wins — PARITY-CRITICAL. The TS query-router proxy already
        //    fetched `connection_string` and supplied it inline; this branch MUST
        //    stay first so that hot 201 path is byte-unchanged. Providers (step 2)
        //    only ever run when inline is absent.
        if let Some(dsn) = mount.inline_dsn.as_ref() {
            if !dsn.trim().is_empty() {
                return Ok(dsn.clone());
            }
        }
        // 2. Pluggable credential providers (gap G8). Single O(1) dispatch keyed
        //    by `credential_ref.provider`. Disabled by default — `get` returns
        //    None unless a provider was configured, so this is a no-op in the
        //    parity baseline. A configured provider is consulted BEFORE the
        //    db_per_tenant guard so a db_per_tenant mount may resolve via its
        //    own provider (its own distinct DSN), but NEVER via the shared map.
        //    The DSN cache (default OFF) wraps the provider call only.
        if let Some(provider) = self.providers.get(&mount.credential_ref.provider) {
            let pool_key = mount.pool_key();
            if let Some(dsn) = self.cache.get(&pool_key) {
                return Ok(dsn);
            }
            let dsn = provider.resolve_dsn(mount).await?;
            self.cache.put(&pool_key, &dsn);
            return Ok(dsn);
        }
        // 3. db_per_tenant fail-closed RUNTIME guard (M3, relocated for G8 per
        //    D-extra). A `db_per_tenant` mount MUST resolve to its own distinct
        //    DSN; its only legitimate sources are an inline DSN (step 1) or a
        //    configured provider (step 2). If we reached this point a
        //    db_per_tenant mount has NEITHER, so it must fail closed — even if
        //    `DATA_PLANE_MOUNTS` happened to carry an entry under its credential
        //    reference, borrowing that SHARED map would breach the per-tenant
        //    isolation contract (cross-tenant data exposure). Placing the guard
        //    after providers but before the shared map keeps that invariant: a
        //    provider may serve db_per_tenant; the shared map never can. This is
        //    a hard runtime return (NOT a `debug_assert`).
        if matches!(mount.isolation(), Isolation::DbPerTenant) {
            return Err(DataPlaneError::CredentialUnavailable {
                mount_id: mount.id.clone(),
            });
        }
        // 4. Static env-provided map (DATA_PLANE_MOUNTS), for server-side flows.
        //    Only reachable for shared_rls / schema_per_tenant (db_per_tenant
        //    already returned above) AND when no provider answered.
        if let Some(dsn) = self.entries.get(&mount.credential_ref.reference) {
            return Ok(dsn.clone());
        }
        // 5. Fail closed: no inline DSN, no provider, no registry entry → no
        //    connection string. There is no shared-DSN fallback for any strategy,
        //    and an unknown provider name (not registered) lands here too — never
        //    a silent fall-through to a weaker credential.
        Err(DataPlaneError::CredentialUnavailable {
            mount_id: mount.id.clone(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use data_plane_core::{CredentialRef, PoolPolicy};

    fn mount(reference: &str, isolation: Option<&str>, inline: Option<&str>) -> DatabaseMount {
        DatabaseMount {
            id: "db1".into(),
            tenant_id: "t-1".into(),
            project_id: None,
            engine: "postgresql".into(),
            name: "n".into(),
            credential_ref: CredentialRef {
                provider: "adapter-registry".into(),
                reference: reference.into(),
                version: "1".into(),
            },
            pool_policy: PoolPolicy::default(),
            capability_overrides: None,
            inline_dsn: inline.map(str::to_string),
            isolation: isolation.map(str::to_string),
            replica_inline_dsn: None,
            read_replica_route: false,
        }
    }

    #[tokio::test]
    async fn inline_dsn_wins() {
        let r = EnvMountResolver::default();
        let m = mount("missing", Some("db_per_tenant"), Some("postgres://inline"));
        assert_eq!(r.resolve_dsn(&m).await.unwrap(), "postgres://inline");
    }

    #[tokio::test]
    async fn env_map_resolves_when_no_inline() {
        let r = EnvMountResolver::from_json(r#"{"cred-a":"postgres://env"}"#);
        let m = mount("cred-a", None, None);
        assert_eq!(r.resolve_dsn(&m).await.unwrap(), "postgres://env");
    }

    #[tokio::test]
    async fn db_per_tenant_without_dsn_fails_closed() {
        // No inline DSN, no registry entry → CredentialUnavailable, NEVER a
        // shared-DSN fallback. This is the db_per_tenant isolation guarantee.
        let r = EnvMountResolver::default();
        let m = mount("absent", Some("db_per_tenant"), None);
        let err = r.resolve_dsn(&m).await.unwrap_err();
        assert!(
            matches!(err, DataPlaneError::CredentialUnavailable { .. }),
            "{err:?}"
        );
    }

    #[tokio::test]
    async fn db_per_tenant_never_falls_back_to_shared_registry_dsn() {
        // M3 runtime guard (holds in release builds, unlike the old debug_assert):
        // even when DATA_PLANE_MOUNTS DOES carry an entry under this mount's
        // credential reference, a db_per_tenant mount with no inline DSN must
        // fail closed rather than borrow that (shared) DSN.
        let r = EnvMountResolver::from_json(r#"{"shared-cred":"postgres://shared"}"#);
        let m = mount("shared-cred", Some("db_per_tenant"), None);
        let err = r.resolve_dsn(&m).await.unwrap_err();
        assert!(
            matches!(err, DataPlaneError::CredentialUnavailable { .. }),
            "db_per_tenant must not borrow a shared registry DSN: {err:?}"
        );
        // Sanity: the SAME registry entry IS usable for a shared_rls mount.
        let shared = mount("shared-cred", Some("shared_rls"), None);
        assert_eq!(r.resolve_dsn(&shared).await.unwrap(), "postgres://shared");
    }

    // ---- gap G8: pluggable-provider resolution (D-extra ordering) -----------
    use crate::credential::{CredentialProvider, ProviderRegistry};
    use std::sync::Arc;

    /// A mount with an explicit provider name (the shared `mount` helper pins
    /// `"adapter-registry"`; G8 tests need to vary it).
    fn mount_with_provider(
        provider: &str,
        reference: &str,
        isolation: Option<&str>,
        inline: Option<&str>,
    ) -> DatabaseMount {
        let mut m = mount(reference, isolation, inline);
        m.credential_ref.provider = provider.into();
        m
    }

    /// Provider stub that returns a fixed DSN under a configurable name.
    struct StubProvider {
        name: String,
        dsn: String,
    }
    #[async_trait]
    impl CredentialProvider for StubProvider {
        fn name(&self) -> &str {
            &self.name
        }
        async fn resolve_dsn(&self, _m: &DatabaseMount) -> DataPlaneResult<String> {
            Ok(self.dsn.clone())
        }
    }

    /// Provider that MUST never be invoked — its `resolve_dsn` panics so a test
    /// proving the inline fast-path bypasses providers fails loudly otherwise.
    struct NeverProvider {
        name: String,
    }
    #[async_trait]
    impl CredentialProvider for NeverProvider {
        fn name(&self) -> &str {
            &self.name
        }
        async fn resolve_dsn(&self, _m: &DatabaseMount) -> DataPlaneResult<String> {
            panic!("provider must not be called when inline_dsn is present");
        }
    }

    fn registry(providers: Vec<Arc<dyn CredentialProvider>>) -> ProviderRegistry {
        ProviderRegistry::with(providers)
    }

    // t4 — inline DSN bypasses providers entirely (PARITY fast-path). A provider
    // is registered for this mount's name but asserts it is never called.
    #[tokio::test]
    async fn t4_inline_dsn_bypasses_providers() {
        let r =
            EnvMountResolver::default().with_providers(registry(vec![Arc::new(NeverProvider {
                name: "adapter-registry".into(),
            })]));
        let m = mount_with_provider(
            "adapter-registry",
            "ref",
            None,
            Some("postgres://inline-wins"),
        );
        assert_eq!(r.resolve_dsn(&m).await.unwrap(), "postgres://inline-wins");
    }

    // t5 — precedence change vs the old env_map test: per D-extra the provider
    // now runs BEFORE the shared env-map, so with BOTH configured the PROVIDER
    // wins. (The legacy `env_map_resolves_when_no_inline` test still passes
    // because its resolver registers NO provider.)
    #[tokio::test]
    async fn t5_provider_wins_over_env_map() {
        let r = EnvMountResolver::from_json(r#"{"cred-a":"postgres://from-env-map"}"#)
            .with_providers(registry(vec![Arc::new(StubProvider {
                name: "adapter-registry".into(),
                dsn: "postgres://from-provider".into(),
            })]));
        let m = mount_with_provider("adapter-registry", "cred-a", None, None);
        assert_eq!(r.resolve_dsn(&m).await.unwrap(), "postgres://from-provider");
    }

    // t6 — provider resolves when there is no inline DSN and no env-map entry.
    #[tokio::test]
    async fn t6_provider_resolves_when_no_inline_and_no_env() {
        let r =
            EnvMountResolver::default().with_providers(registry(vec![Arc::new(StubProvider {
                name: "vault".into(),
                dsn: "postgres://vault-dsn".into(),
            })]));
        let m = mount_with_provider("vault", "ref", None, None);
        assert_eq!(r.resolve_dsn(&m).await.unwrap(), "postgres://vault-dsn");
    }

    // t2 — unknown provider fails closed: empty registry, provider="vault",
    // shared_rls, no inline, no env → CredentialUnavailable (NOT a silent
    // fall-through to a weaker credential).
    #[tokio::test]
    async fn t2_unknown_provider_fails_closed() {
        let r = EnvMountResolver::default(); // empty registry
        let m = mount_with_provider("vault", "ref", Some("shared_rls"), None);
        let err = r.resolve_dsn(&m).await.unwrap_err();
        assert!(
            matches!(err, DataPlaneError::CredentialUnavailable { .. }),
            "{err:?}"
        );
    }

    // ---- gap G8 / S2: rotation cache-eviction hook -------------------------

    /// Build a resolver with the DSN cache ARMED (ttl > 0) and a single stub
    /// provider, so a test can prove resolve→cache→evict→miss without env or a
    /// live secret. Constructed via the private fields directly (in-module).
    fn resolver_with_cache(
        provider: Arc<dyn CredentialProvider>,
        ttl: Duration,
    ) -> EnvMountResolver {
        EnvMountResolver {
            entries: HashMap::new(),
            providers: ProviderRegistry::with(vec![provider]),
            cache: CredentialCache {
                ttl,
                entries: Mutex::new(HashMap::new()),
            },
        }
    }

    /// A provider that counts how many times it was actually called, so the test
    /// can distinguish a cache HIT (no call) from a re-resolve after eviction.
    struct CountingProvider {
        name: String,
        dsn: String,
        calls: Arc<std::sync::atomic::AtomicUsize>,
    }
    #[async_trait]
    impl CredentialProvider for CountingProvider {
        fn name(&self) -> &str {
            &self.name
        }
        async fn resolve_dsn(&self, _m: &DatabaseMount) -> DataPlaneResult<String> {
            self.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Ok(self.dsn.clone())
        }
    }

    // S2 — `evict_cached(pool_key)` removes the cached DSN so the NEXT resolve
    // re-invokes the provider (a stale cached DSN cannot survive a rotation
    // drain). With the cache armed: first resolve populates + provider called
    // once; second resolve is a HIT (still one call); after evict, the third
    // resolve MISSES and the provider is called again.
    #[tokio::test]
    async fn s2_evict_cached_forces_reresolve() {
        use std::sync::atomic::Ordering;
        let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let r = resolver_with_cache(
            Arc::new(CountingProvider {
                name: "vault".into(),
                dsn: "postgres://rotated".into(),
                calls: calls.clone(),
            }),
            Duration::from_secs(60),
        );
        let m = mount_with_provider("vault", "ref", None, None);
        let key = m.pool_key();

        assert_eq!(r.resolve_dsn(&m).await.unwrap(), "postgres://rotated");
        assert_eq!(
            calls.load(Ordering::SeqCst),
            1,
            "first resolve hits the provider"
        );
        // Cached now → second resolve is a HIT (provider NOT called again).
        assert_eq!(r.resolve_dsn(&m).await.unwrap(), "postgres://rotated");
        assert_eq!(
            calls.load(Ordering::SeqCst),
            1,
            "second resolve served from cache"
        );
        // Rotation evicts the cache entry for this key → next resolve MISSES.
        r.evict_cached(&key);
        assert_eq!(r.resolve_dsn(&m).await.unwrap(), "postgres://rotated");
        assert_eq!(
            calls.load(Ordering::SeqCst),
            2,
            "post-evict resolve re-hits the provider"
        );
    }

    // S2 — eviction is scoped to exactly the rotated key: evicting key A leaves
    // key B's cached DSN intact (a rotation drains only the old version's pool).
    #[tokio::test]
    async fn s2_evict_cached_is_key_scoped() {
        use std::sync::atomic::Ordering;
        let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let r = resolver_with_cache(
            Arc::new(CountingProvider {
                name: "vault".into(),
                dsn: "postgres://x".into(),
                calls: calls.clone(),
            }),
            Duration::from_secs(60),
        );
        // Two mounts differing ONLY by version → distinct pool_keys.
        let mut m_v1 = mount_with_provider("vault", "ref", None, None);
        m_v1.credential_ref.version = "1".into();
        let mut m_v2 = mount_with_provider("vault", "ref", None, None);
        m_v2.credential_ref.version = "2".into();
        r.resolve_dsn(&m_v1).await.unwrap();
        r.resolve_dsn(&m_v2).await.unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 2, "two distinct keys cached");
        // Evict only v1; v2 must remain a cache HIT.
        r.evict_cached(&m_v1.pool_key());
        r.resolve_dsn(&m_v2).await.unwrap();
        assert_eq!(
            calls.load(Ordering::SeqCst),
            2,
            "v2 still cached after evicting v1"
        );
        r.resolve_dsn(&m_v1).await.unwrap();
        assert_eq!(
            calls.load(Ordering::SeqCst),
            3,
            "v1 re-resolved after its eviction"
        );
    }

    // t7 — D-extra lock: a db_per_tenant mount WITH a configured provider
    // resolves via that provider (its own distinct DSN), but WITHOUT a provider
    // it fails closed — it must NEVER borrow the shared env-map.
    #[tokio::test]
    async fn t7_db_per_tenant_with_provider_resolves_else_fails_closed() {
        // With a provider configured for this mount's name → provider serves it.
        let with_p = EnvMountResolver::from_json(r#"{"ref":"postgres://shared-map"}"#)
            .with_providers(registry(vec![Arc::new(StubProvider {
                name: "vault".into(),
                dsn: "postgres://tenant-distinct".into(),
            })]));
        let m = mount_with_provider("vault", "ref", Some("db_per_tenant"), None);
        assert_eq!(
            with_p.resolve_dsn(&m).await.unwrap(),
            "postgres://tenant-distinct",
            "db_per_tenant resolves via its provider"
        );
        // No provider registered → must fail closed even though the shared map
        // carries an entry under this reference (no cross-tenant borrow).
        let no_p = EnvMountResolver::from_json(r#"{"ref":"postgres://shared-map"}"#);
        let m2 = mount_with_provider("vault", "ref", Some("db_per_tenant"), None);
        let err = no_p.resolve_dsn(&m2).await.unwrap_err();
        assert!(
            matches!(err, DataPlaneError::CredentialUnavailable { .. }),
            "db_per_tenant with no provider must fail closed, not borrow the shared map: {err:?}"
        );
    }
}
