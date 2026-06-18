/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   event_loop.rs                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! WebSocket event loop with reconnection, dedup, and re-subscribe logic.

use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

use futures::{SinkExt, StreamExt};
use realtime_core::{ClientMessage, EventPayload, ServerMessage};
use tokio::sync::{mpsc, Mutex, RwLock};
use tokio_tungstenite::{connect_async, tungstenite::protocol::Message};
use tracing::{debug, error, info, warn};

use super::{RealtimeClient, SubscriptionState};

impl RealtimeClient {
    /// Connect to the server and start the background event loop.
    ///
    /// Returns an `mpsc::Receiver<EventPayload>` that delivers deduplicated events.
    ///
    /// # Errors
    ///
    /// Returns an error if the background event loop cannot be started.
    pub fn connect(&self) -> anyhow::Result<mpsc::Receiver<EventPayload>> {
        let (event_tx, event_rx) = mpsc::channel::<EventPayload>(1024);
        let ctx = ConnectionContext {
            url: self.url.clone(),
            token: self.token.clone(),
            subscriptions: Arc::clone(&self.subscriptions),
            connected: Arc::clone(&self.connected),
            seen_ids: Arc::clone(&self.seen_event_ids),
            reconnect_enabled: self.reconnect_enabled,
            max_delay: self.max_reconnect_delay,
            ws_tx_holder: Arc::clone(&self.event_tx),
        };
        tokio::spawn(connection_loop(ctx, event_tx));
        Ok(event_rx)
    }
}

struct ConnectionContext {
    url: String,
    token: String,
    subscriptions: Arc<RwLock<Vec<SubscriptionState>>>,
    connected: Arc<RwLock<bool>>,
    seen_ids: Arc<Mutex<HashSet<String>>>,
    reconnect_enabled: bool,
    max_delay: Duration,
    ws_tx_holder: Arc<RwLock<Option<mpsc::Sender<Message>>>>,
}

async fn connection_loop(ctx: ConnectionContext, event_tx: mpsc::Sender<EventPayload>) {
    let mut attempt = 0u32;
    loop {
        match handle_session(&ctx, &event_tx).await {
            Ok(()) => {
                attempt = 0;
            }
            Err(e) => {
                error!("Connection failed: {e}");
            }
        }
        *ctx.connected.write().await = false;
        if !ctx.reconnect_enabled {
            break;
        }
        attempt += 1;
        let delay = backoff_delay(attempt, ctx.max_delay);
        warn!("Reconnecting in {delay:?} (attempt {attempt})");
        tokio::time::sleep(delay).await;
    }
}

async fn handle_session(
    ctx: &ConnectionContext,
    event_tx: &mpsc::Sender<EventPayload>,
) -> anyhow::Result<()> {
    let (ws_stream, _) = connect_async(&ctx.url).await?;
    *ctx.connected.write().await = true;
    info!("Connected to {}", ctx.url);
    let (mut write, mut read) = ws_stream.split();
    send_auth(&mut write, &ctx.token).await?;
    let (tx, mut rx) = mpsc::channel::<Message>(256);
    *ctx.ws_tx_holder.write().await = Some(tx);
    resubscribe(&mut write, &ctx.subscriptions).await;
    let write = Arc::new(Mutex::new(write));
    let write_clone = Arc::clone(&write);
    let fwd = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            let mut w = write_clone.lock().await;
            if w.send(msg).await.is_err() {
                break;
            }
        }
    });
    process_incoming(&mut read, event_tx, &ctx.seen_ids, &ctx.subscriptions).await;
    fwd.abort();
    Ok(())
}

async fn send_auth<S>(write: &mut S, token: &str) -> anyhow::Result<()>
where
    S: futures::Sink<Message> + Unpin,
    S::Error: std::error::Error + Send + Sync + 'static,
{
    let auth_msg = ClientMessage::Auth {
        token: token.to_string(),
    };
    let auth_json = serde_json::to_string(&auth_msg)?;
    write.send(Message::Text(auth_json)).await?;
    Ok(())
}

async fn resubscribe<S>(write: &mut S, subscriptions: &Arc<RwLock<Vec<SubscriptionState>>>)
where
    S: futures::Sink<Message> + Unpin,
    S::Error: std::error::Error + Send + Sync + 'static,
{
    let subs = subscriptions.read().await;
    for sub in subs.iter() {
        let msg = ClientMessage::Subscribe {
            sub_id: sub.sub_id.clone(),
            topic: sub.topic.clone(),
            filter: sub.filter.clone(),
            options: sub.last_sequence.map(|seq| realtime_core::SubOptions {
                overflow: None,
                resume_from: Some(seq),
                rate_limit: None,
            }),
        };
        if let Ok(json) = serde_json::to_string(&msg) {
            let _ = write.send(Message::Text(json)).await;
        }
    }
}

async fn process_incoming<S>(
    read: &mut S,
    event_tx: &mpsc::Sender<EventPayload>,
    seen_ids: &Arc<Mutex<HashSet<String>>>,
    subscriptions: &Arc<RwLock<Vec<SubscriptionState>>>,
) where
    S: futures::Stream<Item = std::result::Result<Message, tokio_tungstenite::tungstenite::Error>>
        + Unpin,
{
    while let Some(msg) = read.next().await {
        match msg {
            Ok(Message::Text(text)) => {
                handle_text_message(&text, event_tx, seen_ids, subscriptions).await;
            }
            Ok(Message::Close(_)) => {
                warn!("WebSocket closed");
                break;
            }
            Err(e) => {
                error!("WebSocket error: {e}");
                break;
            }
            _ => {}
        }
    }
}

#[allow(clippy::cognitive_complexity)]
async fn handle_text_message(
    text: &str,
    event_tx: &mpsc::Sender<EventPayload>,
    seen_ids: &Arc<Mutex<HashSet<String>>>,
    subscriptions: &Arc<RwLock<Vec<SubscriptionState>>>,
) {
    let Ok(server_msg) = serde_json::from_str::<ServerMessage>(text) else {
        return;
    };
    match server_msg {
        ServerMessage::Event { sub_id, event } => {
            if dedup_check(seen_ids, &event.event_id).await {
                debug!("Duplicate event {}, skipping", event.event_id);
                return;
            }
            update_sequence(subscriptions, &sub_id, event.sequence).await;
            if event_tx.send(event).await.is_err() {
                info!("Event receiver dropped");
            }
        }
        ServerMessage::AuthOk { conn_id, .. } => {
            info!("Authenticated as {conn_id}");
        }
        ServerMessage::Error { code, message } => {
            error!("Server error: {code} - {message}");
        }
        _ => {}
    }
}

async fn dedup_check(seen_ids: &Arc<Mutex<HashSet<String>>>, event_id: &str) -> bool {
    let mut seen = seen_ids.lock().await;
    if seen.contains(event_id) {
        return true;
    }
    seen.insert(event_id.to_string());
    if seen.len() > 1000 {
        let to_remove: Vec<String> = seen.iter().take(500).cloned().collect();
        for id in to_remove {
            seen.remove(&id);
        }
    }
    false
}

async fn update_sequence(
    subscriptions: &Arc<RwLock<Vec<SubscriptionState>>>,
    sub_id: &str,
    sequence: u64,
) {
    let mut subs = subscriptions.write().await;
    if let Some(s) = subs.iter_mut().find(|s| s.sub_id == sub_id) {
        s.last_sequence = Some(sequence);
    }
}

fn backoff_delay(attempt: u32, max_delay: Duration) -> Duration {
    let base = Duration::from_millis(100 * 2u64.pow(attempt.min(10)));
    let jitter = Duration::from_millis(rand::random::<u64>() % 500);
    (base + jitter).min(max_delay)
}
