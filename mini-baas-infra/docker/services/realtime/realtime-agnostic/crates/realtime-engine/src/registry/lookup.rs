/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   lookup.rs                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Lookup operations — the hot path queried on every incoming event.

use realtime_core::{ConnectionId, EventEnvelope, NodeId, SubscriptionId};

use super::{SubscriptionEntry, SubscriptionRegistry};

impl SubscriptionRegistry {
    /// Look up all matching connections for an event via the linear path.
    ///
    /// Iterates all subscriptions per matching topic pattern. For
    /// high-cardinality scenarios, prefer [`for_each_match()`] which
    /// uses the slot-based bitmap index.
    pub fn lookup_matches(
        &self,
        event: &EventEnvelope,
    ) -> Vec<(ConnectionId, SubscriptionId, Option<NodeId>)> {
        let mut matches = Vec::new();
        // Pre-parse payload JSON once for all filter evaluations.
        let parsed: Option<serde_json::Value> = serde_json::from_slice(&event.payload).ok();

        for pref in &self.patterns {
            if !pref.value().matches(&event.topic) {
                continue;
            }
            let Some(topic_subs) = self.by_topic.get(pref.key().as_str()) else {
                continue;
            };
            for (conn_id, sub_id) in topic_subs.iter() {
                let key = (*conn_id, sub_id.0.to_string());
                let Some(entry) = self.by_sub_id.get(&key) else {
                    continue;
                };
                if let Some(ref f) = entry.subscription.filter {
                    let getter = |fld: &realtime_core::filter::FieldPath| {
                        realtime_core::filter::envelope_field_getter_cached(
                            event,
                            fld,
                            parsed.as_ref(),
                        )
                    };
                    if !f.evaluate(&getter) {
                        continue;
                    }
                }
                matches.push((*conn_id, sub_id.clone(), entry.gateway_node));
            }
        }
        matches
    }

    /// Optimized lookup using the bitmap index with slot-based dispatch.
    ///
    /// Returns a `Vec` of matching `(conn_id, sub_id, gateway_node)` tuples.
    /// Uses [`collect_matches()`] internally for pre-allocated Vec sizing.
    pub fn lookup_matches_bitmap(
        &self,
        event: &EventEnvelope,
    ) -> Vec<(ConnectionId, SubscriptionId, Option<NodeId>)> {
        self.filter_index.collect_matches(event)
    }

    /// Invoke `callback` for each subscription matching `event`.
    ///
    /// Uses the bitmap filter index with slot-based dispatch for sub-linear
    /// scaling. `bitmap_exact` slots are dispatched immediately; non-exact
    /// slots are post-filtered with the full `FilterExpr`.
    ///
    /// Returns the number of matches.
    pub fn for_each_match<F>(&self, event: &EventEnvelope, callback: F) -> usize
    where
        F: FnMut(ConnectionId, &SubscriptionId, Option<NodeId>),
    {
        self.filter_index.for_each_match(event, callback)
    }

    /// Return a clone of all subscriptions for a given connection.
    #[must_use]
    pub fn get_connection_subscriptions(&self, conn_id: ConnectionId) -> Vec<SubscriptionEntry> {
        self.by_connection
            .get(&conn_id)
            .map(|v| v.clone())
            .unwrap_or_default()
    }

    /// Return the current sequence for a topic (placeholder — managed by `SequenceGenerator`).
    #[must_use]
    pub const fn get_topic_sequence(&self, _topic: &str) -> u64 {
        0
    }
}
