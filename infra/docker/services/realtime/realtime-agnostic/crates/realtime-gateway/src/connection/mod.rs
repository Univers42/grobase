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

//! Connection manager — tracks all active WebSocket connections.
//!
//! Each connected client gets a [`ConnectionState`] containing its
//! metadata, per-connection send channel, and overflow policy.
//! The manager is backed by [`DashMap`] for lock-free concurrent access.
//!
//! ## Per-connection isolation
//!
//! Every connection has its own bounded `mpsc` channel. The fan-out
//! task writes events into the channel; a per-connection writer task
//! reads from it and sends WebSocket frames. If a client reads too
//! slowly, backpressure is applied according to its [`OverflowPolicy`].

mod query;
mod send;

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use dashmap::DashMap;
use realtime_core::{ConnectionId, ConnectionMeta, EventEnvelope, OverflowPolicy};
use tokio::sync::mpsc;
use tracing::info;

/// State for a single active WebSocket connection.
pub struct ConnectionState {
    pub meta: ConnectionMeta,
    /// Per-connection send queue: `(sub_id, event)` tuples.
    pub send_tx: mpsc::Sender<(String, Arc<EventEnvelope>)>,
    pub overflow_policy: OverflowPolicy,
}

/// Manages all active connections on this gateway node.
pub struct ConnectionManager {
    pub(crate) connections: DashMap<ConnectionId, ConnectionState>,
    next_conn_id: AtomicU64,
    pub(crate) send_queue_capacity: usize,
}

/// Result of attempting to send an event to a connection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SendResult {
    Sent,
    DroppedNewest,
    DroppedOldest,
    Disconnect,
    ConnectionGone,
}

impl ConnectionManager {
    #[must_use]
    pub fn new(send_queue_capacity: usize) -> Self {
        Self {
            connections: DashMap::new(),
            next_conn_id: AtomicU64::new(1),
            send_queue_capacity,
        }
    }

    pub fn next_connection_id(&self) -> ConnectionId {
        ConnectionId(self.next_conn_id.fetch_add(1, Ordering::SeqCst))
    }

    pub fn register(
        &self,
        meta: ConnectionMeta,
        overflow_policy: OverflowPolicy,
    ) -> (ConnectionId, mpsc::Receiver<(String, Arc<EventEnvelope>)>) {
        let conn_id = meta.conn_id;
        let (send_tx, send_rx) = mpsc::channel(self.send_queue_capacity);
        let state = ConnectionState {
            meta,
            send_tx,
            overflow_policy,
        };
        self.connections.insert(conn_id, state);
        info!(conn_id = %conn_id, "Connection registered");
        (conn_id, send_rx)
    }
}

impl Default for ConnectionManager {
    fn default() -> Self {
        Self::new(256)
    }
}

#[allow(clippy::unwrap_used)]
#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    fn make_meta(conn_id: ConnectionId) -> ConnectionMeta {
        ConnectionMeta {
            conn_id,
            peer_addr: "127.0.0.1:12345".parse().unwrap(),
            connected_at: Utc::now(),
            user_id: None,
            claims: None,
        }
    }

    #[test]
    fn test_connection_registration() {
        let mgr = ConnectionManager::new(256);
        let conn_id = mgr.next_connection_id();
        let meta = make_meta(conn_id);

        let (id, _rx) = mgr.register(meta, OverflowPolicy::DropNewest);
        assert_eq!(id, conn_id);
        assert_eq!(mgr.connection_count(), 1);
        assert!(mgr.has_connection(conn_id));
    }

    #[test]
    fn test_connection_removal() {
        let mgr = ConnectionManager::new(256);
        let conn_id = mgr.next_connection_id();
        let meta = make_meta(conn_id);

        mgr.register(meta, OverflowPolicy::DropNewest);
        mgr.remove(conn_id);
        assert_eq!(mgr.connection_count(), 0);
        assert!(!mgr.has_connection(conn_id));
    }

    #[tokio::test]
    async fn test_try_send() {
        let mgr = ConnectionManager::new(10);
        let conn_id = mgr.next_connection_id();
        let meta = make_meta(conn_id);
        let (_, mut rx) = mgr.register(meta, OverflowPolicy::DropNewest);

        let event = Arc::new(EventEnvelope::new(
            realtime_core::TopicPath::new("test"),
            "test",
            bytes::Bytes::from("{}"),
        ));

        let result = mgr.try_send(conn_id, "sub-1".to_string(), event);
        assert_eq!(result, SendResult::Sent);

        let (sub_id, received) = rx.recv().await.unwrap();
        assert_eq!(sub_id, "sub-1");
        assert_eq!(received.event_type, "test");
    }

    #[test]
    fn test_send_to_nonexistent() {
        let mgr = ConnectionManager::new(10);
        let event = Arc::new(EventEnvelope::new(
            realtime_core::TopicPath::new("test"),
            "test",
            bytes::Bytes::from("{}"),
        ));

        let result = mgr.try_send(ConnectionId(999), "sub-x".to_string(), event);
        assert_eq!(result, SendResult::ConnectionGone);
    }
}
