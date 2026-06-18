/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   subscriber.rs                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Subscriber side of the in-process bus.

use async_trait::async_trait;
use realtime_core::{EventBusSubscriber, EventEnvelope, EventId, Result};
use tokio::sync::broadcast;

/// Subscriber that holds its own `broadcast::Receiver` cursor.
///
/// If it falls behind, `recv()` returns `Lagged(n)` which the
/// implementation logs and skips past.
pub struct InProcessSubscriber {
    receiver: broadcast::Receiver<EventEnvelope>,
}

impl InProcessSubscriber {
    pub(crate) const fn new(receiver: broadcast::Receiver<EventEnvelope>) -> Self {
        Self { receiver }
    }
}

#[async_trait]
impl EventBusSubscriber for InProcessSubscriber {
    async fn next_event(&mut self) -> Option<EventEnvelope> {
        loop {
            match self.receiver.recv().await {
                Ok(event) => return Some(event),
                Err(broadcast::error::RecvError::Lagged(n)) => {
                    tracing::warn!("In-process subscriber lagged behind by {} messages", n);
                }
                Err(broadcast::error::RecvError::Closed) => {
                    return None;
                }
            }
        }
    }

    async fn ack(&self, _event_id: &EventId) -> Result<()> {
        Ok(())
    }

    async fn nack(&self, _event_id: &EventId) -> Result<()> {
        Ok(())
    }
}
