/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   bus.rs                                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

use async_trait::async_trait;

use crate::error::Result;
use crate::types::{EventEnvelope, EventId, PublishReceipt};

/// Core pub/sub event bus abstraction.
///
/// # Purpose
/// The bus connects producers (CDC, REST, WebSocket) with the router.
/// All events flow through a single bus instance shared via `Arc`.
#[async_trait]
pub trait EventBus: Send + Sync + 'static {
    /// Create a publisher handle for sending events.
    async fn publisher(&self) -> Result<Box<dyn EventBusPublisher>>;

    /// Create a subscriber receiving events matching `topic_pattern`.
    async fn subscriber(&self, topic_pattern: &str) -> Result<Box<dyn EventBusSubscriber>>;

    /// Health check the underlying bus connection.
    async fn health_check(&self) -> Result<()>;

    /// Shut down the bus gracefully.
    async fn shutdown(&self) -> Result<()>;
}

/// Publisher side of the event bus — sends events into the bus.
///
/// # Purpose
/// Obtained from [`EventBus::publisher()`]. Each producer task gets
/// its own handle.
#[async_trait]
pub trait EventBusPublisher: Send + Sync {
    /// Publish a single event to the given topic.
    ///
    /// # Arguments
    /// * `topic` — Topic string to publish on.
    /// * `event` — Fully-formed event envelope.
    ///
    /// # Returns
    /// A [`PublishReceipt`] confirming the event was accepted.
    ///
    /// # Errors
    /// Returns `EventBusError` if the bus rejects the event.
    async fn publish(&self, topic: &str, event: &EventEnvelope) -> Result<PublishReceipt>;

    /// Publish multiple events atomically.
    ///
    /// # Arguments
    /// * `events` — Slice of `(topic, envelope)` pairs.
    ///
    /// # Errors
    /// Returns `EventBusError` if any event fails.
    async fn publish_batch(
        &self,
        events: &[(String, EventEnvelope)],
    ) -> Result<Vec<PublishReceipt>>;
}

/// Subscriber side of the event bus — receives events.
///
/// # Purpose
/// The engine creates one subscriber (topic `"*"`) and feeds every
/// received event into the router for fan-out.
#[async_trait]
pub trait EventBusSubscriber: Send + Sync {
    /// Block until the next event is available.
    async fn next_event(&mut self) -> Option<EventEnvelope>;

    /// Acknowledge successful processing (at-least-once buses).
    async fn ack(&self, event_id: &EventId) -> Result<()>;

    /// Negative acknowledge — request redelivery.
    async fn nack(&self, event_id: &EventId) -> Result<()>;
}
