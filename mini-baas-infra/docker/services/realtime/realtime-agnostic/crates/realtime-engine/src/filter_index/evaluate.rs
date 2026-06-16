/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   evaluate.rs                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Evaluation and dispatch operations — the hot path of the engine.
//!
//! [`evaluate()`] returns a [`RoaringBitmap`] of slot IDs. [`for_each_match()`]
//! combines evaluation with dispatch, invoking a callback for each matching
//! slot using the pre-computed [`DispatchSlot`] info. JSON payload is parsed
//! once and shared between bitmap evaluation and any post-filter checks.
//!
//! ## Circuit breaker
//!
//! When evaluation latency exceeds `evaluation_slow_threshold_us` for
//! `circuit_breaker_trip_count` consecutive evaluations, the circuit opens.
//! While open, **only unfiltered subscriptions** are matched (the cheapest
//! bitmap union). This provides graceful degradation instead of dropping
//! events entirely. The circuit re-closes automatically after a cooldown
//! period when a probe evaluation completes in time.

#![allow(clippy::cast_possible_truncation)] // Intentional: µs values never overflow u64, bitmap len fits usize.

use std::time::Instant;

use realtime_core::{
    filter::{envelope_field_getter_cached, FieldPath},
    ConnectionId, EventEnvelope, NodeId, SubscriptionId,
};
use roaring::RoaringBitmap;

use super::FilterIndex;

impl FilterIndex {
    /// Evaluate all filters against an event, returning a bitmap of slot IDs.
    ///
    /// Integrates with the circuit breaker: when the circuit is open, only
    /// unfiltered subscriptions are returned (fast degraded path). Evaluation
    /// duration and match count are recorded in [`FilterIndexStats`].
    pub fn evaluate(&self, event: &EventEnvelope) -> RoaringBitmap {
        let start = Instant::now();

        // Circuit breaker: if open, return unfiltered-only (cheapest path).
        if self.circuit_breaker.is_open() {
            let result = self.evaluate_unfiltered_only(event);
            let us = start.elapsed().as_micros() as u64;
            self.stats
                .circuit_bypassed
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            self.stats.record_evaluation(us, result.len());
            self.circuit_breaker.report(us, &self.stats);
            return result;
        }

        // Normal path.
        let parsed: Option<serde_json::Value> = if self.fields_by_pattern.is_empty() {
            None
        } else {
            serde_json::from_slice(&event.payload).ok()
        };
        let result = self.evaluate_inner(event, parsed.as_ref());

        let us = start.elapsed().as_micros() as u64;
        self.stats.record_evaluation(us, result.len());
        self.circuit_breaker.report(us, &self.stats);

        result
    }

    /// Degraded evaluation: only unfiltered subscriptions, no field matching.
    fn evaluate_unfiltered_only(&self, event: &EventEnvelope) -> RoaringBitmap {
        let mut result = RoaringBitmap::new();
        for pattern_ref in &self.patterns {
            if !pattern_ref.value().matches(&event.topic) {
                continue;
            }
            if let Some(unfiltered) = self.unfiltered.get(pattern_ref.key().as_str()) {
                result |= unfiltered.value();
            }
        }
        result
    }

    /// Internal evaluation using a pre-parsed payload (avoids double-parse
    /// when called from [`for_each_match()`]).
    fn evaluate_inner(
        &self,
        event: &EventEnvelope,
        parsed_payload: Option<&serde_json::Value>,
    ) -> RoaringBitmap {
        let mut result = RoaringBitmap::new();
        let mut key_buf = String::with_capacity(128);

        for pattern_ref in &self.patterns {
            if !pattern_ref.value().matches(&event.topic) {
                continue;
            }
            let pattern_key = pattern_ref.key();

            // Include all unfiltered (and Ne/Not) subscriptions.
            if let Some(unfiltered) = self.unfiltered.get(pattern_key.as_str()) {
                result |= unfiltered.value();
            }

            // Look up indexed fields using flat composite keys.
            if let Some(fields) = self.fields_by_pattern.get(pattern_key.as_str()) {
                for field_path in fields.value() {
                    if let Some(fv) =
                        envelope_field_getter_cached(event, field_path, parsed_payload)
                    {
                        let vs = Self::value_to_string(&fv);
                        key_buf.clear();
                        key_buf.push_str(pattern_key);
                        key_buf.push('\0');
                        key_buf.push_str(&field_path.0);
                        key_buf.push('\0');
                        key_buf.push_str(&vs);
                        if let Some(bitmap) = self.index.get(key_buf.as_str()) {
                            result |= bitmap.value();
                        }
                    }
                }
            }
        }
        result
    }

    /// Iterate all matching subscriptions for an event, invoking `callback`
    /// for each match. Returns the number of matches.
    ///
    /// For `bitmap_exact` slots, the callback is invoked immediately.
    /// For non-exact slots, the filter is re-evaluated using the pre-parsed
    /// payload. JSON is parsed exactly **once** regardless of slot count.
    ///
    /// When the circuit breaker is open, only unfiltered slots are dispatched.
    pub fn for_each_match<F>(&self, event: &EventEnvelope, mut callback: F) -> usize
    where
        F: FnMut(ConnectionId, &SubscriptionId, Option<NodeId>),
    {
        let start = Instant::now();

        // Circuit breaker: degraded path.
        if self.circuit_breaker.is_open() {
            let bitmap = self.evaluate_unfiltered_only(event);
            let count = self.dispatch_bitmap(&bitmap, &mut callback);
            let us = start.elapsed().as_micros() as u64;
            self.stats
                .circuit_bypassed
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            self.stats.record_evaluation(us, count as u64);
            self.circuit_breaker.report(us, &self.stats);
            return count;
        }

        // Normal path: lazy JSON parse.
        let has_fields = !self.fields_by_pattern.is_empty();
        let parsed: Option<serde_json::Value> = if has_fields {
            serde_json::from_slice(&event.payload).ok()
        } else {
            None
        };
        let bitmap = self.evaluate_inner(event, parsed.as_ref());
        if bitmap.is_empty() {
            let us = start.elapsed().as_micros() as u64;
            self.stats.record_evaluation(us, 0);
            self.circuit_breaker.report(us, &self.stats);
            return 0;
        }

        // Late parse is deferred until the first non-exact slot needs it.
        let mut late_parsed: Option<serde_json::Value> = None;

        let slots = self
            .slots
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut count = 0;

        for slot_id in &bitmap {
            // SAFETY: slot_id was inserted by alloc_slot and is always < slots.len().
            let entry = unsafe { slots.get_unchecked(slot_id as usize) };
            if let Some(slot) = entry {
                if slot.bitmap_exact {
                    // Fast path: bitmap is exact, no post-filter needed.
                    callback(slot.conn_id, &slot.sub_id, slot.gateway_node);
                    count += 1;
                } else if let Some(ref f) = slot.filter {
                    // Parse payload on demand for non-exact post-filtering.
                    if late_parsed.is_none() && parsed.is_none() {
                        late_parsed = serde_json::from_slice(&event.payload).ok();
                    }
                    let parsed_ref = parsed.as_ref().or(late_parsed.as_ref());
                    let getter =
                        |fld: &FieldPath| envelope_field_getter_cached(event, fld, parsed_ref);
                    if f.evaluate(&getter) {
                        callback(slot.conn_id, &slot.sub_id, slot.gateway_node);
                        count += 1;
                    }
                } else {
                    callback(slot.conn_id, &slot.sub_id, slot.gateway_node);
                    count += 1;
                }
            }
        }

        let us = start.elapsed().as_micros() as u64;
        self.stats.record_evaluation(us, count as u64);
        self.circuit_breaker.report(us, &self.stats);

        count
    }

    /// Dispatch all slots in a bitmap (exact-only, no post-filtering).
    ///
    /// Used by the circuit-breaker degraded path where all returned slots
    /// are from the unfiltered bitmap and are inherently exact.
    fn dispatch_bitmap<F>(&self, bitmap: &RoaringBitmap, callback: &mut F) -> usize
    where
        F: FnMut(ConnectionId, &SubscriptionId, Option<NodeId>),
    {
        let slots = self
            .slots
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut count = 0;
        for slot_id in bitmap {
            // SAFETY: slot_id was inserted by alloc_slot and is always < slots.len().
            let entry = unsafe { slots.get_unchecked(slot_id as usize) };
            if let Some(slot) = entry {
                callback(slot.conn_id, &slot.sub_id, slot.gateway_node);
                count += 1;
            }
        }
        count
    }

    /// Collect all matching subscriptions into a pre-allocated `Vec`.
    ///
    /// Like [`for_each_match()`] but returns a `Vec` sized to the bitmap
    /// length upfront, avoiding ~14 reallocations at 10K matches.
    /// Respects the circuit breaker in the same way as [`for_each_match()`].
    pub fn collect_matches(
        &self,
        event: &EventEnvelope,
    ) -> Vec<(ConnectionId, SubscriptionId, Option<NodeId>)> {
        let start = Instant::now();

        // Circuit breaker: degraded path.
        if self.circuit_breaker.is_open() {
            let bitmap = self.evaluate_unfiltered_only(event);
            let mut matches = Vec::with_capacity(bitmap.len() as usize);
            self.dispatch_bitmap(&bitmap, &mut |conn_id, sub_id, node| {
                matches.push((conn_id, sub_id.clone(), node));
            });
            let us = start.elapsed().as_micros() as u64;
            self.stats
                .circuit_bypassed
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            self.stats.record_evaluation(us, matches.len() as u64);
            self.circuit_breaker.report(us, &self.stats);
            return matches;
        }

        let has_fields = !self.fields_by_pattern.is_empty();
        let parsed: Option<serde_json::Value> = if has_fields {
            serde_json::from_slice(&event.payload).ok()
        } else {
            None
        };
        let bitmap = self.evaluate_inner(event, parsed.as_ref());
        if bitmap.is_empty() {
            let us = start.elapsed().as_micros() as u64;
            self.stats.record_evaluation(us, 0);
            self.circuit_breaker.report(us, &self.stats);
            return Vec::new();
        }

        let mut late_parsed: Option<serde_json::Value> = None;

        #[allow(clippy::cast_possible_truncation)]
        let mut matches = Vec::with_capacity(bitmap.len() as usize);
        let slots = self
            .slots
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner);

        for slot_id in &bitmap {
            // SAFETY: slot_id was inserted by alloc_slot and is always < slots.len().
            let entry = unsafe { slots.get_unchecked(slot_id as usize) };
            if let Some(slot) = entry {
                if slot.bitmap_exact {
                    matches.push((slot.conn_id, slot.sub_id.clone(), slot.gateway_node));
                } else if let Some(ref f) = slot.filter {
                    if late_parsed.is_none() && parsed.is_none() {
                        late_parsed = serde_json::from_slice(&event.payload).ok();
                    }
                    let parsed_ref = parsed.as_ref().or(late_parsed.as_ref());
                    let getter =
                        |fld: &FieldPath| envelope_field_getter_cached(event, fld, parsed_ref);
                    if f.evaluate(&getter) {
                        matches.push((slot.conn_id, slot.sub_id.clone(), slot.gateway_node));
                    }
                } else {
                    matches.push((slot.conn_id, slot.sub_id.clone(), slot.gateway_node));
                }
            }
        }

        let us = start.elapsed().as_micros() as u64;
        self.stats.record_evaluation(us, matches.len() as u64);
        self.circuit_breaker.report(us, &self.stats);

        matches
    }
}
