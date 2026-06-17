/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mutate.rs                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Mutation operations — add and remove subscriptions from the bitmap index.
//!
//! Uses slot-based allocation with tracked composite keys for O(k) removal
//! where k = number of filter predicates.
//!
//! ## Limit enforcement
//!
//! [`add_subscription()`] checks all [`FilterIndexLimits`] **before**
//! touching any index state, so a rejected subscription is a no-op.

use std::sync::atomic::Ordering;

use realtime_core::{
    filter::{FieldPath, FilterExpr},
    NodeId, RealtimeError, Subscription,
};

use super::FilterIndex;

impl FilterIndex {
    /// Index a subscription into the bitmap structure.
    ///
    /// Allocates a slot in the dispatch slab, indexes filter predicates
    /// using flat composite keys, and tracks all keys for O(k) removal.
    ///
    /// # Errors
    ///
    /// Returns `RealtimeError::CapacityExceeded` if any limit is violated:
    /// - Total subscription count
    /// - Pattern count
    /// - Per-pattern subscription count
    /// - Composite key count
    /// - Fields-per-pattern count
    pub fn add_subscription(
        &self,
        sub: &Subscription,
        gateway_node: Option<NodeId>,
    ) -> realtime_core::Result<()> {
        let pattern_key = sub.topic.as_str().to_string();

        // ── Pre-flight limit checks (no state mutated yet) ────────
        self.check_limits(&pattern_key, sub)?;

        let bitmap_exact = sub.filter.as_ref().is_none_or(Self::is_filter_exact);

        // Allocate a dispatch slot.
        let slot = super::DispatchSlot {
            conn_id: sub.conn_id,
            sub_id: sub.sub_id.clone(),
            gateway_node,
            topic: sub.topic.clone(),
            filter: sub.filter.clone(),
            bitmap_exact,
        };
        let slot_id = self.alloc_slot(slot);
        self.stats.slots_allocated.fetch_add(1, Ordering::Relaxed);

        // Register the pattern.
        self.patterns
            .entry(pattern_key.clone())
            .or_insert_with(|| sub.topic.clone());

        // Reverse lookup for removal.
        self.slot_by_sub
            .insert((sub.conn_id, sub.sub_id.clone()), slot_id);

        // Index filter predicates.
        if let Some(ref filter) = sub.filter {
            let mut keys = Vec::new();
            self.index_filter(&pattern_key, slot_id, filter, &mut keys);
            self.sub_keys
                .insert((sub.conn_id, sub.sub_id.clone()), keys);
        } else {
            // Unfiltered: always matches on this pattern.
            self.unfiltered
                .entry(pattern_key)
                .or_default()
                .insert(slot_id);
            self.sub_keys
                .insert((sub.conn_id, sub.sub_id.clone()), Vec::new());
        }

        Ok(())
    }

    /// Validate all limits before mutating state.
    fn check_limits(&self, pattern_key: &str, sub: &Subscription) -> realtime_core::Result<()> {
        let limits = &self.limits;

        // Global subscription count.
        if self.slot_by_sub.len() >= limits.max_total_subscriptions {
            self.stats
                .subscriptions_rejected
                .fetch_add(1, Ordering::Relaxed);
            return Err(RealtimeError::CapacityExceeded {
                reason: format!(
                    "global subscription limit reached ({})",
                    limits.max_total_subscriptions,
                ),
            });
        }

        // Pattern count.
        if !self.patterns.contains_key(pattern_key) && self.patterns.len() >= limits.max_patterns {
            self.stats
                .subscriptions_rejected
                .fetch_add(1, Ordering::Relaxed);
            return Err(RealtimeError::CapacityExceeded {
                reason: format!(
                    "pattern limit reached ({}) for new pattern \"{}\"",
                    limits.max_patterns, pattern_key,
                ),
            });
        }

        // Per-pattern subscription count (unfiltered + filtered).
        #[allow(clippy::cast_possible_truncation)] // bitmap len fits usize on any real target.
        let pattern_sub_count = self
            .unfiltered
            .get(pattern_key)
            .map_or(0, |bm| bm.len() as usize);
        if pattern_sub_count >= limits.max_subscriptions_per_pattern {
            self.stats
                .subscriptions_rejected
                .fetch_add(1, Ordering::Relaxed);
            return Err(RealtimeError::CapacityExceeded {
                reason: format!(
                    "pattern \"{}\" already has {} subscriptions (max: {})",
                    pattern_key, pattern_sub_count, limits.max_subscriptions_per_pattern,
                ),
            });
        }

        // Composite key count (approximate — exact counting adds overhead).
        #[allow(clippy::cast_possible_truncation)] // u64 counter fits usize on any real target.
        let current_keys = self.stats.composite_key_count.load(Ordering::Relaxed) as usize;
        let estimated_new_keys = Self::estimate_new_keys(sub);
        if current_keys + estimated_new_keys > limits.max_composite_keys {
            self.stats
                .subscriptions_rejected
                .fetch_add(1, Ordering::Relaxed);
            return Err(RealtimeError::CapacityExceeded {
                reason: format!(
                    "composite key limit would be exceeded ({} + {} > {})",
                    current_keys, estimated_new_keys, limits.max_composite_keys,
                ),
            });
        }

        // Fields-per-pattern check.
        if let Some(ref filter) = sub.filter {
            let existing_fields = self
                .fields_by_pattern
                .get(pattern_key)
                .map_or(0, |v| v.len());
            let new_fields = Self::count_new_fields(filter);
            if existing_fields + new_fields > limits.max_fields_per_pattern {
                self.stats
                    .subscriptions_rejected
                    .fetch_add(1, Ordering::Relaxed);
                return Err(RealtimeError::CapacityExceeded {
                    reason: format!(
                        "pattern \"{}\" would exceed field limit ({} + {} > {})",
                        pattern_key, existing_fields, new_fields, limits.max_fields_per_pattern,
                    ),
                });
            }
        }

        Ok(())
    }

    /// Estimate how many new composite keys a subscription will add.
    fn estimate_new_keys(sub: &Subscription) -> usize {
        sub.filter.as_ref().map_or(0, Self::count_keys_in_filter)
    }

    fn count_keys_in_filter(filter: &FilterExpr) -> usize {
        match filter {
            FilterExpr::Eq(_, _) => 1,
            FilterExpr::In(_, values) => values.len(),
            FilterExpr::And(l, r) | FilterExpr::Or(l, r) => {
                Self::count_keys_in_filter(l) + Self::count_keys_in_filter(r)
            }
            FilterExpr::Not(_) | FilterExpr::Ne(_, _) => 0,
        }
    }

    /// Count unique fields in a filter expression that aren't already indexed.
    fn count_new_fields(filter: &FilterExpr) -> usize {
        let mut fields = Vec::new();
        Self::collect_fields(filter, &mut fields);
        fields.sort_unstable();
        fields.dedup();
        fields.len()
    }

    fn collect_fields(filter: &FilterExpr, out: &mut Vec<String>) {
        match filter {
            FilterExpr::Eq(f, _) | FilterExpr::In(f, _) | FilterExpr::Ne(f, _) => {
                out.push(f.0.clone());
            }
            FilterExpr::And(l, r) | FilterExpr::Or(l, r) => {
                Self::collect_fields(l, out);
                Self::collect_fields(r, out);
            }
            FilterExpr::Not(inner) => Self::collect_fields(inner, out),
        }
    }

    /// Remove a subscription from all bitmap indexes in O(k) time.
    pub fn remove_subscription(&self, sub: &Subscription) {
        let key = (sub.conn_id, sub.sub_id.clone());

        // Look up and free the slot.
        if let Some((_, slot_id)) = self.slot_by_sub.remove(&key) {
            self.free_slot(slot_id);
            self.stats.slots_freed.fetch_add(1, Ordering::Relaxed);

            // Remove from unfiltered bitmap.
            let pattern_key = sub.topic.as_str().to_string();
            if let Some(mut bitmap) = self.unfiltered.get_mut(&pattern_key) {
                bitmap.remove(slot_id);
            }

            // Remove from tracked index keys — O(k).
            if let Some((_, keys)) = self.sub_keys.remove(&key) {
                let removed = keys.len() as u64;
                for k in &keys {
                    if let Some(mut bitmap) = self.index.get_mut(k) {
                        bitmap.remove(slot_id);
                    }
                }
                // Decrement composite key counter.
                self.stats
                    .composite_key_count
                    .fetch_sub(removed, Ordering::Relaxed);
            }
        }
    }

    /// Allocate a slot in the dispatch slab, reusing free slots.
    fn alloc_slot(&self, slot: super::DispatchSlot) -> u32 {
        let mut free = self
            .free_slots
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(id) = free.pop() {
            drop(free);
            let mut slots = self
                .slots
                .write()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            slots[id as usize] = Some(slot);
            id
        } else {
            drop(free);
            let mut slots = self
                .slots
                .write()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let id = u32::try_from(slots.len()).unwrap_or(u32::MAX);
            slots.push(Some(slot));
            id
        }
    }

    /// Free a slot in the dispatch slab for reuse.
    fn free_slot(&self, slot_id: u32) {
        let mut slots = self
            .slots
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(entry) = slots.get_mut(slot_id as usize) {
            *entry = None;
        }
        drop(slots);
        let mut free = self
            .free_slots
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        free.push(slot_id);
    }

    /// Recursively walk a [`FilterExpr`] tree and insert bitmap entries.
    fn index_filter(
        &self,
        pattern_key: &str,
        slot_id: u32,
        filter: &FilterExpr,
        tracked_keys: &mut Vec<String>,
    ) {
        match filter {
            FilterExpr::Eq(field, value) => {
                let vs = Self::value_to_string(value);
                let key = Self::make_index_key(pattern_key, &field.0, &vs);
                self.index.entry(key.clone()).or_default().insert(slot_id);
                self.stats
                    .composite_key_count
                    .fetch_add(1, Ordering::Relaxed);
                {
                    let mut fields = self
                        .fields_by_pattern
                        .entry(pattern_key.to_string())
                        .or_default();
                    if !fields.iter().any(|f| f.0 == field.0) {
                        fields.push(FieldPath::new(field.0.clone()));
                    }
                }
                tracked_keys.push(key);
            }
            FilterExpr::In(field, values) => {
                for v in values {
                    let vs = Self::value_to_string(v);
                    let key = Self::make_index_key(pattern_key, &field.0, &vs);
                    self.index.entry(key.clone()).or_default().insert(slot_id);
                    self.stats
                        .composite_key_count
                        .fetch_add(1, Ordering::Relaxed);
                    tracked_keys.push(key);
                }
                {
                    let mut fields = self
                        .fields_by_pattern
                        .entry(pattern_key.to_string())
                        .or_default();
                    if !fields.iter().any(|f| f.0 == field.0) {
                        fields.push(FieldPath::new(field.0.clone()));
                    }
                }
            }
            FilterExpr::And(l, r) | FilterExpr::Or(l, r) => {
                self.index_filter(pattern_key, slot_id, l, tracked_keys);
                self.index_filter(pattern_key, slot_id, r, tracked_keys);
            }
            FilterExpr::Not(_) | FilterExpr::Ne(_, _) => {
                // Non-indexable: goes to unfiltered, will be post-filtered.
                self.unfiltered
                    .entry(pattern_key.to_string())
                    .or_default()
                    .insert(slot_id);
            }
        }
    }
}
