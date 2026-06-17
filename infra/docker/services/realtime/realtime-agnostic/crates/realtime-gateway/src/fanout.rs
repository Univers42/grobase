/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   fanout.rs                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Fan-out worker pool — bridges the router's dispatch channel to
//! per-connection send queues.
//!
//! A single dispatcher owns the router's dispatch channel and round-robins
//! messages to N worker tasks, each with its OWN queue (no shared mutex —
//! D2-realtime C1). Each [`LocalDispatch`] is forwarded to the target
//! connection via [`ConnectionManager::try_send()`].

use std::sync::Arc;

use realtime_engine::router::{DispatchMessage, LocalDispatch};
use tokio::sync::mpsc;
use tracing::{debug, warn};

use crate::connection::{ConnectionManager, SendResult};

/// Fan-out worker pool that delivers events from the router to connections.
pub struct FanOutWorkerPool {
    conn_manager: Arc<ConnectionManager>,
    worker_count: usize,
}

impl FanOutWorkerPool {
    pub const fn new(conn_manager: Arc<ConnectionManager>, worker_count: usize) -> Self {
        Self {
            conn_manager,
            worker_count,
        }
    }

    #[must_use]
    pub fn start(&self) -> mpsc::Sender<DispatchMessage> {
        // Treat 0 as auto-detect: use the number of available CPU cores (min 1).
        let count = if self.worker_count == 0 {
            std::thread::available_parallelism()
                .map(std::num::NonZero::get)
                .unwrap_or(4)
        } else {
            self.worker_count
        };
        let (tx, rx) = mpsc::channel::<DispatchMessage>(65536);
        // D2-realtime (C1): previously the N workers shared ONE
        // `Arc<Mutex<Receiver>>` and each held the mutex ACROSS `recv().await`
        // — a tokio anti-pattern that serialized every worker on a single lock
        // even while idle. Instead a single dispatcher owns the receiver (the
        // channel is single-consumer anyway) and round-robins each message to a
        // per-worker channel, so workers pull from their OWN queue with zero
        // cross-worker locking and process fully in parallel.
        let mut worker_txs = Vec::with_capacity(count);
        for worker_id in 0..count {
            let (wtx, wrx) = mpsc::channel::<DispatchMessage>(8192);
            worker_txs.push(wtx);
            let cm = Arc::clone(&self.conn_manager);
            tokio::spawn(run_worker(worker_id, wrx, cm));
        }
        tokio::spawn(dispatch_loop(rx, worker_txs));
        tx
    }
}

/// Single-consumer dispatcher: owns the router's receiver and round-robins each
/// message to a per-worker channel. A `send().await` applies natural back-
/// pressure to the router when a worker is saturated, without ever blocking the
/// OTHER workers (each has its own queue).
async fn dispatch_loop(
    mut rx: mpsc::Receiver<DispatchMessage>,
    worker_txs: Vec<mpsc::Sender<DispatchMessage>>,
) {
    let n = worker_txs.len();
    if n == 0 {
        return;
    }
    let mut next = 0usize;
    while let Some(message) = rx.recv().await {
        let idx = next % n;
        next = next.wrapping_add(1);
        if worker_txs[idx].send(message).await.is_err() {
            debug!(worker = idx, "Fan-out worker channel closed; dropping dispatch");
        }
    }
}

async fn run_worker(
    worker_id: usize,
    mut rx: mpsc::Receiver<DispatchMessage>,
    conn_manager: Arc<ConnectionManager>,
) {
    loop {
        // Each worker owns its receiver (D2-realtime C1) — no shared mutex.
        let message = rx.recv().await;
        match message {
            Some(DispatchMessage::Single(d)) => {
                handle_dispatch(worker_id, d, &conn_manager);
            }
            Some(DispatchMessage::Batch { event, targets }) => {
                for (conn_id, sub_id) in targets {
                    let d = LocalDispatch {
                        conn_id,
                        sub_id,
                        event: std::sync::Arc::clone(&event),
                    };
                    handle_dispatch(worker_id, d, &conn_manager);
                }
            }
            None => {
                debug!(worker = worker_id, "Fan-out worker exiting");
                break;
            }
        }
    }
}

fn handle_dispatch(worker_id: usize, dispatch: LocalDispatch, conn_manager: &ConnectionManager) {
    let conn_id = dispatch.conn_id;
    let m = crate::metrics::metrics();
    match conn_manager.try_send(conn_id, dispatch.sub_id.to_string(), dispatch.event) {
        SendResult::Sent => {
            m.inc_dispatched();
        }
        SendResult::DroppedNewest | SendResult::DroppedOldest => {
            // Real event loss to a slow consumer — was a silent debug! before C4.
            m.inc_dropped_overflow();
            debug!(worker = worker_id, conn_id = %conn_id, "Event dropped due to overflow");
        }
        SendResult::Disconnect => {
            m.inc_slow_disconnected();
            warn!(worker = worker_id, conn_id = %conn_id, "Disconnecting slow consumer");
            conn_manager.remove(conn_id);
        }
        SendResult::ConnectionGone => {
            m.inc_connection_gone();
            debug!(worker = worker_id, conn_id = %conn_id, "Connection gone");
        }
    }
}

#[allow(clippy::unwrap_used, clippy::expect_used)]
#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;
    use chrono::Utc;
    use realtime_core::{ConnectionMeta, EventEnvelope, OverflowPolicy, SubscriptionId, TopicPath};
    use smol_str::SmolStr;

    #[tokio::test]
    async fn test_fanout_delivery() {
        let conn_manager = Arc::new(ConnectionManager::new(256));
        let pool = FanOutWorkerPool::new(Arc::clone(&conn_manager), 2);
        let dispatch_tx = pool.start();

        let conn_id = conn_manager.next_connection_id();
        let meta = ConnectionMeta {
            conn_id,
            peer_addr: "127.0.0.1:12345".parse().unwrap(),
            connected_at: Utc::now(),
            user_id: None,
            claims: None,
        };
        let (_, mut rx) = conn_manager.register(meta, OverflowPolicy::DropNewest);

        let event = Arc::new(EventEnvelope::new(
            TopicPath::new("test"),
            "test",
            Bytes::from("{}"),
        ));

        dispatch_tx
            .send(DispatchMessage::Single(LocalDispatch {
                conn_id,
                sub_id: SubscriptionId(SmolStr::new("sub-1")),
                event,
            }))
            .await
            .unwrap();

        let (sub_id, received) = tokio::time::timeout(std::time::Duration::from_secs(1), rx.recv())
            .await
            .unwrap()
            .unwrap();

        assert_eq!(sub_id, "sub-1");
        assert_eq!(received.event_type, "test");
    }

    #[tokio::test]
    async fn test_batch_fanout_reaches_all_connections() {
        // D2-realtime C1: a Batch must reach EVERY target connection even though
        // the dispatcher round-robins across independent worker queues.
        let conn_manager = Arc::new(ConnectionManager::new(256));
        let pool = FanOutWorkerPool::new(Arc::clone(&conn_manager), 4);
        let dispatch_tx = pool.start();

        let mut rxs = Vec::new();
        let mut targets = Vec::new();
        for _ in 0..16 {
            let conn_id = conn_manager.next_connection_id();
            let meta = ConnectionMeta {
                conn_id,
                peer_addr: "127.0.0.1:12345".parse().unwrap(),
                connected_at: Utc::now(),
                user_id: None,
                claims: None,
            };
            let (_, rx) = conn_manager.register(meta, OverflowPolicy::DropNewest);
            rxs.push(rx);
            targets.push((conn_id, SubscriptionId(SmolStr::new("sub-1"))));
        }

        let event = Arc::new(EventEnvelope::new(
            TopicPath::new("test"),
            "broadcast",
            Bytes::from("{}"),
        ));
        dispatch_tx
            .send(DispatchMessage::Batch { event, targets })
            .await
            .unwrap();

        for mut rx in rxs {
            let (_sub, received) =
                tokio::time::timeout(std::time::Duration::from_secs(1), rx.recv())
                    .await
                    .expect("delivery within 1s")
                    .expect("event received");
            assert_eq!(received.event_type, "broadcast");
        }
    }
}
