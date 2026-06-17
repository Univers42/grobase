/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   limits.rs                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Configurable cardinality limits for the filter index.
//!
//! All limits have generous defaults that prevent unbounded growth without
//! affecting normal workloads. Operators can tune them via [`FilterIndexLimits`]
//! at construction time.

/// Hard caps on the filter index to prevent resource exhaustion.
///
/// Every limit has a sensible default (see [`Default`] impl) that should
/// work for most deployments. Pass custom limits to
/// [`FilterIndex::with_limits()`] to override.
///
/// When a limit is hit, the offending `add_subscription` returns
/// `Err(RealtimeError::CapacityExceeded { .. })`.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct FilterIndexLimits {
    /// Maximum number of unique topic patterns (default: 10 000).
    ///
    /// One pattern ≈ 2 KB of overhead (bitmap + field list + key buffers).
    /// At the default of 10K, this caps steady-state memory at ~20 MB.
    pub max_patterns: usize,

    /// Maximum subscriptions per single topic pattern (default: 100 000).
    ///
    /// Prevents a single hot topic from dominating the dispatch slab.
    pub max_subscriptions_per_pattern: usize,

    /// Maximum subscriptions per connection (default: 200).
    ///
    /// Guards against misbehaving clients that open excessive subscriptions.
    pub max_subscriptions_per_connection: usize,

    /// Maximum total composite index keys across all patterns (default: 2 000 000).
    ///
    /// Each composite key is `"pattern\0field\0value"` — bounded by payload
    /// diversity. This cap prevents pathological filter trees from blowing
    /// up the `DashMap` shard count.
    pub max_composite_keys: usize,

    /// Maximum indexed fields per pattern (default: 64).
    ///
    /// Limits the width of the bitmap evaluation loop per pattern.
    pub max_fields_per_pattern: usize,

    /// Global maximum subscriptions across all connections (default: 1 000 000).
    pub max_total_subscriptions: usize,

    /// Evaluation duration (µs) above which an evaluation is classified
    /// as "slow" for circuit-breaker tracking (default: 5 000 µs = 5 ms).
    pub evaluation_slow_threshold_us: u64,

    /// Number of consecutive slow evaluations required to trip the circuit
    /// breaker (default: 50).
    pub circuit_breaker_trip_count: u32,

    /// How long (ms) the circuit breaker stays open before attempting a
    /// half-open probe (default: 5 000 ms = 5 s).
    pub circuit_breaker_cooldown_ms: u64,
}

impl Default for FilterIndexLimits {
    fn default() -> Self {
        Self {
            max_patterns: 10_000,
            max_subscriptions_per_pattern: 100_000,
            max_subscriptions_per_connection: 200,
            max_composite_keys: 2_000_000,
            max_fields_per_pattern: 64,
            max_total_subscriptions: 1_000_000,
            evaluation_slow_threshold_us: 5_000,
            circuit_breaker_trip_count: 50,
            circuit_breaker_cooldown_ms: 5_000,
        }
    }
}

impl FilterIndexLimits {
    /// Unlimited limits — disables all guards. Useful for benchmarks.
    #[must_use]
    pub const fn unlimited() -> Self {
        Self {
            max_patterns: usize::MAX,
            max_subscriptions_per_pattern: usize::MAX,
            max_subscriptions_per_connection: usize::MAX,
            max_composite_keys: usize::MAX,
            max_fields_per_pattern: usize::MAX,
            max_total_subscriptions: usize::MAX,
            evaluation_slow_threshold_us: u64::MAX,
            circuit_breaker_trip_count: u32::MAX,
            circuit_breaker_cooldown_ms: u64::MAX,
        }
    }
}
