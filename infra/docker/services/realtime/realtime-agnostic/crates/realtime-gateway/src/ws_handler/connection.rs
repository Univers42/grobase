/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   connection.rs                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};

use axum::extract::ws::WebSocket;
use bytes::Bytes;
use chrono::Utc;
use futures::StreamExt;
use realtime_core::{
    ConnectionId, ConnectionMeta, EventBusPublisher, EventEnvelope, OverflowPolicy, PresenceMember,
    TopicPath,
};
use realtime_engine::PresenceTracker;
use tokio::sync::mpsc;
use tracing::{error, info};

use super::reader::reader_loop;
use super::writer::writer_loop;
use super::AppState;
use crate::usage::{Usage, CONNECTION_SECONDS};

fn default_peer_addr() -> SocketAddr {
    SocketAddr::from(([0, 0, 0, 0], 0))
}

fn create_connection_meta(conn_id: ConnectionId) -> ConnectionMeta {
    ConnectionMeta {
        conn_id,
        peer_addr: default_peer_addr(),
        connected_at: Utc::now(),
        user_id: None,
        claims: None,
    }
}

pub async fn handle_websocket(socket: WebSocket, state: AppState) {
    let conn_id = state.conn_manager.next_connection_id();
    let meta = create_connection_meta(conn_id);
    // Stamp the open instant locally so the close path computes the lifetime even
    // if the registry's `connected_at` is unavailable later.
    let connected_at = meta.connected_at;
    let (_, send_rx) = state
        .conn_manager
        .register(meta, OverflowPolicy::DropNewest);
    let (ws_sink, ws_stream) = socket.split();
    let (ctrl_tx, ctrl_rx) = mpsc::channel::<String>(64);
    let registry = Arc::clone(&state.registry);
    let conn_manager = Arc::clone(&state.conn_manager);
    let presence = Arc::clone(&state.presence);
    let presence_shared = state.presence_shared.clone();
    let bus_publisher = Arc::clone(&state.bus_publisher);
    let usage = state.usage.clone();
    // The reader stamps the authenticated platform user/tenant here on AUTH; the
    // close path below reads it to attribute the connection-lifetime metric.
    let tenant_slot: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let writer = tokio::spawn(writer_loop(ws_sink, send_rx, ctrl_rx, conn_id));
    let reader = tokio::spawn(reader_loop(
        ws_stream,
        conn_id,
        state,
        ctrl_tx,
        Arc::clone(&tenant_slot),
    ));
    tokio::select! {
        _ = writer => {}
        _ = reader => {}
    }
    // A5: drop this connection from the shared (Redis) store too, so a presence
    // query on ANOTHER node stops listing it the moment this node sees the
    // disconnect. `None` at parity ⇒ skipped (byte-identical).
    if let Some(shared) = presence_shared.as_ref() {
        shared.remove_connection(&conn_id.to_string()).await;
    }
    // Emit a presence LEAVE for every topic this connection was tracking, then
    // tear down its subscriptions. Done before `remove_connection` so the
    // published snapshots reflect the post-departure membership.
    cleanup_presence(conn_id, &presence, bus_publisher.as_ref()).await;
    registry.remove_connection(conn_id);
    conn_manager.remove(conn_id);
    // B1d metering — record the connection lifetime in whole seconds for the
    // authenticated tenant. Only when metering is ON (`usage` is `Some`) AND the
    // connection actually authenticated (an unauthenticated probe has no tenant
    // and is not billable). At parity (`usage` is `None`) this whole block is
    // skipped, byte-identical to before.
    if let Some(usage) = usage.as_ref() {
        meter_connection_lifetime(usage, &tenant_slot, connected_at, conn_id);
    }
    info!(conn_id = %conn_id, "WebSocket connection closed");
}

/// Compute the connection lifetime in WHOLE seconds and record it against the
/// authenticated tenant. Unauthenticated connections (empty slot) are skipped —
/// the metric is per platform user/tenant, matching the `EventSource` identity.
fn meter_connection_lifetime(
    usage: &Usage,
    tenant_slot: &Arc<Mutex<Option<String>>>,
    connected_at: chrono::DateTime<Utc>,
    conn_id: ConnectionId,
) {
    let tenant = match tenant_slot.lock() {
        Ok(slot) => slot.clone(),
        Err(p) => p.into_inner().clone(),
    };
    let Some(tenant) = tenant else {
        return; // never authenticated → no tenant → nothing to meter
    };
    // Whole seconds of lifetime; clamp negatives (clock skew) to 0.
    let secs = (Utc::now() - connected_at).num_seconds().max(0);
    let secs = u64::try_from(secs).unwrap_or(0);
    usage.record(&tenant, CONNECTION_SECONDS, secs);
    info!(
        conn_id = %conn_id,
        tenant = %tenant,
        seconds = secs,
        "metered realtime.connection.seconds"
    );
}

/// On disconnect, drop the connection from every presence set it joined and
/// publish a fresh snapshot per affected topic over the bus so remaining
/// subscribers (local and remote) observe the leave.
async fn cleanup_presence(
    conn_id: ConnectionId,
    presence: &PresenceTracker,
    bus_publisher: &dyn EventBusPublisher,
) {
    for (topic, members) in presence.remove_connection(conn_id) {
        publish_presence_snapshot(&topic, &members, bus_publisher, conn_id).await;
    }
}

/// Publish a presence snapshot (`event_type` `"presence"`) for a topic.
async fn publish_presence_snapshot(
    topic: &str,
    members: &[PresenceMember],
    bus_publisher: &dyn EventBusPublisher,
    conn_id: ConnectionId,
) {
    let body = serde_json::json!({ "topic": topic, "members": members });
    let Ok(payload_bytes) = serde_json::to_vec(&body) else {
        return;
    };
    let envelope =
        EventEnvelope::new(TopicPath::new(topic), "presence", Bytes::from(payload_bytes));
    if let Err(e) = bus_publisher.publish(topic, &envelope).await {
        error!(conn_id = %conn_id, "Failed to publish presence on disconnect: {}", e);
    }
}
