/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   metrics.rs                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:33:09 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:33:10 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Dependency-free Prometheus metrics for the data plane (wiki/04 §6, gap G7).
//!
//! Kept consistent with the Go control plane's `baas_*` exposition and without
//! pulling the `prometheus` crate: the router only needs request counts, uptime
//! and per-mount pool saturation, which std atomics + the existing
//! `PoolRegistry::stats()` already provide.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Instant;

/// B5 per-tenant observability (Pillar 3) — hard in-process cap on the number of
/// distinct tenant_ids that get their own `baas_http_requests_total` series. The
/// first N=512 distinct sanitized tenant_ids each get a series; every tenant
/// beyond the cap folds into a single sentinel series `tenant_id="_over_cap"`.
/// Ceiling = N+1 tenant_id-labeled series per process, INDEPENDENT of tenant
/// count → provably bounded at 10K+ tenants (the only safe way a tenant_id label
/// touches Prometheus). Never applied to any histogram or any other counter.
const TENANT_COUNTER_CAP: usize = 512;
/// Sentinel label value for tenants beyond the cap. A request for any tenant the
/// bounded set is already full for is counted here, so totals never silently drop.
const TENANT_OVER_CAP: &str = "_over_cap";

/// Process-wide request counters. Lives in `AppState` behind an `Arc`.
pub struct Metrics {
    start: Instant,
    total: AtomicU64,
    c2xx: AtomicU64,
    c4xx: AtomicU64,
    c5xx: AtomicU64,
    // Scale counters (B3): verify/mount cache effectiveness. At 10K tenants
    // the hit rate is what stands between every request and a tenant-control
    // Argon2id round-trip — the scale experiments read these from /metrics.
    verify_hit: AtomicU64,
    verify_miss: AtomicU64,
    mount_hit: AtomicU64,
    mount_miss: AtomicU64,
    // D-write-tail: background outbox emission. The write path used to `.await`
    // the outbox INSERT inline (insert p99 583 ms vs read 3.4 ms); these track
    // the async queue so the latency win is observable and queue saturation
    // (`dropped`) is never silent.
    outbox_enqueued: AtomicU64,
    outbox_written: AtomicU64,
    outbox_dropped: AtomicU64,
    outbox_failed: AtomicU64,
    // B5 per-tenant observability (Pillar 3, OPTIONAL, default OFF) — a BOUNDED
    // per-tenant request counter. Keyed by the SANITIZED (`escape_label`) tenant
    // id; the map is capped at `TENANT_COUNTER_CAP` distinct tenants, with every
    // tenant past the cap folded into the single `TENANT_OVER_CAP` sentinel — so
    // the map (and the emitted series) can never exceed N+1 entries regardless of
    // tenant count. Only ever written when `config.tenant_obs_counter` is ON, so
    // at parity this stays empty and is never locked → byte-identical `/metrics`.
    // A `Mutex<HashMap>` (not per-tenant atomics) because the cap check + insert
    // must be atomic together; the lock is taken only on the OPT-IN counter path,
    // never on the parity hot path. Holds at most N+1 `AtomicU64`s ≈ a few KiB.
    tenant_requests: Mutex<HashMap<String, AtomicU64>>,
}

impl Default for Metrics {
    fn default() -> Self {
        Self {
            start: Instant::now(),
            total: AtomicU64::new(0),
            c2xx: AtomicU64::new(0),
            c4xx: AtomicU64::new(0),
            c5xx: AtomicU64::new(0),
            verify_hit: AtomicU64::new(0),
            verify_miss: AtomicU64::new(0),
            mount_hit: AtomicU64::new(0),
            mount_miss: AtomicU64::new(0),
            outbox_enqueued: AtomicU64::new(0),
            outbox_written: AtomicU64::new(0),
            outbox_dropped: AtomicU64::new(0),
            outbox_failed: AtomicU64::new(0),
            tenant_requests: Mutex::new(HashMap::new()),
        }
    }
}

impl Metrics {
    /// Record one finished request, bucketed by HTTP status class.
    pub fn record(&self, status: u16) {
        self.total.fetch_add(1, Ordering::Relaxed);
        let bucket = match status / 100 {
            2 => &self.c2xx,
            4 => &self.c4xx,
            5 => &self.c5xx,
            _ => return,
        };
        bucket.fetch_add(1, Ordering::Relaxed);
    }

    #[must_use]
    pub fn uptime_secs(&self) -> u64 {
        self.start.elapsed().as_secs()
    }

    /// (total, 2xx, 4xx, 5xx)
    #[must_use]
    pub fn snapshot(&self) -> (u64, u64, u64, u64) {
        (
            self.total.load(Ordering::Relaxed),
            self.c2xx.load(Ordering::Relaxed),
            self.c4xx.load(Ordering::Relaxed),
            self.c5xx.load(Ordering::Relaxed),
        )
    }

    /// Record a verify-cache lookup outcome.
    pub fn record_verify_cache(&self, hit: bool) {
        let counter = if hit {
            &self.verify_hit
        } else {
            &self.verify_miss
        };
        counter.fetch_add(1, Ordering::Relaxed);
    }

    /// Record a mount-cache lookup outcome.
    pub fn record_mount_cache(&self, hit: bool) {
        let counter = if hit {
            &self.mount_hit
        } else {
            &self.mount_miss
        };
        counter.fetch_add(1, Ordering::Relaxed);
    }

    /// (verify_hit, verify_miss, mount_hit, mount_miss)
    #[must_use]
    pub fn cache_snapshot(&self) -> (u64, u64, u64, u64) {
        (
            self.verify_hit.load(Ordering::Relaxed),
            self.verify_miss.load(Ordering::Relaxed),
            self.mount_hit.load(Ordering::Relaxed),
            self.mount_miss.load(Ordering::Relaxed),
        )
    }

    /// One mutation accepted onto the background outbox queue.
    pub fn record_outbox_enqueued(&self) {
        self.outbox_enqueued.fetch_add(1, Ordering::Relaxed);
    }

    /// `n` events durably written to `outbox_events` by the background worker.
    pub fn record_outbox_written(&self, n: u64) {
        self.outbox_written.fetch_add(n, Ordering::Relaxed);
    }

    /// One mutation dropped because the queue was full (back-pressure shed). A
    /// non-zero value means the worker can't keep up — scale it or widen the queue.
    pub fn record_outbox_dropped(&self) {
        self.outbox_dropped.fetch_add(1, Ordering::Relaxed);
    }

    /// One background outbox INSERT failed (the write it describes already
    /// committed — parity with the query-router's `.catch(warn)` posture).
    pub fn record_outbox_failed(&self) {
        self.outbox_failed.fetch_add(1, Ordering::Relaxed);
    }

    /// (enqueued, written, dropped, failed)
    #[must_use]
    pub fn outbox_snapshot(&self) -> (u64, u64, u64, u64) {
        (
            self.outbox_enqueued.load(Ordering::Relaxed),
            self.outbox_written.load(Ordering::Relaxed),
            self.outbox_dropped.load(Ordering::Relaxed),
            self.outbox_failed.load(Ordering::Relaxed),
        )
    }

    /// B5 per-tenant observability (Pillar 3) — record ONE request for `tenant_id`
    /// into the BOUNDED per-tenant counter. Caller MUST gate this on
    /// `config.tenant_obs_counter` (it is never called at parity). The label value
    /// is sanitized with [`escape_label`] before it is ever used as a key/series
    /// so an attacker-controlled tenant_id cannot break the exposition or smuggle
    /// extra labels. Cap discipline: a known tenant (or the sentinel) just
    /// increments; a NEW tenant is admitted only while the map holds fewer than
    /// `TENANT_COUNTER_CAP` entries — past the cap it folds into the single
    /// `TENANT_OVER_CAP` sentinel, so the map (and the series count) is bounded at
    /// N+1 regardless of how many distinct tenants are seen.
    pub fn record_tenant_request(&self, tenant_id: &str) {
        let label = escape_label(tenant_id);
        let Ok(mut map) = self.tenant_requests.lock() else {
            return; // poisoned lock: drop the data-point, never panic the handler
        };
        if let Some(counter) = map.get(&label) {
            counter.fetch_add(1, Ordering::Relaxed);
            return;
        }
        // Unknown tenant: admit only if there's room under the cap; otherwise the
        // overflow folds into the sentinel (which is itself one of the ≤ N+1 keys).
        if map.len() < TENANT_COUNTER_CAP {
            map.insert(label, AtomicU64::new(1));
        } else {
            map.entry(TENANT_OVER_CAP.to_string())
                .or_insert_with(|| AtomicU64::new(0))
                .fetch_add(1, Ordering::Relaxed);
        }
    }

    /// B5 per-tenant observability (Pillar 3) — snapshot the bounded per-tenant
    /// counter as `(escaped_tenant_id, count)` pairs for the `/metrics` exposition.
    /// Returns at most N+1 entries (the cap). Empty at parity (the counter path is
    /// never written when the flag is OFF), so the exposition emits no extra lines.
    /// The values are ALREADY `escape_label`-sanitized (they are the stored keys),
    /// so the exposition emits them verbatim inside the quotes.
    #[must_use]
    pub fn tenant_requests_snapshot(&self) -> Vec<(String, u64)> {
        match self.tenant_requests.lock() {
            Ok(map) => map
                .iter()
                .map(|(k, v)| (k.clone(), v.load(Ordering::Relaxed)))
                .collect(),
            Err(_) => Vec::new(),
        }
    }
}

/// Escape a Prometheus label value (`\`, `"`, newline).
#[must_use]
pub fn escape_label(v: &str) -> String {
    v.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_buckets_by_status_class() {
        let m = Metrics::default();
        m.record(200);
        m.record(201);
        m.record(404);
        m.record(503);
        m.record(101); // 1xx ignored by the class buckets but counted in total
        let (total, c2, c4, c5) = m.snapshot();
        assert_eq!(total, 5);
        assert_eq!(c2, 2);
        assert_eq!(c4, 1);
        assert_eq!(c5, 1);
    }

    #[test]
    fn escape_label_handles_specials() {
        assert_eq!(escape_label(r#"a"b\c"#), r#"a\"b\\c"#);
        assert_eq!(escape_label("tenant/proj/db/pg/1"), "tenant/proj/db/pg/1");
    }

    #[test]
    fn cache_counters_split_hit_miss() {
        let m = Metrics::default();
        m.record_verify_cache(true);
        m.record_verify_cache(true);
        m.record_verify_cache(false);
        m.record_mount_cache(false);
        let (vh, vm, mh, mm) = m.cache_snapshot();
        assert_eq!((vh, vm, mh, mm), (2, 1, 0, 1));
    }

    #[test]
    fn outbox_counters_track_queue_lifecycle() {
        let m = Metrics::default();
        m.record_outbox_enqueued();
        m.record_outbox_enqueued();
        m.record_outbox_written(2);
        m.record_outbox_dropped();
        m.record_outbox_failed();
        let (enq, wr, drop, fail) = m.outbox_snapshot();
        assert_eq!((enq, wr, drop, fail), (2, 2, 1, 1));
    }

    // B5 Pillar 3: at parity (never recorded) the bounded counter is empty, so the
    // exposition emits zero tenant_id lines — byte-parity with today.
    #[test]
    fn tenant_counter_empty_until_recorded() {
        let m = Metrics::default();
        assert!(m.tenant_requests_snapshot().is_empty());
    }

    // Repeated requests for the same tenant accumulate on ONE series; distinct
    // tenants each get their own series; the label value is escape_label-sanitized.
    #[test]
    fn tenant_counter_accumulates_and_sanitizes() {
        let m = Metrics::default();
        m.record_tenant_request("tenant-a");
        m.record_tenant_request("tenant-a");
        m.record_tenant_request("tenant-b");
        m.record_tenant_request(r#"ev"il"#); // must be escaped to ev\"il
        let snap: std::collections::HashMap<String, u64> =
            m.tenant_requests_snapshot().into_iter().collect();
        assert_eq!(snap.get("tenant-a"), Some(&2));
        assert_eq!(snap.get("tenant-b"), Some(&1));
        assert_eq!(snap.get(r#"ev\"il"#), Some(&1));
        assert!(!snap.contains_key("_over_cap"));
    }

    // The cap holds: flooding > N distinct tenants yields at most N+1 series, and
    // the overflow folds into the single `_over_cap` sentinel (no dropped counts).
    #[test]
    fn tenant_counter_caps_at_n_plus_one() {
        let m = Metrics::default();
        let flood = TENANT_COUNTER_CAP + 50;
        for i in 0..flood {
            m.record_tenant_request(&format!("tenant-{i}"));
        }
        let snap = m.tenant_requests_snapshot();
        // Ceiling = N+1 series regardless of how many distinct tenants were seen.
        assert!(
            snap.len() <= TENANT_COUNTER_CAP + 1,
            "series count {} exceeded N+1 ({})",
            snap.len(),
            TENANT_COUNTER_CAP + 1
        );
        let by_label: std::collections::HashMap<String, u64> = snap.into_iter().collect();
        // The 50 over-cap tenants all folded into the sentinel.
        assert_eq!(by_label.get(TENANT_OVER_CAP), Some(&50));
    }
}
