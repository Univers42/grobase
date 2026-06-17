//! Publisher side: gateway PUBLISH -> IRC.
//!
//! Events that carry a user `EventSource` (`kind = Api`) are posted through that
//! user's own IRC session (their nick); everything else (platform events with no
//! user, CDC, scheduler, ...) goes out on the shared service connection.

use std::sync::Arc;

use async_trait::async_trait;
use realtime_core::{
    EventBusPublisher, EventEnvelope, PublishReceipt, RealtimeError, Result, SourceKind,
};
use tokio::sync::mpsc;

use crate::mapping::topic_to_channel;
use crate::session_manager::SessionManager;

/// Publishes events onto IRC, choosing the per-user or service identity.
pub struct IrcPublisher {
    service_tx: mpsc::Sender<String>,
    manager: Arc<SessionManager>,
    namespace: String,
}

impl IrcPublisher {
    pub(crate) const fn new(
        service_tx: mpsc::Sender<String>,
        manager: Arc<SessionManager>,
        namespace: String,
    ) -> Self {
        Self {
            service_tx,
            manager,
            namespace,
        }
    }
}

/// Extract a human-readable message from an event payload.
///
/// Accepts a bare JSON string, a `{ "text": "..." }` object, or falls back to
/// the lossy UTF-8 rendering of the raw bytes.
fn payload_text(event: &EventEnvelope) -> String {
    if let Ok(value) = serde_json::from_slice::<serde_json::Value>(&event.payload) {
        if let Some(s) = value.as_str() {
            return s.to_string();
        }
        if let Some(s) = value.get("text").and_then(serde_json::Value::as_str) {
            return s.to_string();
        }
        return value.to_string();
    }
    String::from_utf8_lossy(&event.payload).to_string()
}

#[async_trait]
impl EventBusPublisher for IrcPublisher {
    async fn publish(&self, topic: &str, event: &EventEnvelope) -> Result<PublishReceipt> {
        let Some(channel) = topic_to_channel(topic, &self.namespace) else {
            // Outside the bridged namespace: nothing to do on IRC.
            return Ok(PublishReceipt {
                event_id: event.event_id.clone(),
                sequence: event.sequence,
                delivered_to_bus: false,
            });
        };

        let text = payload_text(event);

        match &event.source {
            // A platform user (the gateway stamps kind = Api with the user id).
            Some(src) if src.kind == SourceKind::Api && !src.id.is_empty() => {
                let handle = src.metadata.get("handle").map_or("", String::as_str);
                self.manager
                    .publish_as_user(&src.id, handle, &channel, &text)
                    .await;
            }
            // Platform event / system source: post on the shared service nick,
            // tagged with the event type.
            _ => {
                let body = if event.event_type.is_empty() {
                    text
                } else {
                    format!("[{}] {}", event.event_type, text)
                };
                self.service_tx
                    .send(format!("PRIVMSG {channel} :{body}"))
                    .await
                    .map_err(|e| {
                        RealtimeError::EventBusError(format!("IRC session unavailable: {e}"))
                    })?;
            }
        }

        Ok(PublishReceipt {
            event_id: event.event_id.clone(),
            sequence: event.sequence,
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
