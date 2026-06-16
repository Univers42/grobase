/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   publisher.rs                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Publisher side of the in-process bus.

use async_trait::async_trait;
use realtime_core::{EventBusPublisher, EventEnvelope, PublishReceipt, RealtimeError, Result};
use tokio::sync::broadcast;
use tracing::debug;

/// Publisher that wraps a `broadcast::Sender`.
///
/// Clones of the sender are cheap — they share the same
/// internal ring buffer via `Arc`.
pub struct InProcessPublisher {
    sender: broadcast::Sender<EventEnvelope>,
}

impl InProcessPublisher {
    pub(crate) const fn new(sender: broadcast::Sender<EventEnvelope>) -> Self {
        Self { sender }
    }
}

#[async_trait]
impl EventBusPublisher for InProcessPublisher {
    async fn publish(&self, _topic: &str, event: &EventEnvelope) -> Result<PublishReceipt> {
        self.sender
            .send(event.clone())
            .map_err(|e| RealtimeError::EventBusError(format!("Failed to publish: {e}")))?;
        debug!(
            event_id = %event.event_id,
            topic = %event.topic,
            "Event published to in-process bus"
        );
        Ok(PublishReceipt {
            event_id: event.event_id.clone(),
            sequence: 0,
            delivered_to_bus: true,
        })
    }

    async fn publish_batch(
        &self,
        events: &[(String, EventEnvelope)],
    ) -> Result<Vec<PublishReceipt>> {
        let mut receipts = Vec::with_capacity(events.len());
        for (topic, event) in events {
            receipts.push(self.publish(topic, event).await?);
        }
        Ok(receipts)
    }
}
