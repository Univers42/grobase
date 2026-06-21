/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   registry.rs                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:31:44 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:31:46 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

use async_trait::async_trait;
use data_plane_core::{
    DataOperation, DataPlaneError, DataPlaneResult, DataResult, DatabaseMount, EngineAdapter,
    EnginePool, PoolRegistry, PoolStats, RequestIdentity, TxBeginRequest, TxHandle,
};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Default cap on simultaneously-open pools when `DATA_PLANE_MAX_POOLS` is
/// unset or unparsable. Bounds memory under N-tenant fan-out (db_per_tenant /
/// schema_per_tenant can otherwise grow one pool per tenant unboundedly).
pub const DEFAULT_MAX_POOLS: usize = 256;

struct PoolEntry {
    engine: String,
    pool: Arc<dyn EnginePool>,
    /// Last time this entry was handed out — drives LRU eviction + idle reaping.
    last_access: Instant,
    /// Idle TTL captured from the mount's pool_policy at creation.
    idle_ttl: Duration,
    /// Number of in-flight transactions holding a handle derived from this
    /// pool. A pinned entry (`> 0`) is excluded from BOTH LRU eviction and
    /// idle reaping so we never close a pool out from under an open tx.
    tx_pins: usize,
}

/// Default in-process pool registry. Keeps at most `max_pools` open pools, one
/// per [`DatabaseMount::pool_key`], dispatching to a per-engine
/// [`EngineAdapter`]. Eviction is LRU with a hard floor: a pool with an
/// in-flight transaction (`tx_pins > 0`) is never evicted or reaped.
pub struct DefaultPoolRegistry {
    adapters: HashMap<String, Arc<dyn EngineAdapter>>,
    pools: Mutex<HashMap<String, PoolEntry>>,
    max_pools: usize,
    // B4-pools: when true, shared_rls mounts on the same connection target share
    // one pool (keyed by DSN/credential, not tenant). Off by default → per-
    // tenant pools (byte-parity). Every pool_key derivation in the server flows
    // through `pool_key_for`, so the tx-pin/rotation keys always match.
    share_pools: bool,
    // Scale counters (B3): cumulative pool lifecycle events. evicted climbing
    // at steady state means the mount working set exceeds max_pools (LRU
    // churn) — the primary signal the 10K-tenant experiments watch.
    created: AtomicU64,
    evicted: AtomicU64,
    reaped: AtomicU64,
}

impl DefaultPoolRegistry {
    /// Build with the default pool cap ([`DEFAULT_MAX_POOLS`]).
    #[must_use]
    pub fn new(adapters: Vec<Arc<dyn EngineAdapter>>) -> Self {
        Self::with_max_pools(adapters, DEFAULT_MAX_POOLS)
    }

    /// Build with an explicit pool cap. A cap of 0 is coerced to 1 (we must be
    /// able to hold at least the pool we just created).
    #[must_use]
    pub fn with_max_pools(adapters: Vec<Arc<dyn EngineAdapter>>, max_pools: usize) -> Self {
        // Default: per-tenant pools (sharing off) — byte-parity with pre-B4.
        Self::with_config(adapters, max_pools, false)
    }

    /// Build with an explicit pool cap AND the B4-pools sharing policy.
    #[must_use]
    pub fn with_config(
        adapters: Vec<Arc<dyn EngineAdapter>>,
        max_pools: usize,
        share_pools: bool,
    ) -> Self {
        let map = adapters
            .into_iter()
            .map(|a| (a.engine().to_string(), a))
            .collect();
        Self {
            adapters: map,
            pools: Mutex::new(HashMap::new()),
            max_pools: max_pools.max(1),
            share_pools,
            created: AtomicU64::new(0),
            evicted: AtomicU64::new(0),
            reaped: AtomicU64::new(0),
        }
    }

    /// The pool key for a mount under THIS registry's sharing policy. The single
    /// derivation point: the server reconstructs tx-pin / rotation keys through
    /// this, so they always match the key `get_or_create` used.
    #[must_use]
    pub fn pool_key_for(&self, mount: &DatabaseMount) -> String {
        mount.effective_pool_key(self.share_pools)
    }

    /// Scale-counter snapshot for `/metrics` (B3):
    /// `(created_total, evicted_total, reaped_total, open_now)`.
    #[must_use]
    pub fn scale_counters(&self) -> (u64, u64, u64, usize) {
        let open = self.pools.lock().expect("pool registry poisoned").len();
        (
            self.created.load(Ordering::Relaxed),
            self.evicted.load(Ordering::Relaxed),
            self.reaped.load(Ordering::Relaxed),
            open,
        )
    }

    /// Touch an entry (update `last_access`) and clone its pool, if cached.
    fn touch(&self, key: &str) -> Option<Arc<dyn EnginePool>> {
        let mut guard = self.pools.lock().expect("pool registry poisoned");
        guard.get_mut(key).map(|e| {
            e.last_access = Instant::now();
            e.pool.clone()
        })
    }

    /// If the map is over capacity, evict least-recently-used entries until
    /// at/under cap, returning their pools to close outside the lock. Two
    /// entries are NEVER evicted, even if that leaves us over cap (correctness
    /// over the soft cap):
    ///   * a pinned entry (`tx_pins > 0`) — an open tx holds its connection;
    ///   * `protect` — the pool the current caller just created/touched (we
    ///     must not evict the very pool we're about to hand back).
    fn collect_evictions(
        guard: &mut HashMap<String, PoolEntry>,
        max_pools: usize,
        protect: &str,
    ) -> Vec<Arc<dyn EnginePool>> {
        let mut evicted = Vec::new();
        while guard.len() > max_pools {
            // Pick the LRU among evictable (unpinned, non-protected) entries.
            let victim = guard
                .iter()
                .filter(|(k, e)| e.tx_pins == 0 && k.as_str() != protect)
                .min_by_key(|(_, e)| e.last_access)
                .map(|(k, _)| k.clone());
            match victim {
                Some(key) => {
                    if let Some(entry) = guard.remove(&key) {
                        evicted.push(entry.pool);
                    }
                }
                // Every remaining entry is pinned or protected — stop.
                None => break,
            }
        }
        evicted
    }
}

#[async_trait]
impl PoolRegistry for DefaultPoolRegistry {
    async fn get_or_create(&self, mount: DatabaseMount) -> DataPlaneResult<Box<dyn EnginePool>> {
        let key = mount.effective_pool_key(self.share_pools);
        if let Some(pool) = self.touch(&key) {
            return Ok(Box::new(SharedPool(pool)));
        }

        let adapter = self.adapters.get(&mount.engine).cloned().ok_or_else(|| {
            DataPlaneError::UnsupportedCapability {
                engine: mount.engine.clone(),
                capability: "engine_adapter".to_string(),
            }
        })?;
        let engine = mount.engine.clone();
        let idle_ttl = Duration::from_millis(mount.pool_policy.idle_ttl_ms);

        let created: Arc<dyn EnginePool> = Arc::from(adapter.open_pool(mount).await?);

        let (pool, evicted) = {
            let mut guard = self.pools.lock().expect("pool registry poisoned");
            let mut was_new = false;
            let entry = guard.entry(key.clone()).or_insert_with(|| {
                was_new = true;
                PoolEntry {
                    engine,
                    pool: created,
                    last_access: Instant::now(),
                    idle_ttl,
                    tx_pins: 0,
                }
            });
            entry.last_access = Instant::now();
            let pool = entry.pool.clone();
            // Enforce the cap AFTER inserting, protecting the pool we just
            // created/touched so it's never the eviction victim.
            let evicted = Self::collect_evictions(&mut guard, self.max_pools, &key);
            if was_new {
                self.created.fetch_add(1, Ordering::Relaxed);
            }
            if !evicted.is_empty() {
                self.evicted
                    .fetch_add(evicted.len() as u64, Ordering::Relaxed);
            }
            (pool, evicted)
        };
        // Close evicted pools outside the lock (close() is async).
        for pool in evicted {
            let _ = pool.close().await;
        }
        Ok(Box::new(SharedPool(pool)))
    }

    /// Drop pools idle past their `pool_policy.idle_ttl_ms`, EXCEPT those with
    /// an in-flight transaction (`tx_pins > 0`). Idempotent; safe to call on a
    /// timer.
    async fn release_idle(&self) -> DataPlaneResult<()> {
        let now = Instant::now();
        let expired: Vec<Arc<dyn EnginePool>> = {
            let mut guard = self.pools.lock().expect("pool registry poisoned");
            let keys: Vec<String> = guard
                .iter()
                .filter(|(_, e)| {
                    e.tx_pins == 0
                        && !e.idle_ttl.is_zero()
                        && now.duration_since(e.last_access) >= e.idle_ttl
                })
                .map(|(k, _)| k.clone())
                .collect();
            keys.into_iter()
                .filter_map(|k| guard.remove(&k))
                .map(|e| e.pool)
                .collect()
        };
        if !expired.is_empty() {
            self.reaped
                .fetch_add(expired.len() as u64, Ordering::Relaxed);
        }
        for pool in expired {
            let _ = pool.close().await;
        }
        Ok(())
    }

    /// Pin the pool for `pool_key` against eviction/reaping while a transaction
    /// derived from it is in flight. No-op if the key is not (or no longer)
    /// cached — the tx still holds its own checked-out connection.
    async fn pin_tx(&self, pool_key: &str) {
        let mut guard = self.pools.lock().expect("pool registry poisoned");
        if let Some(entry) = guard.get_mut(pool_key) {
            entry.tx_pins += 1;
            entry.last_access = Instant::now();
        }
    }

    /// Release a transaction pin taken by [`pin_tx`]. Saturating at 0 so an
    /// extra unpin can never underflow.
    async fn unpin_tx(&self, pool_key: &str) {
        let mut guard = self.pools.lock().expect("pool registry poisoned");
        if let Some(entry) = guard.get_mut(pool_key) {
            entry.tx_pins = entry.tx_pins.saturating_sub(1);
        }
    }

    async fn close_mount(&self, mount_id: &str) -> DataPlaneResult<()> {
        let removed: Vec<Arc<dyn EnginePool>> = {
            let mut guard = self.pools.lock().expect("pool registry poisoned");
            let keys: Vec<String> = guard
                .iter()
                .filter(|(_, e)| e.pool.mount_id() == mount_id)
                .map(|(k, _)| k.clone())
                .collect();
            keys.into_iter()
                .filter_map(|k| guard.remove(&k))
                .map(|e| e.pool)
                .collect()
        };
        for pool in removed {
            pool.close().await?;
        }
        Ok(())
    }

    /// Rotation drain (gap G8): close + drop the pool for exactly `pool_key` so
    /// the next request rebuilds it with a freshly-resolved credential. Mirrors
    /// `close_mount`'s lock/close-outside-lock pattern. A pinned pool
    /// (`tx_pins > 0`) is LEFT in place — an open tx holds its connection; the
    /// idle reaper retires it once the tx finishes. `pool_key` embeds the
    /// credential version, so a newer version's pool is never touched.
    ///
    /// This is HALF of a rotation: a rotation = version bump (which automatically
    /// keys a new pool + resolver cache entry) PLUS two proactive hooks that
    /// retire the stale state — this `drain_pool_key` (pool) AND
    /// `EnvMountResolver::evict_cached` (cached DSN). BOTH must run or a stale
    /// cached DSN outlives the drained pool; the single caller that runs both is
    /// the server's `AppState::rotate`, exposed over `POST /v1/admin/rotate`.
    async fn drain_pool_key(&self, pool_key: &str) -> DataPlaneResult<()> {
        let removed: Option<Arc<dyn EnginePool>> = {
            let mut guard = self.pools.lock().expect("pool registry poisoned");
            match guard.get(pool_key) {
                // Pinned → leave it; the reaper handles it post-tx.
                Some(entry) if entry.tx_pins > 0 => None,
                Some(_) => guard.remove(pool_key).map(|e| e.pool),
                None => None,
            }
        };
        if let Some(pool) = removed {
            pool.close().await?;
        }
        Ok(())
    }

    async fn stats(&self) -> DataPlaneResult<Vec<PoolStats>> {
        let guard = self.pools.lock().expect("pool registry poisoned");
        Ok(guard
            .values()
            .map(|e| PoolStats {
                mount_id: e.pool.mount_id().to_string(),
                engine: e.engine.clone(),
                active_connections: 0,
                idle_connections: 0,
                waiting_requests: 0,
            })
            .collect())
    }
}

/// Delegating wrapper so the registry can hand out owned `Box<dyn EnginePool>`
/// handles that all share one underlying pool.
struct SharedPool(Arc<dyn EnginePool>);

#[async_trait]
impl EnginePool for SharedPool {
    fn mount_id(&self) -> &str {
        self.0.mount_id()
    }

    async fn execute(
        &self,
        operation: DataOperation,
        identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        self.0.execute(operation, identity).await
    }

    async fn begin(&self, request: TxBeginRequest) -> DataPlaneResult<Box<dyn TxHandle>> {
        self.0.begin(request).await
    }

    async fn close(&self) -> DataPlaneResult<()> {
        self.0.close().await
    }

    // Delegate the optional surface too — otherwise the trait default
    // (NotImplemented) wins and engine-side overrides never fire because
    // every callsite hits the registry-returned SharedPool wrapper.
    async fn execute_raw(
        &self,
        statement: data_plane_core::RawStatement,
        identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        self.0.execute_raw(statement, identity).await
    }

    async fn apply_migration(
        &self,
        request: data_plane_core::MigrationRequest,
        identity: RequestIdentity,
    ) -> DataPlaneResult<data_plane_core::MigrationResult> {
        self.0.apply_migration(request, identity).await
    }

    async fn describe_schema(
        &self,
        identity: RequestIdentity,
    ) -> DataPlaneResult<data_plane_core::SchemaDescriptor> {
        self.0.describe_schema(identity).await
    }

    async fn apply_schema_ddl(
        &self,
        ddl: data_plane_core::SchemaDdlRequest,
        identity: RequestIdentity,
    ) -> DataPlaneResult<data_plane_core::SchemaDdlResult> {
        self.0.apply_schema_ddl(ddl, identity).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use data_plane_core::{CredentialRef, EngineCapabilities, EngineHealth, PoolPolicy};
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// A no-op pool that counts how many times `close()` was called, so tests
    /// can assert eviction/reaping actually closed the underlying pool.
    struct CountingPool {
        mount_id: String,
        closed: Arc<AtomicUsize>,
    }

    #[async_trait]
    impl EnginePool for CountingPool {
        fn mount_id(&self) -> &str {
            &self.mount_id
        }
        async fn execute(
            &self,
            _op: DataOperation,
            _id: RequestIdentity,
        ) -> DataPlaneResult<DataResult> {
            Ok(DataResult::new(vec![], 0))
        }
        async fn begin(&self, _r: TxBeginRequest) -> DataPlaneResult<Box<dyn TxHandle>> {
            Err(DataPlaneError::NotImplemented {
                feature: "test".into(),
            })
        }
        async fn close(&self) -> DataPlaneResult<()> {
            self.closed.fetch_add(1, Ordering::SeqCst);
            Ok(())
        }
    }

    /// An adapter that hands out `CountingPool`s and records the shared close
    /// counter so the test can observe evictions.
    struct CountingAdapter {
        closed: Arc<AtomicUsize>,
    }

    #[async_trait]
    impl EngineAdapter for CountingAdapter {
        fn engine(&self) -> &str {
            "postgresql"
        }
        fn capabilities(&self) -> EngineCapabilities {
            EngineCapabilities::postgresql()
        }
        fn supported_ops(&self) -> &'static [data_plane_core::DataOperationKind] {
            &[]
        }
        async fn open_pool(&self, mount: DatabaseMount) -> DataPlaneResult<Box<dyn EnginePool>> {
            Ok(Box::new(CountingPool {
                mount_id: mount.id,
                closed: self.closed.clone(),
            }))
        }
        async fn health_check(&self, pool: &dyn EnginePool) -> DataPlaneResult<EngineHealth> {
            Ok(EngineHealth {
                engine: "postgresql".into(),
                mount_id: pool.mount_id().to_string(),
                status: "ok".into(),
            })
        }
    }

    fn mount_n(n: usize, idle_ttl_ms: u64) -> DatabaseMount {
        let pool_policy = PoolPolicy {
            idle_ttl_ms,
            ..PoolPolicy::default()
        };
        DatabaseMount {
            id: format!("db{n}"),
            tenant_id: format!("t{n}"),
            project_id: None,
            engine: "postgresql".into(),
            name: "n".into(),
            credential_ref: CredentialRef {
                provider: "p".into(),
                reference: format!("r{n}"),
                version: "1".into(),
            },
            pool_policy,
            capability_overrides: None,
            inline_dsn: None,
            isolation: None,
            replica_inline_dsn: None,
            read_replica_route: false,
        }
    }

    fn registry(closed: Arc<AtomicUsize>, cap: usize) -> DefaultPoolRegistry {
        DefaultPoolRegistry::with_max_pools(
            vec![Arc::new(CountingAdapter { closed }) as Arc<dyn EngineAdapter>],
            cap,
        )
    }

    #[tokio::test]
    async fn lru_evicts_oldest_when_over_cap() {
        let closed = Arc::new(AtomicUsize::new(0));
        let reg = registry(closed.clone(), 2);
        // Create 3 distinct mounts under a cap of 2 → one eviction.
        reg.get_or_create(mount_n(1, 30_000)).await.unwrap();
        reg.get_or_create(mount_n(2, 30_000)).await.unwrap();
        // Touch #1 so #2 becomes the LRU victim.
        reg.get_or_create(mount_n(1, 30_000)).await.unwrap();
        reg.get_or_create(mount_n(3, 30_000)).await.unwrap();
        assert_eq!(closed.load(Ordering::SeqCst), 1, "exactly one eviction");
        let ids: Vec<String> = reg
            .stats()
            .await
            .unwrap()
            .into_iter()
            .map(|s| s.mount_id)
            .collect();
        assert!(
            ids.contains(&"db1".to_string()),
            "recently-used db1 survives"
        );
        assert!(ids.contains(&"db3".to_string()), "newest db3 present");
        assert!(!ids.contains(&"db2".to_string()), "LRU db2 evicted");
    }

    #[tokio::test]
    async fn pinned_pool_is_excluded_from_eviction() {
        let closed = Arc::new(AtomicUsize::new(0));
        let reg = registry(closed.clone(), 1);
        reg.get_or_create(mount_n(1, 30_000)).await.unwrap();
        let key1 = mount_n(1, 30_000).pool_key();
        reg.pin_tx(&key1).await; // in-flight tx on db1
                                 // Adding db2 over cap-1 would normally evict the LRU (db1), but db1 is
                                 // pinned → db2 stays AND db1 survives (over cap, correctness wins).
        reg.get_or_create(mount_n(2, 30_000)).await.unwrap();
        assert_eq!(closed.load(Ordering::SeqCst), 0, "pinned pool not evicted");
        // Unpin, then a new insert can evict db1 (now LRU + unpinned).
        reg.unpin_tx(&key1).await;
        reg.get_or_create(mount_n(3, 30_000)).await.unwrap();
        assert!(
            closed.load(Ordering::SeqCst) >= 1,
            "eviction resumes after unpin"
        );
    }

    #[tokio::test]
    async fn release_idle_drops_expired_unpinned_pools() {
        let closed = Arc::new(AtomicUsize::new(0));
        let reg = registry(closed.clone(), 256);
        // idle_ttl = 0 would be treated as "never reap"; use 1ms and sleep.
        reg.get_or_create(mount_n(1, 1)).await.unwrap();
        tokio::time::sleep(Duration::from_millis(5)).await;
        reg.release_idle().await.unwrap();
        assert_eq!(closed.load(Ordering::SeqCst), 1, "idle pool reaped");
        assert!(reg.stats().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn release_idle_keeps_pinned_pool() {
        let closed = Arc::new(AtomicUsize::new(0));
        let reg = registry(closed.clone(), 256);
        reg.get_or_create(mount_n(1, 1)).await.unwrap();
        let key1 = mount_n(1, 1).pool_key();
        reg.pin_tx(&key1).await;
        tokio::time::sleep(Duration::from_millis(5)).await;
        reg.release_idle().await.unwrap();
        assert_eq!(closed.load(Ordering::SeqCst), 0, "pinned pool not reaped");
        reg.unpin_tx(&key1).await;
        reg.release_idle().await.unwrap();
        assert_eq!(closed.load(Ordering::SeqCst), 1, "reaped once unpinned");
    }

    // ---- gap G8: rotation drain (drain_pool_key) ----------------------------

    /// Same as `mount_n` but with an explicit credential version, so two mounts
    /// can differ ONLY in version (proving version → distinct pool_key).
    fn mount_v(n: usize, version: &str) -> DatabaseMount {
        let mut m = mount_n(n, 30_000);
        m.credential_ref.version = version.into();
        m
    }

    // t8 — a version bump yields a distinct pool_key; under a generous cap both
    // versions live and neither evicts the other.
    #[tokio::test]
    async fn t8_version_bump_yields_distinct_pool_key() {
        let closed = Arc::new(AtomicUsize::new(0));
        let reg = registry(closed.clone(), 256);
        let v1 = mount_v(1, "1");
        let v2 = mount_v(1, "2");
        assert_ne!(v1.pool_key(), v2.pool_key(), "version is part of pool_key");
        reg.get_or_create(v1).await.unwrap();
        reg.get_or_create(v2).await.unwrap();
        assert_eq!(
            closed.load(Ordering::SeqCst),
            0,
            "both versions live, no eviction"
        );
        assert_eq!(reg.stats().await.unwrap().len(), 2, "two distinct pools");
    }

    // t9 — draining one version's pool_key closes ONLY that version; the other
    // version's pool survives in stats().
    #[tokio::test]
    async fn t9_drain_pool_key_closes_only_that_version() {
        let closed = Arc::new(AtomicUsize::new(0));
        let reg = registry(closed.clone(), 256);
        let v1 = mount_v(1, "1");
        let v2 = mount_v(1, "2");
        let key_v1 = v1.pool_key();
        let key_v2 = v2.pool_key();
        reg.get_or_create(v1).await.unwrap();
        reg.get_or_create(v2).await.unwrap();
        reg.drain_pool_key(&key_v1).await.unwrap();
        assert_eq!(
            closed.load(Ordering::SeqCst),
            1,
            "exactly the drained version closed"
        );
        assert_eq!(
            reg.stats().await.unwrap().len(),
            1,
            "only the surviving version remains"
        );
        // Draining a non-existent key is a no-op (idempotent / unknown key).
        reg.drain_pool_key("no-such-key").await.unwrap();
        assert_eq!(
            closed.load(Ordering::SeqCst),
            1,
            "unknown key drain is a no-op"
        );
        // Sanity: the surviving key is v2, not v1.
        reg.drain_pool_key(&key_v2).await.unwrap();
        assert_eq!(closed.load(Ordering::SeqCst), 2, "v2 still drainable");
    }

    // B3 — scale counters track create/evict/reap lifecycle events.
    #[tokio::test]
    async fn scale_counters_track_lifecycle() {
        let closed = Arc::new(AtomicUsize::new(0));
        let reg = registry(closed.clone(), 2);
        reg.get_or_create(mount_n(1, 1)).await.unwrap();
        reg.get_or_create(mount_n(2, 30_000)).await.unwrap();
        reg.get_or_create(mount_n(1, 1)).await.unwrap(); // cache hit — no create
        reg.get_or_create(mount_n(3, 30_000)).await.unwrap(); // over cap → evict
        let (created, evicted, reaped, open) = reg.scale_counters();
        assert_eq!(created, 3, "three distinct pools created");
        assert_eq!(evicted, 1, "one LRU eviction");
        assert_eq!(reaped, 0);
        assert_eq!(open, 2, "at cap");
        // Reap the idle (1ms TTL) pool — mount 1 was evicted? mount 2 was LRU
        // victim (mount 1 touched last). Whichever survives with 1ms TTL reaps.
        tokio::time::sleep(Duration::from_millis(5)).await;
        reg.release_idle().await.unwrap();
        let (_, _, reaped_after, _) = reg.scale_counters();
        assert!(reaped_after >= 1, "idle pool reaped is counted");
    }

    // t10 — drain skips a pinned pool (open tx); after unpin it drains.
    #[tokio::test]
    async fn t10_drain_pool_key_skips_pinned() {
        let closed = Arc::new(AtomicUsize::new(0));
        let reg = registry(closed.clone(), 256);
        let v1 = mount_v(1, "1");
        let key = v1.pool_key();
        reg.get_or_create(v1).await.unwrap();
        reg.pin_tx(&key).await; // in-flight tx
        reg.drain_pool_key(&key).await.unwrap();
        assert_eq!(closed.load(Ordering::SeqCst), 0, "pinned pool not drained");
        assert_eq!(
            reg.stats().await.unwrap().len(),
            1,
            "pinned pool still present"
        );
        reg.unpin_tx(&key).await;
        reg.drain_pool_key(&key).await.unwrap();
        assert_eq!(closed.load(Ordering::SeqCst), 1, "drained once unpinned");
        assert!(
            reg.stats().await.unwrap().is_empty(),
            "pool removed after drain"
        );
    }
}
