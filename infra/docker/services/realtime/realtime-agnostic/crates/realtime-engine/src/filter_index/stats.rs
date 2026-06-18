/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   stats.rs                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Lock-free atomic telemetry counters and circuit breaker for the filter index.
//!
//! All fields use `AtomicU64` / `AtomicU32` / `AtomicBool` so they can be
//! updated from the evaluation hot-path without any locking. The
//! [`StatsSnapshot`] struct provides a point-in-time copy for serialization.

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use super::limits::FilterIndexLimits;

/// Lock-free telemetry counters for the filter index.
///
/// Updated on every `add_subscription`, `remove_subscription`, and
/// `evaluate` / `for_each_match` call. Reading individual counters is
/// always wait-free (a single atomic load).
pub struct FilterIndexStats {
    // ── Subscription metrics ──────────────────────────────────────
    /// Total slot allocations since startup.
    pub(crate) slots_allocated: AtomicU64,
    /// Total slot frees since startup (difference = live slot count).
    pub(crate) slots_freed: AtomicU64,
    /// Subscriptions rejected because a limit was exceeded.
    pub(crate) subscriptions_rejected: AtomicU64,

    // ── Index size metrics (maintained live) ──────────────────────
    /// Current number of composite keys in the inverted index.
    pub(crate) composite_key_count: AtomicU64,

    // ── Evaluation metrics ────────────────────────────────────────
    /// Total `evaluate` / `for_each_match` calls.
    pub(crate) evaluations_total: AtomicU64,
    /// Evaluations that returned zero matches.
    pub(crate) evaluations_empty: AtomicU64,
    /// Total individual slot matches across all evaluations.
    pub(crate) matches_total: AtomicU64,
    /// Last evaluation duration in microseconds.
    pub(crate) last_eval_us: AtomicU64,
    /// Peak (high-water mark) evaluation duration in microseconds.
    pub(crate) peak_eval_us: AtomicU64,
    /// Count of evaluations classified as "slow".
    pub(crate) slow_evaluations: AtomicU64,

    // ── Circuit breaker ──────────────────────────────────────────
    /// Number of times the circuit breaker has tripped.
    pub(crate) circuit_trips: AtomicU64,
    /// Evaluations that were bypassed while the circuit was open.
    pub(crate) circuit_bypassed: AtomicU64,
}

impl FilterIndexStats {
    pub(crate) const fn new() -> Self {
        Self {
            slots_allocated: AtomicU64::new(0),
            slots_freed: AtomicU64::new(0),
            subscriptions_rejected: AtomicU64::new(0),
            composite_key_count: AtomicU64::new(0),
            evaluations_total: AtomicU64::new(0),
            evaluations_empty: AtomicU64::new(0),
            matches_total: AtomicU64::new(0),
            last_eval_us: AtomicU64::new(0),
            peak_eval_us: AtomicU64::new(0),
            slow_evaluations: AtomicU64::new(0),
            circuit_trips: AtomicU64::new(0),
            circuit_bypassed: AtomicU64::new(0),
        }
    }

    /// Take a point-in-time snapshot of all counters (for serialization).
    #[must_use]
    pub fn snapshot(&self) -> StatsSnapshot {
        StatsSnapshot {
            slots_active: self
                .slots_allocated
                .load(Ordering::Relaxed)
                .saturating_sub(self.slots_freed.load(Ordering::Relaxed)),
            slots_allocated: self.slots_allocated.load(Ordering::Relaxed),
            slots_freed: self.slots_freed.load(Ordering::Relaxed),
            subscriptions_rejected: self.subscriptions_rejected.load(Ordering::Relaxed),
            composite_key_count: self.composite_key_count.load(Ordering::Relaxed),
            evaluations_total: self.evaluations_total.load(Ordering::Relaxed),
            evaluations_empty: self.evaluations_empty.load(Ordering::Relaxed),
            matches_total: self.matches_total.load(Ordering::Relaxed),
            last_eval_us: self.last_eval_us.load(Ordering::Relaxed),
            peak_eval_us: self.peak_eval_us.load(Ordering::Relaxed),
            slow_evaluations: self.slow_evaluations.load(Ordering::Relaxed),
            circuit_trips: self.circuit_trips.load(Ordering::Relaxed),
            circuit_bypassed: self.circuit_bypassed.load(Ordering::Relaxed),
        }
    }

    /// Record an evaluation duration and update peak / slow counters.
    pub(crate) fn record_evaluation(&self, duration_us: u64, match_count: u64) {
        self.evaluations_total.fetch_add(1, Ordering::Relaxed);
        self.matches_total.fetch_add(match_count, Ordering::Relaxed);
        self.last_eval_us.store(duration_us, Ordering::Relaxed);
        if match_count == 0 {
            self.evaluations_empty.fetch_add(1, Ordering::Relaxed);
        }
        // Update peak (CAS loop, wait-free in practice).
        let mut peak = self.peak_eval_us.load(Ordering::Relaxed);
        while duration_us > peak {
            match self.peak_eval_us.compare_exchange_weak(
                peak,
                duration_us,
                Ordering::Relaxed,
                Ordering::Relaxed,
            ) {
                Ok(_) => break,
                Err(actual) => peak = actual,
            }
        }
    }
}

impl Default for FilterIndexStats {
    fn default() -> Self {
        Self::new()
    }
}

/// Point-in-time snapshot of filter index telemetry.
///
/// All fields are plain `u64` — safe to serialize to JSON for health
/// endpoints or ship to a metrics backend.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct StatsSnapshot {
    /// Currently live (allocated − freed) dispatch slots.
    pub slots_active: u64,
    /// Total slot allocations since startup.
    pub slots_allocated: u64,
    /// Total slot frees since startup.
    pub slots_freed: u64,
    /// Subscriptions rejected due to limit violations.
    pub subscriptions_rejected: u64,
    /// Current composite key count in the inverted index.
    pub composite_key_count: u64,
    /// Total evaluations performed.
    pub evaluations_total: u64,
    /// Evaluations that returned zero matches.
    pub evaluations_empty: u64,
    /// Total slot matches across all evaluations.
    pub matches_total: u64,
    /// Most recent evaluation latency (µs).
    pub last_eval_us: u64,
    /// Peak evaluation latency (µs) since startup.
    pub peak_eval_us: u64,
    /// Evaluations classified as slow.
    pub slow_evaluations: u64,
    /// Times the circuit breaker has tripped.
    pub circuit_trips: u64,
    /// Evaluations bypassed while the circuit was open.
    pub circuit_bypassed: u64,
}

/// Automatic circuit breaker protecting the evaluation hot-path.
///
/// Uses lock-free atomics only. States:
///
/// - **Closed** — normal operation; evaluations run fully.
/// - **Open** — evaluation returns only unfiltered (cheapest) matches;
///   field-indexed evaluation is skipped.
/// - **Half-open** — one probe evaluation runs fully; if it's fast enough
///   the circuit closes, otherwise it re-opens.
///
/// Transitions:
/// ```text
/// Closed ──[consecutive_slow >= trip_count]──► Open
///                                               │
///                              [cooldown elapsed]│
///                                               ▼
/// Closed ◄──[probe fast]── Half-Open ──[probe slow]──► Open
/// ```
pub struct CircuitBreaker {
    /// Consecutive slow evaluations (reset to 0 on any fast evaluation).
    consecutive_slow: AtomicU32,
    /// `true` when the circuit is open (evaluation degraded).
    open: AtomicBool,
    /// `true` when a half-open probe is in progress (prevents stampede).
    half_open_probe: AtomicBool,
    /// System-time millis when the circuit was opened.
    opened_at_ms: AtomicU64,
    /// Reference to limits for thresholds.
    threshold_us: u64,
    trip_count: u32,
    cooldown_ms: u64,
}

impl CircuitBreaker {
    pub(crate) const fn new(limits: &FilterIndexLimits) -> Self {
        Self {
            consecutive_slow: AtomicU32::new(0),
            open: AtomicBool::new(false),
            half_open_probe: AtomicBool::new(false),
            opened_at_ms: AtomicU64::new(0),
            threshold_us: limits.evaluation_slow_threshold_us,
            trip_count: limits.circuit_breaker_trip_count,
            cooldown_ms: limits.circuit_breaker_cooldown_ms,
        }
    }

    /// Check whether the circuit is open (caller should degrade).
    ///
    /// If the cooldown has elapsed, attempts a half-open probe:
    /// returns `false` (allow evaluation) for exactly one caller.
    pub(crate) fn is_open(&self) -> bool {
        if !self.open.load(Ordering::Relaxed) {
            return false;
        }
        // Check cooldown.
        let now_ms = epoch_ms();
        let opened = self.opened_at_ms.load(Ordering::Relaxed);
        if now_ms.saturating_sub(opened) >= self.cooldown_ms {
            // Attempt half-open probe (only one thread wins).
            if self
                .half_open_probe
                .compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
                .is_ok()
            {
                return false; // This caller runs the probe.
            }
        }
        true
    }

    /// Report an evaluation result. Updates the circuit state.
    pub(crate) fn report(&self, duration_us: u64, stats: &FilterIndexStats) {
        let slow = duration_us > self.threshold_us;

        if slow {
            stats.slow_evaluations.fetch_add(1, Ordering::Relaxed);
            let prev = self.consecutive_slow.fetch_add(1, Ordering::Relaxed);

            if !self.open.load(Ordering::Relaxed) && prev + 1 >= self.trip_count {
                // Trip the circuit.
                self.open.store(true, Ordering::Release);
                self.opened_at_ms.store(epoch_ms(), Ordering::Relaxed);
                stats.circuit_trips.fetch_add(1, Ordering::Relaxed);
                tracing::warn!(
                    duration_us,
                    consecutive = prev + 1,
                    "Circuit breaker OPEN — evaluation degraded"
                );
            }

            // If this was a half-open probe and it was slow, re-open.
            if self.half_open_probe.load(Ordering::Relaxed) {
                self.opened_at_ms.store(epoch_ms(), Ordering::Relaxed);
                self.half_open_probe.store(false, Ordering::Release);
            }
        } else {
            // Fast evaluation — reset consecutive count.
            self.consecutive_slow.store(0, Ordering::Relaxed);

            if self.half_open_probe.load(Ordering::Relaxed) {
                // Half-open probe succeeded — close the circuit.
                self.open.store(false, Ordering::Release);
                self.half_open_probe.store(false, Ordering::Release);
                tracing::info!(duration_us, "Circuit breaker CLOSED — recovered");
            }
        }
    }
}

/// Current epoch time in milliseconds (monotonic-ish, cheap).
#[allow(clippy::cast_possible_truncation)] // ms since epoch fits u64 for 584M years.
fn epoch_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
