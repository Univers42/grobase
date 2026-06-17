/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   usage.rs                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Track-B metering for the realtime plane (slice B1d) — the
//! `realtime.connection.seconds` usage counter.
//!
//! This MIRRORS the data-plane producer
//! (`data-plane-router/crates/data-plane-server/src/usage.rs`): an in-process
//! `Mutex<HashMap<(tenant, metric), u64>>` aggregator + a background flusher on
//! a `tokio::time::interval` that drains the CUMULATIVE per-`(tenant, metric)`
//! window total ONCE per window and `XADD`s the FROZEN envelope to the single
//! Redis stream `usage.events`. The Go control-plane consumer (B1b) ingests it
//! AS-IS — so the envelope, the `idempotency_key`, and the `window_start_ms`
//! math here are byte-for-byte the data-plane producer's.
//!
//! ## Where it is recorded
//!
//! On WebSocket connection CLOSE the gateway computes the connection lifetime in
//! whole seconds and `record`s it for the connection's authenticated platform
//! user/tenant (the same identity it stamps as `EventSource.id` on publishes —
//! `AuthClaims::sub`). The metric is the constant [`CONNECTION_SECONDS`].
//!
//! ## Cumulative window aggregation (NOT per-event emit)
//!
//! Because the `idempotency_key` buckets on the WINDOW START and the consumer
//! does `ON CONFLICT (idempotency_key) DO NOTHING`, every event inside one
//! window MUST be summed and the running total flushed ONCE — a per-event XADD
//! would share one key per window and the consumer would keep only the first
//! (massive undercount). [`UsageAggregate::record`] saturating-adds; the flusher
//! [`Usage::spawn_flusher`] drains+resets each window and emits the total.
//!
//! ## Sub-flag (`REALTIME_METERING`, default OFF) = byte-parity
//!
//! When OFF, the gateway never constructs a [`Usage`] handle (`AppState.usage`
//! is `None`), so the close path never calls `record`, the flusher is never
//! spawned (not even an idle timer), and no Redis connection is ever opened:
//! the connect/close path is byte-identical to today, and `usage.events` stays
//! empty for identical traffic.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::Mutex;
use std::time::Duration;

use sha2::{Digest, Sha256};
use tracing::warn;

/// The single Redis stream all usage windows are XADD'd to (FROZEN contract,
/// shared with the data-plane producer). `metric` is a FIELD on each entry, not
/// part of the key — one stream, many metrics.
pub const USAGE_STREAM_KEY: &str = "usage.events";

/// The metric name for connection lifetime, in whole seconds. Follows the
/// `<noun>.<noun>.<unit>` convention of the data-plane metrics
/// (`query.count` / `query.rows` / `write.rows`).
pub const CONNECTION_SECONDS: &str = "realtime.connection.seconds";

/// In-process usage aggregate keyed `(tenant_id, metric)` → summed `qty`.
///
/// Same `Mutex<HashMap>` shape as the data-plane producer's aggregate. The metric
/// is a `&'static str` (the gateway only meters one metric today) so a key carries
/// no per-event allocation beyond the tenant string.
#[derive(Default)]
pub struct UsageAggregate {
    counters: Mutex<HashMap<(String, &'static str), u64>>,
}

impl UsageAggregate {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Record `qty` of `metric` for `tenant`. Cheap, non-blocking `+=` under a
    /// short critical section (no I/O, no await). Saturating so a runaway count
    /// can never panic. `qty == 0` is a no-op (an instant connect/close emits
    /// nothing, preserving parity for a degenerate window).
    pub fn record(&self, tenant: &str, metric: &'static str, qty: u64) {
        if qty == 0 {
            return;
        }
        // Recover a poisoned lock rather than panic (workspace lints deny panic).
        // The guard lives only inside this statement's temporary scope, so the
        // critical section is a single saturating `+=` (no I/O, no await) — the
        // tight scope clippy::significant_drop_tightening wants.
        self.counters
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .entry((tenant.to_string(), metric))
            .and_modify(|v| *v = v.saturating_add(qty))
            .or_insert(qty);
    }

    /// Drain every non-zero `(tenant, metric)` entry, returning its window total
    /// and REMOVING it from the map (reset for the next window, bound the map).
    #[must_use]
    pub fn drain(&self) -> Vec<(String, &'static str, u64)> {
        let mut map = self
            .counters
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if map.is_empty() {
            return Vec::new();
        }
        // Swap with an empty map: read+reset in one critical section so a
        // concurrent `record` either lands in the old (drained) map before the
        // swap or the fresh one after — never lost mid-swap.
        let taken = std::mem::take(&mut *map);
        drop(map);
        taken
            .into_iter()
            .filter(|(_, qty)| *qty > 0)
            .map(|((t, m), qty)| (t, m, qty))
            .collect()
    }

    /// Number of `(tenant, metric)` pairs currently tracked — the gauge a gate
    /// can read to prove OFF == 0 entries.
    #[must_use]
    pub fn tracked(&self) -> usize {
        self.counters
            .lock()
            .map_or(0, |m| m.len())
    }
}

/// The FROZEN on-the-wire envelope for one `(tenant, metric)` window.
///
/// Every field is the exact string the consumer reads off `usage.events`;
/// [`UsageEnvelope::build`] is the single place the contract is computed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UsageEnvelope {
    pub tenant_id: String,
    pub metric: String,
    pub qty: String,
    pub ts: String,
    pub window_ms: String,
    pub idempotency_key: String,
}

impl UsageEnvelope {
    /// Build the FROZEN envelope for one drained `(tenant, metric, qty)` window.
    /// `now_ms` is the flush instant (unix ms); `window_ms` the flush cadence.
    /// Pure (no I/O) so the contract test and the live XADD share one path.
    #[must_use]
    pub fn build(tenant: &str, metric: &str, qty: u64, now_ms: u64, window_ms: u64) -> Self {
        let window_start = window_start_ms(now_ms, window_ms);
        Self {
            tenant_id: tenant.to_string(),
            metric: metric.to_string(),
            qty: qty.to_string(),
            ts: now_ms.to_string(),
            window_ms: window_ms.to_string(),
            idempotency_key: idempotency_key(tenant, metric, window_start),
        }
    }
}

/// The window-start the `idempotency_key` buckets on: the largest multiple of
/// `window_ms` not exceeding `ts`.
///
/// `window_ms == 0` degrades to the raw `ts` rather than dividing by zero.
/// Byte-identical to the data-plane producer.
#[must_use]
pub const fn window_start_ms(ts: u64, window_ms: u64) -> u64 {
    if window_ms == 0 {
        return ts;
    }
    ts - (ts % window_ms)
}

/// Compute the FROZEN `idempotency_key`: lower-hex sha256 of
/// `"<tenant_id>|<metric>|<window_start_ms>"`.
///
/// Byte-for-byte the data-plane producer's key — the Go consumer dedups across
/// the producer/consumer boundary on this exact value. `sha2` is already in the
/// workspace lockfile.
#[must_use]
pub fn idempotency_key(tenant: &str, metric: &str, window_start: u64) -> String {
    let mut hasher = Sha256::new();
    hasher.update(tenant.as_bytes());
    hasher.update(b"|");
    hasher.update(metric.as_bytes());
    hasher.update(b"|");
    hasher.update(window_start.to_string().as_bytes());
    let out = hasher.finalize();
    let mut hex = String::with_capacity(64);
    for b in out {
        use std::fmt::Write;
        let _ = write!(hex, "{b:02x}");
    }
    hex
}

/// Current unix time in milliseconds. Falls back to 0 on a pre-epoch clock so
/// the flusher can never panic on a `SystemTime` error.
fn now_unix_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or(0)
}

/// The metering handle wired into `AppState` (as `Option<Usage>`).
///
/// Holds the shared aggregate and the durable Redis sink. Constructed ONLY when
/// the `REALTIME_METERING` sub-flag is ON; at parity `AppState.usage` is `None`
/// and nothing here is ever reached.
#[derive(Clone)]
pub struct Usage {
    aggregate: Arc<UsageAggregate>,
    /// Durable `usage.events` sink (producer side of the FROZEN B1b contract).
    /// `None` ⇒ no Redis URL configured (tracing-only would still work but the
    /// gate requires the durable path, so the URL is always set when metering
    /// is ON).
    stream: Option<Arc<UsageStream>>,
}

impl Default for Usage {
    fn default() -> Self {
        Self::new()
    }
}

impl Usage {
    #[must_use]
    pub fn new() -> Self {
        Self {
            aggregate: Arc::new(UsageAggregate::new()),
            stream: None,
        }
    }

    /// Configure the durable Redis stream sink from a URL. An empty/blank URL
    /// leaves the handle tracing-only. The connection is lazy (opened on the
    /// first flush), so an unreachable Redis at boot never blocks startup.
    #[must_use]
    pub fn with_stream_url(mut self, url: &str) -> Self {
        if !url.trim().is_empty() {
            self.stream = Some(Arc::new(UsageStream::new(url.to_string())));
        }
        self
    }

    /// Record one metering event for `tenant`. Cheap + non-blocking.
    pub fn record(&self, tenant: &str, metric: &'static str, qty: u64) {
        self.aggregate.record(tenant, metric, qty);
    }

    /// Pairs currently tracked (test/observability).
    #[must_use]
    pub fn tracked(&self) -> usize {
        self.aggregate.tracked()
    }

    /// Spawn the background flusher: every `flush_ms`, drain non-zero
    /// `(tenant, metric)` aggregates and, per entry, `XADD` the FROZEN envelope
    /// to `usage.events` (best-effort). Spawned ONLY when metering is ON, so OFF
    /// adds not even an idle timer (parity). `flush_ms` is clamped to ≥1.
    pub fn spawn_flusher(&self, flush_ms: u64) {
        let aggregate = self.aggregate.clone();
        let stream = self.stream.clone();
        let period = Duration::from_millis(flush_ms.max(1));
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(period);
            ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                ticker.tick().await;
                let windows = drain_windows(&aggregate, flush_ms);
                if let Some(stream) = stream.as_ref() {
                    stream.xadd_windows(&windows).await;
                }
            }
        });
    }
}

/// Drain the aggregate into FROZEN envelopes for XADD. No-op (empty vec) when
/// nothing was recorded — a quiet flusher allocates nothing.
fn drain_windows(aggregate: &UsageAggregate, flush_ms: u64) -> Vec<UsageEnvelope> {
    let drained = aggregate.drain();
    if drained.is_empty() {
        return Vec::new();
    }
    let now_ms = now_unix_ms();
    drained
        .into_iter()
        .map(|(tenant, metric, qty)| UsageEnvelope::build(&tenant, metric, qty, now_ms, flush_ms))
        .collect()
}

/// Durable producer — a lazily-connected Redis client that `XADD`s usage windows
/// to the FROZEN `usage.events` stream. Connection is a `ConnectionManager`
/// (auto-reconnecting), opened on first use via a `OnceCell`.
struct UsageStream {
    url: String,
    conn: tokio::sync::OnceCell<redis::aio::ConnectionManager>,
}

impl UsageStream {
    fn new(url: String) -> Self {
        Self {
            url,
            conn: tokio::sync::OnceCell::new(),
        }
    }

    /// XADD each window to `usage.events`, best-effort. A connect/XADD failure is
    /// logged and dropped — never panics, never blocks the next flush. Each entry
    /// carries the FROZEN envelope fields; the consumer dedups on
    /// `idempotency_key`.
    async fn xadd_windows(&self, windows: &[UsageEnvelope]) {
        if windows.is_empty() {
            return;
        }
        let mgr = self
            .conn
            .get_or_try_init(|| async {
                let client = redis::Client::open(self.url.as_str())?;
                redis::aio::ConnectionManager::new(client).await
            })
            .await;
        let Ok(mgr) = mgr else {
            warn!(
                target: "usage",
                count = windows.len(),
                "realtime metering redis connect failed — usage windows dropped (best-effort)"
            );
            return;
        };
        let mut conn = mgr.clone();
        for env in windows {
            let res: redis::RedisResult<String> = redis::cmd("XADD")
                .arg(USAGE_STREAM_KEY)
                .arg("*")
                .arg("tenant_id")
                .arg(&env.tenant_id)
                .arg("metric")
                .arg(&env.metric)
                .arg("qty")
                .arg(&env.qty)
                .arg("ts")
                .arg(&env.ts)
                .arg("window_ms")
                .arg(&env.window_ms)
                .arg("idempotency_key")
                .arg(&env.idempotency_key)
                .query_async(&mut conn)
                .await;
            if let Err(e) = res {
                warn!(
                    target: "usage",
                    tenant = %env.tenant_id,
                    metric = %env.metric,
                    "realtime metering XADD failed — usage window dropped (best-effort): {e}"
                );
            }
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    // The CRITICAL property: N events for ONE (tenant, metric) in ONE window
    // sum to ONE drained total (NOT 1, NOT N rows) — the whole reason for
    // cumulative aggregation. A second drain is empty (reset, no double-count).
    #[test]
    fn record_sums_per_window_then_resets() {
        let agg = UsageAggregate::new();
        // Three connections for one tenant of durations 4, 7, 5 → sum 16.
        agg.record("t1", CONNECTION_SECONDS, 4);
        agg.record("t1", CONNECTION_SECONDS, 7);
        agg.record("t1", CONNECTION_SECONDS, 5);
        assert_eq!(agg.tracked(), 1, "one (tenant, metric) pair");

        let drained = agg.drain();
        assert_eq!(
            drained,
            vec![("t1".to_string(), CONNECTION_SECONDS, 16)],
            "ONE window total == SUM of the N events, never 1 or duplicated"
        );
        assert_eq!(agg.tracked(), 0, "drain reset the aggregate");
        assert!(agg.drain().is_empty(), "second drain empty (no double-count)");
    }

    #[test]
    fn zero_qty_records_nothing() {
        let agg = UsageAggregate::new();
        agg.record("t1", CONNECTION_SECONDS, 0);
        assert_eq!(agg.tracked(), 0);
        assert!(agg.drain().is_empty());
    }

    #[test]
    fn tenants_are_isolated() {
        let agg = UsageAggregate::new();
        agg.record("a", CONNECTION_SECONDS, 9);
        agg.record("b", CONNECTION_SECONDS, 1);
        let mut drained = agg.drain();
        drained.sort();
        assert_eq!(
            drained,
            vec![
                ("a".to_string(), CONNECTION_SECONDS, 9),
                ("b".to_string(), CONNECTION_SECONDS, 1),
            ]
        );
    }

    #[test]
    fn window_start_ms_buckets_to_window() {
        assert_eq!(window_start_ms(123_456, 60_000), 120_000);
        assert_eq!(window_start_ms(120_000, 60_000), 120_000);
        assert_eq!(window_start_ms(180_001, 60_000), 180_000);
        assert_eq!(window_start_ms(123_456, 0), 123_456);
    }

    // The idempotency_key MUST equal the data-plane producer's: lower-hex
    // sha256("<tenant>|<metric>|<window_start_ms>"). Pinned against an
    // independently-recomputed golden so a separator/order change diverges here.
    #[test]
    fn idempotency_key_matches_frozen_contract() {
        let k = idempotency_key("t1", CONNECTION_SECONDS, 120_000);
        assert_eq!(k.len(), 64);
        assert!(k.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
        let preimage = format!("t1|{CONNECTION_SECONDS}|120000");
        let mut hasher = Sha256::new();
        hasher.update(preimage.as_bytes());
        let mut golden = String::with_capacity(64);
        for b in hasher.finalize() {
            use std::fmt::Write;
            let _ = write!(golden, "{b:02x}");
        }
        assert_eq!(k, golden, "key == sha256_hex(\"tenant|metric|window_start_ms\")");
    }

    #[test]
    fn envelope_is_window_bucketed() {
        let env = UsageEnvelope::build("t1", CONNECTION_SECONDS, 42, 123_456, 60_000);
        assert_eq!(env.tenant_id, "t1");
        assert_eq!(env.metric, CONNECTION_SECONDS);
        assert_eq!(env.qty, "42");
        assert_eq!(env.ts, "123456");
        assert_eq!(env.window_ms, "60000");
        assert_eq!(
            env.idempotency_key,
            idempotency_key("t1", CONNECTION_SECONDS, 120_000),
            "key buckets on window START, not raw ts"
        );
        // A second flush LATER in the SAME window ⇒ identical key (dedup).
        let later = UsageEnvelope::build("t1", CONNECTION_SECONDS, 99, 150_000, 60_000);
        assert_eq!(later.idempotency_key, env.idempotency_key);
        // The NEXT window ⇒ a fresh key (new billable bucket).
        let next = UsageEnvelope::build("t1", CONNECTION_SECONDS, 1, 181_000, 60_000);
        assert_ne!(next.idempotency_key, env.idempotency_key);
    }

    #[test]
    fn handle_records_via_shared_aggregate() {
        let usage = Usage::new();
        assert_eq!(usage.tracked(), 0);
        usage.record("t1", CONNECTION_SECONDS, 7);
        usage.record("t1", CONNECTION_SECONDS, 3);
        assert_eq!(usage.tracked(), 1);
        assert_eq!(usage.aggregate.drain(), vec![("t1".to_string(), CONNECTION_SECONDS, 10)]);
    }

    #[test]
    fn stream_sink_is_opt_in_via_nonempty_url() {
        assert!(Usage::new().stream.is_none(), "no sink by default");
        assert!(Usage::new().with_stream_url("  ").stream.is_none(), "blank URL ⇒ no sink");
        assert!(Usage::new().with_stream_url("redis://127.0.0.1:6379").stream.is_some());
    }
}
