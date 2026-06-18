//! `AppState` runtime operations: credential rotation, cache eviction, the reaper
//! tick, and the flag/accessor surface `server::run` reads. Split out of
//! `state.rs` so the state module stays focused on the struct + its constructor;
//! these methods access `AppState`'s `pub(super)` fields, which are visible
//! across the sibling modules of `routes`.
use data_plane_core::PoolRegistry;
use data_plane_pool::DefaultPoolRegistry;
use std::sync::Arc;

use super::state::AppState;

impl AppState {
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
