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

//! Async Rust client SDK for the realtime server.
//!
//! Provides [`RealtimeClient`] with automatic reconnection,
//! transparent re-subscription, and sliding-window deduplication.

mod builder;
mod event_loop;

pub use builder::RealtimeClientBuilder;

use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

use realtime_core::ClientMessage;
use tokio::sync::{mpsc, Mutex, RwLock};
use tokio_tungstenite::tungstenite::protocol::Message;

/// Internal subscription state tracked for transparent re-subscription.
#[derive(Debug, Clone)]
pub struct SubscriptionState {
    pub sub_id: String,
    pub topic: String,
    pub filter: Option<serde_json::Value>,
    pub last_sequence: Option<u64>,
}

/// Realtime client SDK with automatic reconnection and deduplication.
///
/// After calling [`connect()`](Self::connect), the client runs its event loop
/// in a background Tokio task. Events arrive on the returned `mpsc::Receiver`.
pub struct RealtimeClient {
    pub(crate) url: String,
    pub(crate) token: String,
    pub(crate) reconnect_enabled: bool,
    pub(crate) max_reconnect_delay: Duration,
    pub(crate) subscriptions: Arc<RwLock<Vec<SubscriptionState>>>,
    pub(crate) event_tx: Arc<RwLock<Option<mpsc::Sender<Message>>>>,
    pub(crate) connected: Arc<RwLock<bool>>,
    pub(crate) seen_event_ids: Arc<Mutex<HashSet<String>>>,
}

impl RealtimeClient {
    /// Shorthand for `RealtimeClientBuilder::new(url)`.
    pub fn builder(url: impl Into<String>) -> RealtimeClientBuilder {
        RealtimeClientBuilder::new(url)
    }

    /// Subscribe to a topic.
    ///
    /// The subscription is recorded locally so it persists across reconnections.
    ///
    /// # Errors
    ///
    /// Returns an error if the subscription message cannot be sent.
    pub async fn subscribe(
        &self,
        sub_id: impl Into<String>,
        topic: impl Into<String>,
        filter: Option<serde_json::Value>,
    ) -> anyhow::Result<()> {
        let sub_id = sub_id.into();
        let topic = topic.into();
        self.store_subscription(&sub_id, &topic, filter.as_ref())
            .await;
        self.send_subscribe(&sub_id, &topic, filter.as_ref()).await
    }

    /// Unsubscribe from a subscription by its `sub_id`.
    ///
    /// # Errors
    ///
    /// Returns an error if the unsubscribe message cannot be sent.
    pub async fn unsubscribe(&self, sub_id: &str) -> anyhow::Result<()> {
        self.remove_subscription(sub_id).await;
        self.send_unsubscribe(sub_id).await
    }

    /// Returns `true` if the WebSocket connection is currently active.
    pub async fn is_connected(&self) -> bool {
        *self.connected.read().await
    }
}

impl RealtimeClient {
    async fn store_subscription(
        &self,
        sub_id: &str,
        topic: &str,
        filter: Option<&serde_json::Value>,
    ) {
        let mut subs = self.subscriptions.write().await;
        subs.push(SubscriptionState {
            sub_id: sub_id.to_string(),
            topic: topic.to_string(),
            filter: filter.cloned(),
            last_sequence: None,
        });
    }

    async fn send_subscribe(
        &self,
        sub_id: &str,
        topic: &str,
        filter: Option<&serde_json::Value>,
    ) -> anyhow::Result<()> {
        if let Some(ref tx) = *self.event_tx.read().await {
            let msg = ClientMessage::Subscribe {
                sub_id: sub_id.to_string(),
                topic: topic.to_string(),
                filter: filter.cloned(),
                options: None,
            };
            let json = serde_json::to_string(&msg)?;
            tx.send(Message::Text(json)).await?;
        }
        Ok(())
    }

    async fn remove_subscription(&self, sub_id: &str) {
        let mut subs = self.subscriptions.write().await;
        subs.retain(|s| s.sub_id != sub_id);
    }

    async fn send_unsubscribe(&self, sub_id: &str) -> anyhow::Result<()> {
        if let Some(ref tx) = *self.event_tx.read().await {
            let msg = ClientMessage::Unsubscribe {
                sub_id: sub_id.to_string(),
            };
            let json = serde_json::to_string(&msg)?;
            tx.send(Message::Text(json)).await?;
        }
        Ok(())
    }
}
