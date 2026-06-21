/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   usage.rs                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:33:48 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:33:50 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Track-B metering (B1a + B1b) — per-tenant usage counters in the data plane.
//!
//! The rate limiter caps *how fast* a tenant may go; metering records *how much*
//! it actually did, so the same per-tenant dimension the tier already caps
//! (`rps`/`max_rows`/`write`) gets its measured count. This is the **count** to
//! the limit's **cap** — the missing other half of each tier knob.
//!
//! ## Shape (mirrors `ratelimit.rs` + `outbox.rs`)
//!
//! - **Aggregate:** an in-process `Mutex<HashMap<(tenant, metric), u64>>` — the
//!   SAME concurrency shape the per-tenant token bucket uses (`ratelimit.rs`), so
//!   it adds no new dependency. [`UsageAggregate::record`] is a cheap, non-
//!   blocking `+=` taken on the request path only when metering is ON; at parity
//!   (flag OFF) the call site short-circuits before `record` is ever reached.
//! - **Flush:** a background task on a `tokio::time::interval` (the `outbox.rs`
//!   `into_background` precedent) drains the non-zero entries every `flush_ms`
//!   and emits ONE structured `usage` tracing event per `(tenant, metric)`
//!   window — then resets that entry to zero. Draining-and-resetting bounds the
//!   map and makes each event a discrete window total (not a running sum).
//!
//! ## Sink (B1a tracing + B1b durable stream)
//!
//! - **B1a SINK:** the structured `tracing::info!(target: "usage", …)` event —
//!   routable by the existing tracing/promtail pipeline exactly like the `audit`
//!   target. Always emitted by the flusher when metering is ON.
//! - **B1b SINK (durable, this slice):** when a metering Redis URL is configured
//!   AND the `ratelimit-redis` feature is compiled (it is in the default image),
//!   the flusher ALSO `XADD`s one entry per drained `(tenant, metric, qty)` to
//!   the single Redis stream `usage.events` with the **frozen envelope** — the
//!   producer side of the B1b producer/consumer boundary. The XADD is
//!   best-effort and OFF the request path (it runs in the background flusher): a
//!   Redis error is logged and dropped, never panics, never blocks the request
//!   nor the next flush window. The Go control-plane ingest (B1b consumer) reads
//!   `usage.events` and idempotently UPSERTs into `public.tenant_usage`.
//!
//! ## Frozen contract (both planes MUST match — producer/consumer boundary)
//!
//! - Stream key `usage.events` (single stream; `metric` is a field).
//! - Entry fields: `tenant_id` · `metric` (`query.count`|`query.rows`|
//!   `write.rows`) · `qty` (integer as string) · `ts` (unix ms as string) ·
//!   `window_ms` (string) · `idempotency_key` (= lower-hex sha256 of
//!   `"<tenant_id>|<metric>|<window_start_ms>"`, where
//!   `window_start_ms = ts - (ts mod window_ms)`).
//! - Re-delivering an identical window (same `idempotency_key`) MUST NOT double-
//!   count: the consumer's INSERT … ON CONFLICT (idempotency_key) DO NOTHING.
//!
//! ## Parity (flag OFF)
//!
//! With metering OFF the request path never calls `record`, so the map stays
//! empty and the flusher is never spawned (`server.rs` only spawns it when
//! metering is ON) → zero counters, zero tracing events, zero XADD. Observably
//! byte-parity with today; the B1b durable path adds nothing at parity.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::Mutex;
use std::time::Duration;

use sha2::{Digest, Sha256};

/// The single Redis stream all usage windows are XADD'd to (frozen contract).
/// `metric` is a field on each entry, not part of the key — one stream, many
/// metrics — so the consumer subscribes to exactly one stream.
pub const USAGE_STREAM_KEY: &str = "usage.events";

/// In-process usage aggregate keyed `(tenant_id, metric)` → summed `qty`. Cheap:
/// one `u64` per active `(tenant, metric)` pair, bounded by the flusher draining
/// (and removing) zeroed entries each window. Same `Mutex<HashMap>` shape as the
/// rate limiter's bucket store — no new dependency.
#[derive(Default)]
pub struct UsageAggregate {
    counters: Mutex<HashMap<(String, String), u64>>,
}

impl UsageAggregate {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Record `qty` of `metric` for `tenant`. Cheap, non-blocking `+=` under a
    /// short critical section (no I/O, no await). Saturating so a runaway count
    /// can never panic the request path. Call sites guard on the metering flag
    /// BEFORE invoking this, so at parity it is never reached.
    pub fn record(&self, tenant: &str, metric: &str, qty: u64) {
        if qty == 0 {
            return;
        }
        let mut map = self.counters.lock().expect("usage aggregate poisoned");
        let entry = map
            .entry((tenant.to_string(), metric.to_string()))
            .or_insert(0);
        *entry = entry.saturating_add(qty);
    }

    /// Drain every non-zero `(tenant, metric)` entry, returning its window total
    /// and REMOVING it from the map (reset to zero for the next window, and bound
    /// the map so idle pairs don't accumulate). Returned order is unspecified.
    #[must_use]
    pub fn drain(&self) -> Vec<(String, String, u64)> {
        let mut map = self.counters.lock().expect("usage aggregate poisoned");
        if map.is_empty() {
            return Vec::new();
        }
        // Replace with an empty map: this both reads every entry AND resets, in
        // one critical section, so a concurrent `record` either lands in the old
        // (drained) map before the swap or the fresh one after — never lost mid-
        // swap. The old map is moved out and iterated outside the lock.
        let taken = std::mem::take(&mut *map);
        drop(map);
        taken
            .into_iter()
            .filter(|(_, qty)| *qty > 0)
            .map(|((t, m), qty)| (t, m, qty))
            .collect()
    }

    /// Number of `(tenant, metric)` pairs currently tracked — the gauge a gate
    /// or `/metrics` scrape can read to prove OFF == 0 entries.
    #[must_use]
    pub fn tracked(&self) -> usize {
        self.counters
            .lock()
            .expect("usage aggregate poisoned")
            .len()
    }
}

/// The frozen on-the-wire envelope for one `(tenant, metric)` window. Every
/// field is the exact string the consumer reads off the `usage.events` stream;
/// [`UsageEnvelope::build`] is the SINGLE place the contract is computed, so the
/// XADD path and the unit test that pins the contract share one implementation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UsageEnvelope {
    pub tenant_id: String,
    pub metric: String,
    /// `qty` as a string (the stream stores everything as strings).
    pub qty: String,
    /// `ts` = the flush instant, unix ms, as a string.
    pub ts: String,
    /// `window_ms` = the flush cadence, as a string.
    pub window_ms: String,
    /// `idempotency_key` = lower-hex sha256 of
    /// `"<tenant_id>|<metric>|<window_start_ms>"`, the dedup key the consumer
    /// UPSERTs on. Identical re-delivery of a window collapses to one row.
    pub idempotency_key: String,
}

impl UsageEnvelope {
    /// Build the frozen envelope for one drained `(tenant, metric, qty)` window,
    /// stamping `ts`/`window_ms` and computing the contract `idempotency_key`.
    /// `now_ms` is the flush instant (unix ms); `window_ms` the flush cadence.
    /// Pure (no I/O) so the contract test and the live XADD share one path.
    #[must_use]
    pub fn build(tenant: &str, metric: &str, qty: u64, now_ms: u64, window_ms: u64) -> Self {
        let window_start_ms = window_start_ms(now_ms, window_ms);
        Self {
            tenant_id: tenant.to_string(),
            metric: metric.to_string(),
            qty: qty.to_string(),
            ts: now_ms.to_string(),
            window_ms: window_ms.to_string(),
            idempotency_key: idempotency_key(tenant, metric, window_start_ms),
        }
    }
}

/// The window-start the `idempotency_key` is bucketed on: the largest multiple
/// of `window_ms` not exceeding `ts`. `window_ms == 0` (misconfig) degrades to
/// the raw `ts` (every window distinct) rather than dividing by zero.
#[must_use]
pub fn window_start_ms(ts: u64, window_ms: u64) -> u64 {
    if window_ms == 0 {
        return ts;
    }
    ts - (ts % window_ms)
}

/// Compute the frozen `idempotency_key`: lower-hex sha256 of
/// `"<tenant_id>|<metric>|<window_start_ms>"`. SHA-256 is already in-tree
/// (`sha2`, non-optional); the hex format matches `nano.rs::sha256_hex` and
/// `service_auth.rs::hex` (lower-case, zero-padded, 64 chars).
#[must_use]
pub fn idempotency_key(tenant: &str, metric: &str, window_start_ms: u64) -> String {
    let mut hasher = Sha256::new();
    hasher.update(tenant.as_bytes());
    hasher.update(b"|");
    hasher.update(metric.as_bytes());
    hasher.update(b"|");
    hasher.update(window_start_ms.to_string().as_bytes());
    let out = hasher.finalize();
    let mut hex = String::with_capacity(64);
    for b in out {
        use std::fmt::Write;
        let _ = write!(hex, "{b:02x}");
    }
    hex
}

/// Current unix time in milliseconds. Falls back to 0 on a pre-epoch clock so
/// the flusher can never panic on a SystemTime error (the envelope's `ts`/key
/// still build; a degraded clock only mis-buckets the window, never crashes).
fn now_unix_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or(0)
}

/// The metering handle wired into `AppState` (like the rate limiter / metrics).
/// Holds the shared aggregate; the request path calls [`Usage::record`], the
/// background flusher (spawned by [`Usage::spawn_flusher`]) drains + emits the
/// B1a tracing event and the B1b durable XADD.
#[derive(Clone)]
pub struct Usage {
    aggregate: Arc<UsageAggregate>,
    /// B1b durable sink (the producer side of the frozen `usage.events`
    /// contract). `None` → tracing-only (no URL configured, or the
    /// `ratelimit-redis` feature is not compiled in this build, e.g. nano/one).
    #[cfg(feature = "ratelimit-redis")]
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
            #[cfg(feature = "ratelimit-redis")]
            stream: None,
        }
    }

    /// Configure the B1b durable Redis stream sink from a URL. An empty/blank URL
    /// leaves the handle tracing-only (B1a). The connection is lazy (opened on
    /// the first flush), so an unreachable Redis at boot never blocks startup —
    /// it just logs and drops on each flush (best-effort). No-op (returns self
    /// unchanged) on builds without the `ratelimit-redis` feature.
    // `mut self` is only mutated under `ratelimit-redis` (which assigns the stream
    // sink); on builds without that feature (nano/one) the body is a no-op, so the
    // `mut` is unused there — allow it rather than splitting the signature.
    #[cfg_attr(not(feature = "ratelimit-redis"), allow(unused_mut))]
    #[must_use]
    pub fn with_stream_url(mut self, url: &str) -> Self {
        #[cfg(feature = "ratelimit-redis")]
        if !url.trim().is_empty() {
            self.stream = Some(Arc::new(UsageStream::new(url.to_string())));
        }
        #[cfg(not(feature = "ratelimit-redis"))]
        let _ = url;
        self
    }

    /// Record one metering event. A thin pass-through to the aggregate so call
    /// sites depend only on this handle. Cheap + non-blocking.
    pub fn record(&self, tenant: &str, metric: &str, qty: u64) {
        self.aggregate.record(tenant, metric, qty);
    }

    /// Pairs currently tracked (test/observability).
    #[must_use]
    pub fn tracked(&self) -> usize {
        self.aggregate.tracked()
    }

    /// Spawn the background flusher (the `outbox.rs::into_background` precedent):
    /// every `flush_ms`, drain non-zero `(tenant, metric)` aggregates and, per
    /// entry, emit ONE structured `usage` tracing event (B1a) AND — when a stream
    /// sink is configured — `XADD` the frozen envelope to `usage.events` (B1b),
    /// best-effort. Only spawned when metering is ON, so OFF adds not even an idle
    /// timer (parity). `flush_ms` is clamped to ≥1 so a misconfigured `0` can't
    /// busy-spin.
    pub fn spawn_flusher(&self, flush_ms: u64) {
        let aggregate = self.aggregate.clone();
        #[cfg(feature = "ratelimit-redis")]
        let stream = self.stream.clone();
        let period = Duration::from_millis(flush_ms.max(1));
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(period);
            // Skip missed ticks instead of bursting if a flush ran long.
            ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                ticker.tick().await;
                let windows = drain_and_trace(&aggregate, flush_ms);
                #[cfg(feature = "ratelimit-redis")]
                if let Some(stream) = stream.as_ref() {
                    // B1b durable XADD — best-effort, never blocks the next tick
                    // beyond the (bounded) Redis round-trips; errors are logged
                    // and dropped inside `xadd_window`.
                    stream.xadd_windows(&windows).await;
                }
                #[cfg(not(feature = "ratelimit-redis"))]
                let _ = &windows;
            }
        });
    }

    /// Flush-on-shutdown (cheap, sync): drain + emit the B1a tracing event for
    /// any pending window synchronously. Called from the graceful-shutdown path
    /// so the last partial window isn't silently lost in the logs. The B1b
    /// durable XADD is async and is NOT attempted here (shutdown is sync and the
    /// stream is best-effort anyway — the last sub-window is the documented
    /// best-effort tolerance). No-op when the map is empty (parity / OFF).
    pub fn flush_now(&self, flush_ms: u64) {
        let _ = drain_and_trace(&self.aggregate, flush_ms);
    }
}

/// Drain the aggregate and emit one structured `usage` tracing event per non-
/// zero `(tenant, metric)` window (the B1a sink), returning the frozen envelopes
/// for the B1b XADD. The `tracing` event carries the human-facing fields; the
/// returned [`UsageEnvelope`]s carry the exact wire contract. No-op (empty vec)
/// when nothing was recorded — the empty-map fast path in `drain` keeps a quiet
/// flusher allocation-free.
fn drain_and_trace(aggregate: &UsageAggregate, flush_ms: u64) -> Vec<UsageEnvelope> {
    let drained = aggregate.drain();
    if drained.is_empty() {
        return Vec::new();
    }
    let now_ms = now_unix_ms();
    let mut envelopes = Vec::with_capacity(drained.len());
    for (tenant, metric, qty) in drained {
        tracing::info!(
            target: "usage",
            tenant = %tenant,
            metric = %metric,
            qty = qty,
            window_ms = flush_ms,
            "usage window"
        );
        envelopes.push(UsageEnvelope::build(
            &tenant, &metric, qty, now_ms, flush_ms,
        ));
    }
    envelopes
}

/// B1b durable producer — a lazily-connected Redis client that `XADD`s usage
/// windows to the frozen `usage.events` stream. Reuses the `redis-rl` crate the
/// rate limiter already compiles (renamed from the `redis` engine crate to avoid
/// the feature collision), so no new dependency. The connection is a
/// `ConnectionManager` (auto-reconnecting), opened on first use via a
/// `OnceCell` — identical posture to `RedisRateLimiter`.
#[cfg(feature = "ratelimit-redis")]
struct UsageStream {
    url: String,
    conn: tokio::sync::OnceCell<redis_rl::aio::ConnectionManager>,
}

#[cfg(feature = "ratelimit-redis")]
impl UsageStream {
    fn new(url: String) -> Self {
        Self {
            url,
            conn: tokio::sync::OnceCell::new(),
        }
    }

    /// XADD each window to `usage.events`, best-effort. A connect/XADD failure is
    /// logged and dropped (the metering rollup is best-effort between flush and
    /// ingest, per the plan's durability caveat) — never panics, never blocks the
    /// request path (this runs in the background flusher). Each entry carries the
    /// frozen envelope fields; the consumer dedups on `idempotency_key`.
    async fn xadd_windows(&self, windows: &[UsageEnvelope]) {
        if windows.is_empty() {
            return;
        }
        let mgr = self
            .conn
            .get_or_try_init(|| async {
                let client = redis_rl::Client::open(self.url.as_str())?;
                redis_rl::aio::ConnectionManager::new(client).await
            })
            .await;
        let Ok(mgr) = mgr else {
            tracing::warn!(
                target: "usage",
                count = windows.len(),
                "metering redis connect failed — usage windows dropped (best-effort)"
            );
            return;
        };
        let mut conn = mgr.clone();
        for env in windows {
            // `XADD usage.events * field value …` with the frozen field set. `*`
            // lets Redis assign the entry id (we dedup on `idempotency_key`, not
            // the stream id). One round-trip per window; the window count is the
            // bounded (tenants × metrics) drained set, not per-op.
            let res: redis_rl::RedisResult<String> = redis_rl::cmd("XADD")
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
                tracing::warn!(
                    target: "usage",
                    tenant = %env.tenant_id,
                    metric = %env.metric,
                    "metering XADD failed — usage window dropped (best-effort): {e}"
                );
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // The core contract the gate pins: record sums per (tenant, metric), drain
    // returns the window totals AND resets to zero, and a second drain is empty.
    #[test]
    fn record_drain_reset() {
        let agg = UsageAggregate::new();
        // Two metrics for one tenant + one for another.
        agg.record("t1", "query.count", 1);
        agg.record("t1", "query.count", 1); // sums to 2
        agg.record("t1", "query.rows", 50);
        agg.record("t2", "write.rows", 3);
        assert_eq!(agg.tracked(), 3, "three distinct (tenant, metric) pairs");

        let mut drained = agg.drain();
        drained.sort();
        assert_eq!(
            drained,
            vec![
                ("t1".to_string(), "query.count".to_string(), 2),
                ("t1".to_string(), "query.rows".to_string(), 50),
                ("t2".to_string(), "write.rows".to_string(), 3),
            ],
            "drain returns per-pair window totals"
        );

        // Reset: the map is empty after a drain, and a second drain yields none.
        assert_eq!(agg.tracked(), 0, "drain reset the aggregate to empty");
        assert!(
            agg.drain().is_empty(),
            "second drain is empty (no double-count)"
        );
    }

    // qty == 0 is a no-op (parity: a zero-row read at the limit clamp must not
    // create an entry or emit a window).
    #[test]
    fn zero_qty_records_nothing() {
        let agg = UsageAggregate::new();
        agg.record("t1", "query.rows", 0);
        assert_eq!(agg.tracked(), 0, "zero qty creates no entry");
        assert!(agg.drain().is_empty());
    }

    // Tenants are isolated — one tenant's count never bleeds into another's, the
    // same isolation property the rate limiter pins.
    #[test]
    fn tenants_are_isolated() {
        let agg = UsageAggregate::new();
        agg.record("a", "query.count", 5);
        agg.record("b", "query.count", 1);
        let mut drained = agg.drain();
        drained.sort();
        assert_eq!(
            drained,
            vec![
                ("a".to_string(), "query.count".to_string(), 5),
                ("b".to_string(), "query.count".to_string(), 1),
            ]
        );
    }

    // The Usage handle is the wired surface: record → tracked → drain via the
    // shared aggregate, and flush_now on an empty handle is a harmless no-op.
    #[test]
    fn handle_records_and_flush_now_is_noop_when_empty() {
        let usage = Usage::new();
        assert_eq!(usage.tracked(), 0);
        usage.flush_now(60000); // empty → no-op, must not panic
        usage.record("t1", "write.rows", 7);
        assert_eq!(usage.tracked(), 1);
        // Draining via the shared aggregate clone proves the handle shares state.
        assert_eq!(
            usage.aggregate.drain(),
            vec![("t1".to_string(), "write.rows".to_string(), 7)]
        );
        assert_eq!(usage.tracked(), 0);
    }

    // B1b — window_start_ms buckets `ts` to the largest multiple of `window_ms`
    // not exceeding it (the frozen contract), and degrades safely on window 0.
    #[test]
    fn window_start_ms_buckets_to_window() {
        // ts in the middle of a 60s window → floor to the window start.
        assert_eq!(window_start_ms(123_456, 60_000), 120_000);
        // ts exactly on a boundary → itself.
        assert_eq!(window_start_ms(120_000, 60_000), 120_000);
        // first ms of the next window → that window's start.
        assert_eq!(window_start_ms(180_001, 60_000), 180_000);
        // window 0 (misconfig) → raw ts, never a divide-by-zero.
        assert_eq!(window_start_ms(123_456, 0), 123_456);
    }

    // B1b — idempotency_key is the lower-hex sha256 of
    // "<tenant>|<metric>|<window_start_ms>" EXACTLY (frozen contract). It is
    // pinned against a golden recomputed independently from the documented
    // preimage (`printf 't1|query.count|120000' | sha256sum`), so the Go consumer
    // computing the same key off the stream agrees byte-for-byte → dedup works
    // across the producer/consumer boundary, and a refactor that changed the
    // separator or field order would diverge here.
    #[test]
    fn idempotency_key_is_frozen_contract() {
        let k = idempotency_key("t1", "query.count", 120_000);
        // 64 lower-hex chars.
        assert_eq!(k.len(), 64, "sha256 hex is 64 chars");
        assert!(
            k.chars()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()),
            "lower-hex only"
        );
        // Independent golden: sha256("t1|query.count|120000"), recomputed here so
        // the assert pins the EXACT bytes without trusting the SUT's internals.
        let preimage = format!("{}|{}|{}", "t1", "query.count", 120_000u64);
        let mut hasher = Sha256::new();
        hasher.update(preimage.as_bytes());
        let mut golden = String::with_capacity(64);
        for b in hasher.finalize() {
            use std::fmt::Write;
            let _ = write!(golden, "{b:02x}");
        }
        assert_eq!(
            k, golden,
            "key == sha256_hex(\"tenant|metric|window_start_ms\")"
        );
    }

    // Determinism: same inputs → same key; any input change → different key.
    #[test]
    fn idempotency_key_is_deterministic_and_sensitive() {
        let a = idempotency_key("t1", "query.count", 120_000);
        let b = idempotency_key("t1", "query.count", 120_000);
        assert_eq!(a, b, "same inputs are deterministic");
        // Each field participates → changing any one changes the key.
        assert_ne!(
            a,
            idempotency_key("t2", "query.count", 120_000),
            "tenant matters"
        );
        assert_ne!(
            a,
            idempotency_key("t1", "query.rows", 120_000),
            "metric matters"
        );
        assert_ne!(
            a,
            idempotency_key("t1", "query.count", 180_000),
            "window matters"
        );
    }

    // B1b — the frozen envelope: every field is the exact string the consumer
    // reads off `usage.events`, and the idempotency_key buckets on the window
    // START (not the raw ts) so two flushes inside one window collapse to one key.
    #[test]
    fn envelope_carries_frozen_fields_and_window_bucketed_key() {
        // ts mid-window; window 60s → window_start 120000.
        let env = UsageEnvelope::build("t1", "query.rows", 42, 123_456, 60_000);
        assert_eq!(env.tenant_id, "t1");
        assert_eq!(env.metric, "query.rows");
        assert_eq!(env.qty, "42", "qty is the integer as a string");
        assert_eq!(env.ts, "123456", "ts is the raw flush instant (unix ms)");
        assert_eq!(env.window_ms, "60000");
        assert_eq!(
            env.idempotency_key,
            idempotency_key("t1", "query.rows", 120_000),
            "key buckets on window START, not raw ts"
        );

        // A second flush LATER in the SAME window → identical idempotency_key
        // (the consumer's ON CONFLICT collapses these, preventing double-count).
        let later = UsageEnvelope::build("t1", "query.rows", 99, 150_000, 60_000);
        assert_eq!(
            later.idempotency_key, env.idempotency_key,
            "same window ⇒ same dedup key (re-delivery must not double-count)"
        );
        // …but a flush in the NEXT window gets a fresh key (a new billable bucket).
        let next = UsageEnvelope::build("t1", "query.rows", 1, 181_000, 60_000);
        assert_ne!(
            next.idempotency_key, env.idempotency_key,
            "next window ⇒ distinct dedup key"
        );
    }

    // A fresh Usage handle has no stream sink (tracing-only) until a non-empty
    // URL is configured; with_stream_url("") leaves it tracing-only (parity).
    #[cfg(feature = "ratelimit-redis")]
    #[test]
    fn stream_sink_is_opt_in_via_nonempty_url() {
        let plain = Usage::new();
        assert!(plain.stream.is_none(), "no sink by default");
        let blank = Usage::new().with_stream_url("   ");
        assert!(blank.stream.is_none(), "blank URL leaves it tracing-only");
        let wired = Usage::new().with_stream_url("redis://127.0.0.1:6379");
        assert!(wired.stream.is_some(), "a real URL wires the durable sink");
    }
}
