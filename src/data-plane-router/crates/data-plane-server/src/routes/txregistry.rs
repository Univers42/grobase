/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   txregistry.rs                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:32:47 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:32:48 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! The in-`AppState` transaction registry: active multi-statement transaction
//! handles keyed by `tx_id`, with pool-pin bookkeeping and TTL reaping. Split
//! out of `state.rs` so the shared `AppState` module stays focused on
//! construction + accessors; `state` re-exports `TransactionRegistry` so its
//! `super::state::TransactionRegistry` path is unchanged.
use data_plane_core::TxHandle;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime};
use tokio::sync::Mutex;

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
