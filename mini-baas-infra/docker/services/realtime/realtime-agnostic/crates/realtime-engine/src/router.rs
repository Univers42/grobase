/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   router.rs                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/04/07 11:13:18 by dlesieur          #+#    #+#             */
/*   Updated: 2026/04/07 23:40:36 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Event router — the central fan-out loop of the engine.
//!
//! The router sits between the event bus and the gateway. It:
//! 1. Consumes events from the bus subscriber.
//! 2. Assigns a per-topic sequence number.
//! 3. Wraps the event in `Arc` for zero-copy fan-out.
//! 4. Queries the [`SubscriptionRegistry`] for matching connections.
//! 5. Sends a [`LocalDispatch`] per match into the dispatch channel.
//!
//! The gateway's fan-out task reads from the dispatch channel and
//! writes into each connection's individual send queue.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use realtime_core::{ConnectionId, EventBusSubscriber, EventEnvelope, SubscriptionId};
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};

use crate::registry::SubscriptionRegistry;
use crate::sequence::SequenceGenerator;

/// Type alias for the dispatch callback (currently unused in favour of channels).
pub type DispatchCallback =
    Arc<dyn Fn(ConnectionId, SubscriptionId, Arc<EventEnvelope>) + Send + Sync>;

/// A message sent through the dispatch channel.
///
/// A single `route_event` call produces **one** `DispatchMessage::Batch`
/// instead of N `LocalDispatch` messages. This avoids N `Arc::clone` and
/// N `try_send` calls (saves ~50 µs at 10K subscribers).
#[derive(Debug, Clone)]
pub enum DispatchMessage {
    /// A single dispatch instruction (used for low-cardinality or external sends).
    Single(LocalDispatch),
    /// A batch of targets sharing the same event (produced by `route_event`).
    Batch {
        /// The event shared by all targets (1 `Arc` instead of N clones).
        event: Arc<EventEnvelope>,
        /// The target connections and their subscription IDs.
        targets: Vec<(ConnectionId, SubscriptionId)>,
    },
}

/// The event router: consumes bus events, evaluates subscriptions, dispatches matches.
///
/// ## Architecture
///
/// ```text
/// EventBusSubscriber ──► EventRouter ──► mpsc::channel ──► FanOut task
///                          │
///                 SubscriptionRegistry
/// ```
pub struct EventRouter {
    registry: Arc<SubscriptionRegistry>,
    sequence_gen: Arc<SequenceGenerator>,
    dispatch_tx: mpsc::Sender<DispatchMessage>,
    /// Lock-free dispatch pipeline telemetry.
    dispatch_stats: DispatchStats,
}

/// Lock-free dispatch pipeline telemetry.
///
/// Tracks events routed, matches dispatched, channel failures, and
/// batch sizing. All fields are `AtomicU64` — zero-contention reads.
pub struct DispatchStats {
    /// Total events processed by `route_event`.
    events_routed: AtomicU64,
    /// Total individual matches dispatched (sum of batch sizes).
    matches_dispatched: AtomicU64,
    /// Count of `try_send` failures on the dispatch channel.
    dispatch_failures: AtomicU64,
    /// Number of `DispatchMessage::Batch` messages sent.
    batches_sent: AtomicU64,
    /// Events that had zero matching subscriptions.
    empty_routes: AtomicU64,
    /// Largest batch size seen.
    largest_batch: AtomicU64,
}

impl DispatchStats {
    const fn new() -> Self {
        Self {
            events_routed: AtomicU64::new(0),
            matches_dispatched: AtomicU64::new(0),
            dispatch_failures: AtomicU64::new(0),
            batches_sent: AtomicU64::new(0),
            empty_routes: AtomicU64::new(0),
            largest_batch: AtomicU64::new(0),
        }
    }

    /// Take a point-in-time snapshot for serialization.
    #[must_use]
    pub fn snapshot(&self) -> DispatchStatsSnapshot {
        DispatchStatsSnapshot {
            events_routed: self.events_routed.load(Ordering::Relaxed),
            matches_dispatched: self.matches_dispatched.load(Ordering::Relaxed),
            dispatch_failures: self.dispatch_failures.load(Ordering::Relaxed),
            batches_sent: self.batches_sent.load(Ordering::Relaxed),
            empty_routes: self.empty_routes.load(Ordering::Relaxed),
            largest_batch: self.largest_batch.load(Ordering::Relaxed),
        }
    }

    /// Update the largest-batch high-water mark (CAS loop, wait-free in practice).
    fn update_largest_batch(&self, size: u64) {
        let mut current = self.largest_batch.load(Ordering::Relaxed);
        while size > current {
            match self.largest_batch.compare_exchange_weak(
                current,
                size,
                Ordering::Relaxed,
                Ordering::Relaxed,
            ) {
                Ok(_) => break,
                Err(actual) => current = actual,
            }
        }
    }
}

/// Serializable snapshot of dispatch pipeline telemetry.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct DispatchStatsSnapshot {
    /// Total events processed by `route_event`.
    pub events_routed: u64,
    /// Total individual matches dispatched.
    pub matches_dispatched: u64,
    /// Dispatch channel send failures.
    pub dispatch_failures: u64,
    /// Batch messages sent.
    pub batches_sent: u64,
    /// Events with zero matches.
    pub empty_routes: u64,
    /// High-water mark for batch size.
    pub largest_batch: u64,
}

/// A dispatch instruction destined for a local connection.
///
/// Contains the connection ID, subscription ID, and an `Arc`-wrapped
/// event (shared across all recipients for zero-copy).
#[derive(Debug, Clone)]
pub struct LocalDispatch {
    pub conn_id: ConnectionId,
    pub sub_id: SubscriptionId,
    pub event: Arc<EventEnvelope>,
}

impl EventRouter {
    /// Create a new router.
    ///
    /// # Arguments
    ///
    /// * `registry` — Shared subscription registry.
    /// * `sequence_gen` — Per-topic sequence generator.
    /// * `dispatch_tx` — Channel sender for dispatch instructions.
    #[must_use]
    pub const fn new(
        registry: Arc<SubscriptionRegistry>,
        sequence_gen: Arc<SequenceGenerator>,
        dispatch_tx: mpsc::Sender<DispatchMessage>,
    ) -> Self {
        Self {
            registry,
            sequence_gen,
            dispatch_tx,
            dispatch_stats: DispatchStats::new(),
        }
    }

    /// Route a single event to all matching subscribers.
    ///
    /// Assigns a sequence number, wraps in `Arc` for zero-copy fan-out,
    /// queries the registry via slot-based bitmap dispatch, and sends a
    /// single [`DispatchMessage::Batch`] containing all matching targets.
    ///
    /// This avoids N `Arc::clone` + N `try_send` calls, replacing them
    /// with 1 `Arc` + 1 `try_send` regardless of subscriber count.
    pub fn route_event(&self, mut event: EventEnvelope) -> usize {
        event.sequence = self.sequence_gen.next(event.topic.as_str());
        let event = Arc::new(event);
        let mut targets = Vec::new();
        self.registry
            .for_each_match(&event, |conn_id, sub_id, _node| {
                targets.push((conn_id, sub_id.clone()));
            });
        let count = targets.len();

        self.dispatch_stats
            .events_routed
            .fetch_add(1, Ordering::Relaxed);
        self.dispatch_stats
            .matches_dispatched
            .fetch_add(count as u64, Ordering::Relaxed);

        if count == 0 {
            self.dispatch_stats
                .empty_routes
                .fetch_add(1, Ordering::Relaxed);
            debug!(topic = %event.topic, "No matching subscriptions for event");
        } else {
            self.dispatch_stats.update_largest_batch(count as u64);
            let msg = DispatchMessage::Batch {
                event: event.clone(),
                targets,
            };
            if let Err(e) = self.dispatch_tx.try_send(msg) {
                self.dispatch_stats
                    .dispatch_failures
                    .fetch_add(1, Ordering::Relaxed);
                warn!("Dispatch channel full or closed: {}", e);
            } else {
                self.dispatch_stats
                    .batches_sent
                    .fetch_add(1, Ordering::Relaxed);
            }
            debug!(
                topic = %event.topic, event_id = %event.event_id,
                match_count = count, "Routing event to subscribers"
            );
        }
        count
    }

    /// Start the router loop, consuming events from a bus subscriber.
    ///
    /// This is a long-running task. It blocks on `subscriber.next_event()`
    /// in a loop, routes each event, then acks it on the bus.
    ///
    /// Call this from a `tokio::spawn` with a `Box<dyn EventBusSubscriber>`.
    #[allow(clippy::cognitive_complexity)]
    pub async fn run_with_subscriber(&self, mut subscriber: Box<dyn EventBusSubscriber>) {
        info!("Event router started");

        while let Some(event) = subscriber.next_event().await {
            let event_id = event.event_id.clone();
            let _routed = self.route_event(event);

            // Ack the event on the bus
            if let Err(e) = subscriber.ack(&event_id).await {
                error!("Failed to ack event {}: {}", event_id, e);
            }
        }

        info!("Event router stopped (subscriber closed)");
    }

    /// Return the current sequence number for a topic (without incrementing).
    #[must_use]
    pub fn current_sequence(&self, topic: &str) -> u64 {
        self.sequence_gen.current(topic)
    }

    /// Return a reference to the underlying subscription registry.
    #[must_use]
    pub const fn registry(&self) -> &Arc<SubscriptionRegistry> {
        &self.registry
    }

    /// Access the live dispatch pipeline stats.
    #[must_use]
    pub const fn dispatch_stats(&self) -> &DispatchStats {
        &self.dispatch_stats
    }
}

#[allow(clippy::unwrap_used)]
#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;
    use realtime_core::{SubConfig, Subscription, SubscriptionId, TopicPath, TopicPattern};
    use smol_str::SmolStr;

    #[tokio::test]
    async fn test_route_event_to_single_subscriber() {
        let registry = Arc::new(SubscriptionRegistry::new());
        let seq_gen = Arc::new(SequenceGenerator::new());
        let (dispatch_tx, mut dispatch_rx) = mpsc::channel(1024);

        let router = EventRouter::new(Arc::clone(&registry), seq_gen, dispatch_tx);

        // Subscribe
        let sub = Subscription {
            sub_id: SubscriptionId(SmolStr::new("sub-1")),
            conn_id: ConnectionId(1),
            topic: TopicPattern::parse("orders/created"),
            filter: None,
            config: SubConfig::default(),
        };
        registry.subscribe(sub, None).unwrap();

        // Route event
        let event = EventEnvelope::new(
            TopicPath::new("orders/created"),
            "created",
            Bytes::from(r#"{"id": 1}"#),
        );
        let count = router.route_event(event);
        assert_eq!(count, 1);

        // Check dispatch
        let msg = dispatch_rx.recv().await.unwrap();
        match msg {
            DispatchMessage::Batch { event, targets } => {
                assert_eq!(targets.len(), 1);
                assert_eq!(targets[0].0, ConnectionId(1));
                assert_eq!(event.sequence, 1);
            }
            DispatchMessage::Single(d) => {
                assert_eq!(d.conn_id, ConnectionId(1));
                assert_eq!(d.event.sequence, 1);
            }
        }
    }

    #[tokio::test]
    async fn test_route_event_to_multiple_subscribers() {
        let registry = Arc::new(SubscriptionRegistry::new());
        let seq_gen = Arc::new(SequenceGenerator::new());
        let (dispatch_tx, mut dispatch_rx) = mpsc::channel(4096);

        let router = EventRouter::new(Arc::clone(&registry), seq_gen, dispatch_tx);

        // Subscribe 100 connections
        for i in 0..100u64 {
            let sub = Subscription {
                sub_id: SubscriptionId(SmolStr::new(format!("sub-{i}"))),
                conn_id: ConnectionId(i),
                topic: TopicPattern::parse("broadcast"),
                filter: None,
                config: SubConfig::default(),
            };
            registry.subscribe(sub, None).unwrap();
        }

        let event = EventEnvelope::new(TopicPath::new("broadcast"), "notify", Bytes::from("{}"));
        let count = router.route_event(event);
        assert_eq!(count, 100);

        // Drain dispatch channel — batch dispatch produces 1 message
        let mut received = 0;
        while let Ok(msg) = dispatch_rx.try_recv() {
            match msg {
                DispatchMessage::Batch { targets, .. } => received += targets.len(),
                DispatchMessage::Single(_) => received += 1,
            }
        }
        assert_eq!(received, 100);
    }

    #[tokio::test]
    async fn test_no_matches() {
        let registry = Arc::new(SubscriptionRegistry::new());
        let seq_gen = Arc::new(SequenceGenerator::new());
        let (dispatch_tx, _dispatch_rx) = mpsc::channel(1024);

        let router = EventRouter::new(Arc::clone(&registry), seq_gen, dispatch_tx);

        let event = EventEnvelope::new(TopicPath::new("no/subscribers"), "test", Bytes::from("{}"));
        let count = router.route_event(event);
        assert_eq!(count, 0);
    }

    #[tokio::test]
    async fn test_sequence_numbers_increment() {
        let registry = Arc::new(SubscriptionRegistry::new());
        let seq_gen = Arc::new(SequenceGenerator::new());
        let (dispatch_tx, mut dispatch_rx) = mpsc::channel(1024);

        let router = EventRouter::new(Arc::clone(&registry), seq_gen, dispatch_tx);

        let sub = Subscription {
            sub_id: SubscriptionId(SmolStr::new("sub-1")),
            conn_id: ConnectionId(1),
            topic: TopicPattern::parse("orders/*"),
            filter: None,
            config: SubConfig::default(),
        };
        registry.subscribe(sub, None).unwrap();

        for i in 1..=5 {
            let event = EventEnvelope::new(
                TopicPath::new("orders/created"),
                "created",
                Bytes::from("{}"),
            );
            router.route_event(event);

            let msg = dispatch_rx.recv().await.unwrap();
            match msg {
                DispatchMessage::Batch { event, .. } => {
                    assert_eq!(event.sequence, i);
                }
                DispatchMessage::Single(d) => {
                    assert_eq!(d.event.sequence, i);
                }
            }
        }
    }
}
