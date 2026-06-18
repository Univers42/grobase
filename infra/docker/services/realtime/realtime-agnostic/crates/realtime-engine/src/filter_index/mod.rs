/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mod.rs                                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Bitmap-based inverted index for high-cardinality filter evaluation.
//!
//! When thousands of subscriptions exist, evaluating each filter individually
//! is O(S) per event. The [`FilterIndex`] pre-indexes filter predicates into
//! [`RoaringBitmap`]s so that evaluation becomes a series of bitmap operations
//! — dramatically faster for large subscription sets.
//!
//! ## Slot-based dispatch
//!
//! Instead of storing connection IDs in the bitmap and then doing O(n) `DashMap`
//! lookups to resolve dispatch info, we store **slot IDs** that index directly
//! into a `Vec<Option<DispatchSlot>>` slab (~2ns per slot vs ~30ns `DashMap`).
//!
//! The index uses flat composite keys `"pattern\0field\0value"` to avoid
//! nested `DashMap` lock contention.
//!
//! ## Guards
//!
//! The index enforces configurable [`FilterIndexLimits`] to prevent
//! unbounded growth (pattern explosion, per-connection abuse, memory
//! exhaustion). An automatic [`CircuitBreaker`] degrades evaluation
//! when latency spikes, and [`FilterIndexStats`] provide lock-free
//! telemetry for health endpoints and monitoring.

mod evaluate;
pub mod limits;
mod mutate;
pub mod stats;

use std::borrow::Cow;
use std::sync::{Mutex, RwLock};

use dashmap::DashMap;
use realtime_core::{
    filter::{FieldPath, FilterExpr, FilterValue},
    ConnectionId, NodeId, SubscriptionId, TopicPattern,
};
use roaring::RoaringBitmap;

use limits::FilterIndexLimits;
use stats::{CircuitBreaker, FilterIndexStats};

/// Pre-computed dispatch information for a single subscription.
///
/// Stored in the slab at the slot ID tracked by the bitmap, enabling
/// O(1) lookup during event dispatch without any `DashMap` access.
#[derive(Debug, Clone)]
pub struct DispatchSlot {
    /// Connection to dispatch to.
    pub conn_id: ConnectionId,
    /// Subscription identifier.
    pub sub_id: SubscriptionId,
    /// Gateway node for multi-node routing.
    pub gateway_node: Option<NodeId>,
    /// Topic pattern for this subscription.
    pub topic: TopicPattern,
    /// Optional filter expression (needed for post-filtering non-exact matches).
    pub filter: Option<FilterExpr>,
    /// Whether the bitmap result is exact (no post-filter needed).
    ///
    /// `true` for `None` (unfiltered), `Eq`, `In`, and pure `Or` trees.
    /// `false` for `And`, `Ne`, `Not` (bitmap over-approximates).
    pub bitmap_exact: bool,
}

/// Bitmap-based inverted index for efficient filter evaluation at scale.
///
/// Uses flat composite keys (`"pattern\0field\0value"`) with slot-based
/// dispatch for sub-linear event routing. The bitmap stores slot IDs that
/// index directly into a `Vec<Option<DispatchSlot>>` slab, eliminating
/// per-connection `DashMap` lookups from the hot path.
///
/// ## Guards
///
/// - **Limits** — configurable hard caps (see [`FilterIndexLimits`]).
/// - **Stats** — lock-free atomic telemetry (see [`FilterIndexStats`]).
/// - **Circuit breaker** — automatic degradation on sustained slow evaluations.
pub struct FilterIndex {
    /// Flat inverted index: `"pattern\0field\0value"` → bitmap of slot IDs.
    index: DashMap<String, RoaringBitmap>,
    /// Unfiltered subscriptions (no filter / non-indexable filters).
    unfiltered: DashMap<String, RoaringBitmap>,
    /// All registered patterns for matching incoming events.
    patterns: DashMap<String, TopicPattern>,
    /// Fields indexed per pattern (for targeted evaluation lookups).
    ///
    /// Stored as `Vec<FieldPath>` instead of `DashSet<String>` to avoid
    /// shard-lock overhead during iteration and eliminate `FieldPath::new`
    /// allocation from the hot path. Dedup is maintained on insert.
    fields_by_pattern: DashMap<String, Vec<FieldPath>>,
    /// Per-subscription tracked index keys for O(k) targeted removal.
    sub_keys: DashMap<(ConnectionId, SubscriptionId), Vec<String>>,
    /// Dispatch slab: `slot_id` → dispatch info. `RwLock` for concurrent reads.
    slots: RwLock<Vec<Option<DispatchSlot>>>,
    /// Free slot IDs for reuse (avoids unbounded slab growth).
    free_slots: Mutex<Vec<u32>>,
    /// Reverse lookup: `(conn_id, sub_id)` → `slot_id` for O(1) removal.
    slot_by_sub: DashMap<(ConnectionId, SubscriptionId), u32>,

    // ── Guards ─────────────────────────────────────────────────────
    /// Hard cardinality limits.
    pub(crate) limits: FilterIndexLimits,
    /// Lock-free telemetry counters.
    pub(crate) stats: FilterIndexStats,
    /// Automatic circuit breaker for evaluation hot-path protection.
    pub(crate) circuit_breaker: CircuitBreaker,
}

impl FilterIndex {
    /// Create a new empty filter index with default limits.
    #[must_use]
    pub fn new() -> Self {
        Self::with_limits(FilterIndexLimits::default())
    }

    /// Create a new empty filter index with custom limits.
    #[must_use]
    pub fn with_limits(limits: FilterIndexLimits) -> Self {
        let circuit_breaker = CircuitBreaker::new(&limits);
        Self {
            index: DashMap::new(),
            unfiltered: DashMap::new(),
            patterns: DashMap::new(),
            fields_by_pattern: DashMap::new(),
            sub_keys: DashMap::new(),
            slots: RwLock::new(Vec::new()),
            free_slots: Mutex::new(Vec::new()),
            slot_by_sub: DashMap::new(),
            limits,
            stats: FilterIndexStats::new(),
            circuit_breaker,
        }
    }

    /// Access the live telemetry stats.
    #[must_use]
    pub const fn stats(&self) -> &FilterIndexStats {
        &self.stats
    }

    /// Access the current limits configuration.
    #[must_use]
    pub const fn limits(&self) -> &FilterIndexLimits {
        &self.limits
    }

    /// Build a composite index key: `"pattern\0field\0value"`.
    fn make_index_key(pattern: &str, field: &str, value: &str) -> String {
        let mut key = String::with_capacity(pattern.len() + field.len() + value.len() + 2);
        key.push_str(pattern);
        key.push('\0');
        key.push_str(field);
        key.push('\0');
        key.push_str(value);
        key
    }

    /// Convert a [`FilterValue`] to a string for composite key construction.
    ///
    /// Returns `Cow::Borrowed` for string values (zero-alloc fast path).
    pub(crate) fn value_to_string(value: &FilterValue) -> Cow<'_, str> {
        match value {
            FilterValue::String(s) => Cow::Borrowed(s.as_str()),
            FilterValue::Integer(i) => Cow::Owned(i.to_string()),
            FilterValue::Float(f) => Cow::Owned(f.to_string()),
            FilterValue::Bool(b) => Cow::Owned(b.to_string()),
            FilterValue::Null => Cow::Borrowed("null"),
        }
    }

    /// Determine whether a filter expression can be exactly represented
    /// by the bitmap (no post-filtering needed).
    fn is_filter_exact(filter: &FilterExpr) -> bool {
        match filter {
            FilterExpr::Eq(_, _) | FilterExpr::In(_, _) => true,
            FilterExpr::Or(l, r) => Self::is_filter_exact(l) && Self::is_filter_exact(r),
            FilterExpr::And(_, _) | FilterExpr::Ne(_, _) | FilterExpr::Not(_) => false,
        }
    }
}

impl Default for FilterIndex {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    use bytes::Bytes;
    use realtime_core::{
        filter::{FieldPath, FilterExpr, FilterValue},
        ConnectionId, EventEnvelope, SubConfig, Subscription, SubscriptionId, TopicPath,
        TopicPattern,
    };
    use smol_str::SmolStr;

    fn make_sub(
        conn_id: u64,
        sub_id: &str,
        topic: &str,
        filter: Option<FilterExpr>,
    ) -> Subscription {
        Subscription {
            sub_id: SubscriptionId(SmolStr::new(sub_id)),
            conn_id: ConnectionId(conn_id),
            topic: TopicPattern::parse(topic),
            filter,
            config: SubConfig::default(),
        }
    }

    #[test]
    fn test_unfiltered_bitmap() {
        let index = FilterIndex::new();
        for i in 0..100 {
            let sub = make_sub(i, &format!("sub-{i}"), "broadcast", None);
            index.add_subscription(&sub, None).unwrap();
        }

        let event = EventEnvelope::new(TopicPath::new("broadcast"), "notify", Bytes::from("{}"));
        let bitmap = index.evaluate(&event);
        assert_eq!(bitmap.len(), 100);
    }

    #[test]
    fn test_filtered_bitmap() {
        let index = FilterIndex::new();
        for i in 0..50 {
            let filter = FilterExpr::Eq(
                FieldPath::new("event_type"),
                FilterValue::String("created".to_string()),
            );
            let sub = make_sub(i, &format!("sub-{i}"), "orders/*", Some(filter));
            index.add_subscription(&sub, None).unwrap();
        }
        for i in 50..100 {
            let filter = FilterExpr::Eq(
                FieldPath::new("event_type"),
                FilterValue::String("deleted".to_string()),
            );
            let sub = make_sub(i, &format!("sub-{i}"), "orders/*", Some(filter));
            index.add_subscription(&sub, None).unwrap();
        }

        let event = EventEnvelope::new(
            TopicPath::new("orders/created"),
            "created",
            Bytes::from("{}"),
        );
        let bitmap = index.evaluate(&event);
        assert_eq!(bitmap.len(), 50);
        for id in &bitmap {
            assert!(id < 50, "Only slots 0-49 should match 'created'");
        }
    }

    #[test]
    fn test_in_filter_bitmap() {
        let index = FilterIndex::new();
        let filter = FilterExpr::In(
            FieldPath::new("event_type"),
            vec![
                FilterValue::String("created".to_string()),
                FilterValue::String("updated".to_string()),
            ],
        );
        let sub = make_sub(1, "sub-1", "orders/*", Some(filter));
        index.add_subscription(&sub, None).unwrap();

        let event1 = EventEnvelope::new(
            TopicPath::new("orders/created"),
            "created",
            Bytes::from("{}"),
        );
        let event2 = EventEnvelope::new(
            TopicPath::new("orders/updated"),
            "updated",
            Bytes::from("{}"),
        );
        let event3 = EventEnvelope::new(
            TopicPath::new("orders/deleted"),
            "deleted",
            Bytes::from("{}"),
        );
        assert_eq!(index.evaluate(&event1).len(), 1);
        assert_eq!(index.evaluate(&event2).len(), 1);
        assert_eq!(index.evaluate(&event3).len(), 0);
    }

    #[test]
    fn test_remove_subscription() {
        let index = FilterIndex::new();
        let sub = make_sub(1, "sub-1", "orders/created", None);
        index.add_subscription(&sub, None).unwrap();

        let event = EventEnvelope::new(
            TopicPath::new("orders/created"),
            "created",
            Bytes::from("{}"),
        );
        assert_eq!(index.evaluate(&event).len(), 1);
        index.remove_subscription(&sub);
        assert_eq!(index.evaluate(&event).len(), 0);
    }

    // ── Guard / limit tests ──────────────────────────────────────

    #[test]
    fn test_max_total_subscriptions_limit() {
        let limits = FilterIndexLimits {
            max_total_subscriptions: 5,
            ..FilterIndexLimits::default()
        };
        let index = FilterIndex::with_limits(limits);

        for i in 0..5 {
            let sub = make_sub(i, &format!("sub-{i}"), "broadcast", None);
            index.add_subscription(&sub, None).unwrap();
        }

        // 6th should fail.
        let sub = make_sub(99, "sub-99", "broadcast", None);
        let err = index.add_subscription(&sub, None).unwrap_err();
        assert!(
            err.to_string().contains("global subscription limit"),
            "Expected global limit error, got: {err}"
        );
    }

    #[test]
    fn test_max_patterns_limit() {
        let limits = FilterIndexLimits {
            max_patterns: 3,
            ..FilterIndexLimits::default()
        };
        let index = FilterIndex::with_limits(limits);

        index
            .add_subscription(&make_sub(1, "s1", "topic/a", None), None)
            .unwrap();
        index
            .add_subscription(&make_sub(2, "s2", "topic/b", None), None)
            .unwrap();
        index
            .add_subscription(&make_sub(3, "s3", "topic/c", None), None)
            .unwrap();

        // 4th pattern should fail.
        let err = index
            .add_subscription(&make_sub(4, "s4", "topic/d", None), None)
            .unwrap_err();
        assert!(
            err.to_string().contains("pattern limit"),
            "Expected pattern limit error, got: {err}"
        );

        // Same pattern should still work.
        index
            .add_subscription(&make_sub(5, "s5", "topic/c", None), None)
            .unwrap();
    }

    #[test]
    fn test_max_composite_keys_limit() {
        let limits = FilterIndexLimits {
            max_composite_keys: 3,
            ..FilterIndexLimits::default()
        };
        let index = FilterIndex::with_limits(limits);

        // Each In(3 values) = 3 keys.
        let filter = FilterExpr::In(
            FieldPath::new("status"),
            vec![
                FilterValue::String("a".to_string()),
                FilterValue::String("b".to_string()),
                FilterValue::String("c".to_string()),
            ],
        );
        index
            .add_subscription(&make_sub(1, "s1", "t", Some(filter)), None)
            .unwrap();

        // Adding 1 more Eq key should fail (3 + 1 > 3).
        let filter2 = FilterExpr::Eq(
            FieldPath::new("status"),
            FilterValue::String("d".to_string()),
        );
        let err = index
            .add_subscription(&make_sub(2, "s2", "t", Some(filter2)), None)
            .unwrap_err();
        assert!(
            err.to_string().contains("composite key limit"),
            "Expected composite key error, got: {err}"
        );
    }

    #[test]
    fn test_stats_tracking() {
        let index = FilterIndex::new();
        let sub = make_sub(1, "s1", "t", None);
        index.add_subscription(&sub, None).unwrap();

        let stats = index.stats().snapshot();
        assert_eq!(stats.slots_allocated, 1);
        assert_eq!(stats.slots_active, 1);
        assert_eq!(stats.slots_freed, 0);

        index.remove_subscription(&sub);
        let stats = index.stats().snapshot();
        assert_eq!(stats.slots_allocated, 1);
        assert_eq!(stats.slots_freed, 1);
        assert_eq!(stats.slots_active, 0);
    }

    #[test]
    fn test_evaluation_stats_tracking() {
        let index = FilterIndex::new();
        for i in 0..10 {
            let sub = make_sub(i, &format!("s-{i}"), "broadcast", None);
            index.add_subscription(&sub, None).unwrap();
        }

        let event = EventEnvelope::new(TopicPath::new("broadcast"), "x", Bytes::from("{}"));
        let _ = index.evaluate(&event);

        let stats = index.stats().snapshot();
        assert_eq!(stats.evaluations_total, 1);
        assert_eq!(stats.matches_total, 10);
        assert!(stats.last_eval_us < 1_000_000, "eval should be < 1s");
    }

    #[test]
    fn test_rejected_subscription_counter() {
        let limits = FilterIndexLimits {
            max_total_subscriptions: 1,
            ..FilterIndexLimits::default()
        };
        let index = FilterIndex::with_limits(limits);
        index
            .add_subscription(&make_sub(1, "s1", "t", None), None)
            .unwrap();

        // Rejected.
        let _ = index.add_subscription(&make_sub(2, "s2", "t", None), None);
        let stats = index.stats().snapshot();
        assert_eq!(stats.subscriptions_rejected, 1);
    }
}
