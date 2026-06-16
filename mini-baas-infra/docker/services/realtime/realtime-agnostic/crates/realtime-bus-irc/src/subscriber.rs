//! Subscriber side: IRC PRIVMSG -> gateway EVENT.

use async_trait::async_trait;
use realtime_core::{EventBusSubscriber, EventEnvelope, EventId, Result};
use tokio::sync::broadcast;
use tokio::sync::broadcast::error::RecvError;
use tracing::warn;

/// Receives IRC-originated events from the session task's broadcast channel.
pub struct IrcSubscriber {
    rx: broadcast::Receiver<EventEnvelope>,
}

impl IrcSubscriber {
    pub(crate) const fn new(rx: broadcast::Receiver<EventEnvelope>) -> Self {
        Self { rx }
    }
}

#[async_trait]
impl EventBusSubscriber for IrcSubscriber {
    async fn next_event(&mut self) -> Option<EventEnvelope> {
        loop {
            match self.rx.recv().await {
                Ok(event) => return Some(event),
                Err(RecvError::Lagged(skipped)) => {
                    warn!(skipped, "IRC subscriber lagged; dropped events");
                }
                Err(RecvError::Closed) => return None,
            }
        }
    }

    async fn ack(&self, _event_id: &EventId) -> Result<()> {
        Ok(()) // fire-and-forget bus: nothing to acknowledge
    }

    async fn nack(&self, _event_id: &EventId) -> Result<()> {
        Ok(())
    }
}
