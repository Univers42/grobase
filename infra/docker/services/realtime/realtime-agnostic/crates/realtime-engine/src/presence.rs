/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   presence.rs                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Per-topic presence tracking — the "who's online" surface.
//!
//! ## Model
//!
//! A connection calls `TRACK { topic, meta }` to join a topic's presence set
//! and `UNTRACK { topic }` (or simply disconnects) to leave it. The tracker
//! keeps, per topic, the set of member connections plus their opaque metadata.
//! Whenever a set changes, the gateway emits a [`ServerMessage::Presence`]
//! snapshot to the topic's subscribers.
//!
//! ## Concurrency
//!
//! Backed by a nested [`DashMap`](dashmap::DashMap) (`topic → conn_id → member`)
//! so joins, leaves, and snapshot reads are lock-free in the common case and
//! never block the event router.
//!
//! ## Multi-node honesty
//!
//! This tracker is **single-node authoritative**: each server instance only
//! knows the members connected to *itself*. The gateway additionally publishes
//! every presence change over the [`EventBus`] (`event_type` `"presence"`), so a
//! multi-node bus *propagates the change notification* cluster-wide — but the
//! membership LIST in a `PRESENCE` frame reflects only the emitting node's
//! local set. True cross-node membership merge needs a shared store
//! (Redis/Postgres) the engine does not yet own; see
//! `wiki/services/realtime/` for the deferral note.
//!
//! [`EventBus`]: realtime_core::EventBus
//! [`ServerMessage::Presence`]: realtime_core::ServerMessage

use dashmap::DashMap;
use realtime_core::{ConnectionId, PresenceMember};

/// Lock-free per-topic presence registry.
///
/// `topic → (conn_id → member)`. The inner map keys on the raw `u64`
/// connection id so a connection can appear at most once per topic.
#[derive(Default)]
pub struct PresenceTracker {
    topics: DashMap<String, DashMap<u64, PresenceMember>>,
}

impl PresenceTracker {
    /// Create an empty presence tracker.
    #[must_use]
    pub fn new() -> Self {
        Self {
            topics: DashMap::new(),
        }
    }

    /// Record `member` as present on `topic` (idempotent — a repeated track
    /// updates the member's metadata in place).
    ///
    /// Returns the topic's full member list *after* the join, ready to be sent
    /// in a [`ServerMessage::Presence`] frame.
    ///
    /// [`ServerMessage::Presence`]: realtime_core::ServerMessage
    #[must_use]
    pub fn track(&self, topic: &str, conn_id: ConnectionId, member: PresenceMember) -> Vec<PresenceMember> {
        let entry = self.topics.entry(topic.to_string()).or_default();
        entry.insert(conn_id.0, member);
        entry.value().iter().map(|m| m.value().clone()).collect()
    }

    /// Remove a connection from `topic`'s presence set.
    ///
    /// Returns `Some(members)` (the remaining set) when the connection was
    /// actually present, else `None` — letting the caller skip emitting a
    /// redundant snapshot. Empty topics are pruned.
    #[must_use]
    pub fn untrack(&self, topic: &str, conn_id: ConnectionId) -> Option<Vec<PresenceMember>> {
        let entry = self.topics.get(topic)?;
        let removed = entry.remove(&conn_id.0).is_some();
        let remaining: Vec<PresenceMember> = entry.iter().map(|m| m.value().clone()).collect();
        let now_empty = remaining.is_empty();
        drop(entry);
        if now_empty {
            // Re-check under a fresh ref to avoid pruning a topic another thread
            // just re-populated.
            self.topics
                .remove_if(topic, |_, members| members.is_empty());
        }
        if removed {
            Some(remaining)
        } else {
            None
        }
    }

    /// Drop a connection from *every* topic it was tracking (disconnect path).
    ///
    /// Returns one `(topic, remaining_members)` pair per topic the connection
    /// actually left, so the gateway can emit a `PRESENCE` snapshot for each.
    #[must_use]
    pub fn remove_connection(&self, conn_id: ConnectionId) -> Vec<(String, Vec<PresenceMember>)> {
        let mut affected = Vec::new();
        // Collect topic keys first — mutating the outer map while iterating it
        // is not allowed.
        let topics: Vec<String> = self.topics.iter().map(|e| e.key().clone()).collect();
        for topic in topics {
            if let Some(remaining) = self.untrack(&topic, conn_id) {
                affected.push((topic, remaining));
            }
        }
        affected
    }

    /// Current members of a topic's presence set (empty when untracked).
    #[must_use]
    pub fn members(&self, topic: &str) -> Vec<PresenceMember> {
        self.topics
            .get(topic)
            .map(|e| e.iter().map(|m| m.value().clone()).collect())
            .unwrap_or_default()
    }

    /// Number of topics with at least one present member.
    #[must_use]
    pub fn topic_count(&self) -> usize {
        self.topics.len()
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    fn member(conn: u64, user: &str) -> PresenceMember {
        PresenceMember {
            conn_id: conn.to_string(),
            user_id: Some(user.to_string()),
            meta: serde_json::json!({ "color": "blue" }),
        }
    }

    #[test]
    fn track_then_members_lists_the_member() {
        let p = PresenceTracker::new();
        let after = p.track("room/1", ConnectionId(7), member(7, "alice"));
        assert_eq!(after.len(), 1);
        assert_eq!(p.members("room/1").len(), 1);
        assert_eq!(p.members("room/1")[0].user_id.as_deref(), Some("alice"));
    }

    #[test]
    fn second_track_same_conn_updates_in_place() {
        let p = PresenceTracker::new();
        let _ = p.track("room/1", ConnectionId(7), member(7, "alice"));
        let after = p.track("room/1", ConnectionId(7), member(7, "alice2"));
        assert_eq!(after.len(), 1, "same connection must not duplicate");
        assert_eq!(p.members("room/1")[0].user_id.as_deref(), Some("alice2"));
    }

    #[test]
    fn untrack_removes_and_reports_remaining() {
        let p = PresenceTracker::new();
        let _ = p.track("room/1", ConnectionId(1), member(1, "alice"));
        let _ = p.track("room/1", ConnectionId(2), member(2, "bob"));
        let remaining = p.untrack("room/1", ConnectionId(1));
        assert_eq!(remaining.expect("was present").len(), 1);
        assert_eq!(p.members("room/1")[0].user_id.as_deref(), Some("bob"));
    }

    #[test]
    fn untrack_unknown_conn_returns_none() {
        let p = PresenceTracker::new();
        let _ = p.track("room/1", ConnectionId(1), member(1, "alice"));
        assert!(p.untrack("room/1", ConnectionId(99)).is_none());
        assert!(p.untrack("no/such/topic", ConnectionId(1)).is_none());
    }

    #[test]
    fn last_leave_prunes_topic() {
        let p = PresenceTracker::new();
        let _ = p.track("room/1", ConnectionId(1), member(1, "alice"));
        let _ = p.untrack("room/1", ConnectionId(1));
        assert_eq!(p.topic_count(), 0, "empty topic must be pruned");
    }

    #[test]
    fn remove_connection_clears_all_its_topics() {
        let p = PresenceTracker::new();
        let _ = p.track("room/1", ConnectionId(1), member(1, "alice"));
        let _ = p.track("room/2", ConnectionId(1), member(1, "alice"));
        let _ = p.track("room/1", ConnectionId(2), member(2, "bob"));
        let affected = p.remove_connection(ConnectionId(1));
        assert_eq!(affected.len(), 2, "left two topics");
        assert!(p.members("room/1").iter().all(|m| m.user_id.as_deref() != Some("alice")));
        assert_eq!(p.members("room/2").len(), 0);
    }
}
