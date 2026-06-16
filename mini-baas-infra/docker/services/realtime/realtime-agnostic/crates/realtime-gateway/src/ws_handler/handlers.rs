/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handlers.rs                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

use std::net::SocketAddr;

use bytes::Bytes;
use chrono::Utc;
use realtime_core::{
    filter::FilterExpr, AuthContext, ConnectionId, EventEnvelope, EventSource, PresenceMember,
    ServerMessage, SourceKind, SubscribeItem, Subscription, SubscriptionId, TopicPath, TopicPattern,
};
use smol_str::SmolStr;
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};

use super::reader::{Action, AuthState};
use super::util::{parse_sub_config, send_ctrl};
use super::AppState;

/// Max serialized payload for a client PUBLISH/BROADCAST frame — matches the
/// REST publish limit (`rest_api.rs`) and the protocol's documented ≤64 KB, so
/// the WebSocket path can't bypass the size cap the REST path enforces.
const MAX_WS_PAYLOAD_BYTES: usize = 65_536;
/// Max serialized presence metadata per member — keeps a single TRACK from
/// fanning an oversized blob out to every subscriber on the topic.
const MAX_PRESENCE_META_BYTES: usize = 16_384;

pub(super) async fn handle_auth(
    token: String,
    conn_id: ConnectionId,
    state: &AppState,
    ctrl_tx: &mpsc::Sender<String>,
    auth: &mut AuthState,
) -> Action {
    let ctx = AuthContext {
        peer_addr: SocketAddr::from(([0, 0, 0, 0], 0)),
        transport: "websocket".into(),
    };
    match state.auth_provider.verify(&token, &ctx).await {
        Ok(claims) => {
            auth.authenticated = true;
            auth.claims = Some(claims);
            info!(conn_id = %conn_id, "Client authenticated");
            let msg = ServerMessage::AuthOk {
                conn_id: conn_id.to_string(),
                server_time: Utc::now().to_rfc3339(),
            };
            send_ctrl(ctrl_tx, &msg).await;
            Action::Continue
        }
        Err(e) => {
            warn!(conn_id = %conn_id, "Auth failed: {}", e);
            send_ctrl(ctrl_tx, &ServerMessage::error("AUTH_FAILED", e.to_string())).await;
            Action::Close
        }
    }
}

#[allow(clippy::too_many_arguments, clippy::cognitive_complexity)]
pub(super) async fn handle_subscribe(
    sub_id: String,
    topic: String,
    filter: Option<serde_json::Value>,
    options: Option<realtime_core::SubOptions>,
    conn_id: ConnectionId,
    auth: &AuthState,
    state: &AppState,
    ctrl_tx: &mpsc::Sender<String>,
) -> Action {
    if !auth.authenticated {
        warn!(conn_id = %conn_id, "Subscribe before auth");
        return Action::Continue;
    }
    let pattern = TopicPattern::parse(&topic);
    if let Some(ref c) = auth.claims {
        if state
            .auth_provider
            .authorize_subscribe(c, &pattern)
            .await
            .is_err()
        {
            warn!(conn_id = %conn_id, "Subscribe denied");
            return Action::Continue;
        }
    }
    let sub = Subscription {
        sub_id: SubscriptionId(SmolStr::new(&sub_id)),
        conn_id,
        topic: pattern,
        filter: filter.and_then(|f| FilterExpr::from_json(&f)),
        config: parse_sub_config(options),
    };
    if let Err(e) = state.registry.subscribe(sub, None) {
        warn!(conn_id = %conn_id, sub_id = %sub_id, "Subscribe rejected: {}", e);
        send_ctrl(
            ctrl_tx,
            &ServerMessage::error("CAPACITY_EXCEEDED", e.to_string()),
        )
        .await;
        return Action::Continue;
    }
    debug!(conn_id = %conn_id, sub_id = %sub_id, "Subscribed");
    send_ctrl(ctrl_tx, &ServerMessage::Subscribed { sub_id, seq: 0 }).await;
    Action::Continue
}

pub(super) async fn handle_subscribe_batch(
    subscriptions: Vec<SubscribeItem>,
    conn_id: ConnectionId,
    auth: &AuthState,
    state: &AppState,
    ctrl_tx: &mpsc::Sender<String>,
) -> Action {
    if !auth.authenticated {
        warn!(conn_id = %conn_id, "Subscribe batch before auth");
        return Action::Continue;
    }
    for item in subscriptions {
        let sub = Subscription {
            sub_id: SubscriptionId(SmolStr::new(&item.sub_id)),
            conn_id,
            topic: TopicPattern::parse(&item.topic),
            filter: item.filter.and_then(|f| FilterExpr::from_json(&f)),
            config: parse_sub_config(item.options),
        };
        if let Err(e) = state.registry.subscribe(sub, None) {
            warn!(conn_id = %conn_id, sub_id = %item.sub_id, "Subscribe rejected: {}", e);
            send_ctrl(
                ctrl_tx,
                &ServerMessage::error("CAPACITY_EXCEEDED", e.to_string()),
            )
            .await;
            continue;
        }
        send_ctrl(
            ctrl_tx,
            &ServerMessage::Subscribed {
                sub_id: item.sub_id,
                seq: 0,
            },
        )
        .await;
    }
    Action::Continue
}

pub(super) async fn handle_unsubscribe(
    sub_id: String,
    conn_id: ConnectionId,
    state: &AppState,
    ctrl_tx: &mpsc::Sender<String>,
) -> Action {
    state.registry.unsubscribe(conn_id, &sub_id);
    debug!(conn_id = %conn_id, sub_id = %sub_id, "Unsubscribed");
    send_ctrl(ctrl_tx, &ServerMessage::Unsubscribed { sub_id }).await;
    Action::Continue
}

#[allow(clippy::cognitive_complexity)]
pub(super) async fn handle_publish(
    topic: String,
    event_type: String,
    payload: serde_json::Value,
    conn_id: ConnectionId,
    auth: &AuthState,
    state: &AppState,
) -> Action {
    if !auth.authenticated {
        warn!(conn_id = %conn_id, "Publish before auth");
        return Action::Continue;
    }
    if let Some(ref c) = auth.claims {
        if state
            .auth_provider
            .authorize_publish(c, &TopicPath::new(&topic))
            .await
            .is_err()
        {
            warn!(conn_id = %conn_id, topic = %topic, "Publish denied (namespace)");
            return Action::Continue;
        }
    }
    debug!(conn_id = %conn_id, topic = %topic, event_type = %event_type, "PUBLISH received");
    let payload_bytes = match serde_json::to_vec(&payload) {
        Ok(b) => b,
        Err(e) => {
            warn!(conn_id = %conn_id, "Invalid publish payload: {}", e);
            return Action::Continue;
        }
    };
    if payload_bytes.len() > MAX_WS_PAYLOAD_BYTES {
        warn!(conn_id = %conn_id, len = payload_bytes.len(), "Publish payload too large");
        return Action::Continue;
    }
    let mut envelope = EventEnvelope::new(
        TopicPath::new(&topic),
        &event_type,
        Bytes::from(payload_bytes),
    );
    // Stamp the originating platform user so identity-aware buses (e.g. the IRC
    // bridge) can attribute the event to that user rather than a service nick.
    envelope.source = api_source(auth);
    if let Err(e) = state
        .bus_publisher
        .publish(envelope.topic.as_str(), &envelope)
        .await
    {
        error!(conn_id = %conn_id, "Failed to publish event: {}", e);
    }
    Action::Continue
}

/// Build an [`EventSource`] from the connection's auth claims so identity-aware
/// buses (e.g. the IRC bridge) can attribute the event to the platform user.
fn api_source(auth: &AuthState) -> Option<EventSource> {
    let claims = auth.claims.as_ref()?;
    let mut metadata = std::collections::HashMap::new();
    if let Some(handle) = claims
        .metadata
        .get("handle")
        .or_else(|| claims.metadata.get("name"))
        .or_else(|| claims.metadata.get("preferred_username"))
        .and_then(serde_json::Value::as_str)
    {
        metadata.insert("handle".to_string(), handle.to_string());
    }
    Some(EventSource {
        kind: SourceKind::Api,
        id: claims.sub.clone(),
        metadata,
    })
}

/// Handle a `BROADCAST` client message.
///
/// Broadcast is an ephemeral client→client message: it carries a fixed
/// `event_type` of `"broadcast"`, nests the application `event` label inside
/// the payload, and is published to the [`EventBus`] so every subscriber of
/// `topic` receives it as a normal [`ServerMessage::Event`]. No database is
/// involved. Because it flows over the bus, a multi-node bus delivers it to
/// subscribers on other nodes too.
///
/// [`EventBus`]: realtime_core::EventBus
/// [`ServerMessage::Event`]: realtime_core::ServerMessage
#[allow(clippy::cognitive_complexity)]
pub(super) async fn handle_broadcast(
    topic: String,
    event: String,
    payload: serde_json::Value,
    conn_id: ConnectionId,
    auth: &AuthState,
    state: &AppState,
) -> Action {
    if !auth.authenticated {
        warn!(conn_id = %conn_id, "Broadcast before auth");
        return Action::Continue;
    }
    if let Some(ref c) = auth.claims {
        if state
            .auth_provider
            .authorize_publish(c, &TopicPath::new(&topic))
            .await
            .is_err()
        {
            warn!(conn_id = %conn_id, topic = %topic, "Broadcast denied (namespace)");
            return Action::Continue;
        }
    }
    debug!(conn_id = %conn_id, topic = %topic, event = %event, "BROADCAST received");
    // Wrap the caller payload so receivers can read both the app event label
    // and the body under a stable shape.
    let body = serde_json::json!({ "event": event, "payload": payload });
    let payload_bytes = match serde_json::to_vec(&body) {
        Ok(b) => b,
        Err(e) => {
            warn!(conn_id = %conn_id, "Invalid broadcast payload: {}", e);
            return Action::Continue;
        }
    };
    if payload_bytes.len() > MAX_WS_PAYLOAD_BYTES {
        warn!(conn_id = %conn_id, len = payload_bytes.len(), "Broadcast payload too large");
        return Action::Continue;
    }
    let mut envelope =
        EventEnvelope::new(TopicPath::new(&topic), "broadcast", Bytes::from(payload_bytes));
    envelope.source = api_source(auth);
    if let Err(e) = state
        .bus_publisher
        .publish(envelope.topic.as_str(), &envelope)
        .await
    {
        error!(conn_id = %conn_id, "Failed to publish broadcast: {}", e);
    }
    Action::Continue
}

/// Handle a `TRACK` client message — join (or refresh) a topic's presence set.
///
/// Records this connection as present on `topic`, then publishes the updated
/// member list over the [`EventBus`] (`event_type` `"presence"`) so every
/// subscriber of `topic` receives the change as a normal `EVENT`. The list
/// reflects this node's local membership — see [`PresenceTracker`] for the
/// multi-node caveat.
///
/// [`EventBus`]: realtime_core::EventBus
/// [`PresenceTracker`]: realtime_engine::PresenceTracker
#[allow(clippy::cognitive_complexity)]
pub(super) async fn handle_track(
    topic: String,
    meta: serde_json::Value,
    conn_id: ConnectionId,
    auth: &AuthState,
    state: &AppState,
) -> Action {
    if !auth.authenticated {
        warn!(conn_id = %conn_id, "Track before auth");
        return Action::Continue;
    }
    // Presence is publish-like: a TRACK announces this member to every
    // subscriber of `topic`, so gate it on publish authorization — otherwise a
    // client could inject its identity into another tenant's presence set.
    if let Some(ref c) = auth.claims {
        if state
            .auth_provider
            .authorize_publish(c, &TopicPath::new(&topic))
            .await
            .is_err()
        {
            warn!(conn_id = %conn_id, topic = %topic, "Track denied (namespace)");
            return Action::Continue;
        }
    }
    // Bound the metadata so a single TRACK can't fan an oversized blob to every
    // subscriber on the topic.
    if serde_json::to_vec(&meta).map_or(usize::MAX, |b| b.len()) > MAX_PRESENCE_META_BYTES {
        warn!(conn_id = %conn_id, topic = %topic, "Track meta too large");
        return Action::Continue;
    }
    let member = PresenceMember {
        conn_id: conn_id.to_string(),
        user_id: auth.claims.as_ref().map(|c| c.sub.clone()),
        meta,
    };
    // A5: mirror into the shared (Redis) store BEFORE the local track when the
    // cross-node flag is ON, so a presence query on ANOTHER node sees this member.
    // `None` at parity ⇒ this is skipped entirely (no Redis, byte-identical).
    if let Some(shared) = state.presence_shared.as_ref() {
        shared.track(&topic, &member).await;
    }
    let members = state.presence.track(&topic, conn_id, member);
    debug!(conn_id = %conn_id, topic = %topic, count = members.len(), "TRACK (presence join)");
    publish_presence(&topic, members, auth, state, conn_id).await;
    Action::Continue
}

/// Handle an `UNTRACK` client message — leave a topic's presence set.
pub(super) async fn handle_untrack(
    topic: String,
    conn_id: ConnectionId,
    auth: &AuthState,
    state: &AppState,
) -> Action {
    // A5: drop from the shared store too so a presence query on ANOTHER node no
    // longer lists this member. `None` at parity ⇒ skipped (byte-identical).
    if let Some(shared) = state.presence_shared.as_ref() {
        shared.untrack(&topic, &conn_id.to_string()).await;
    }
    if let Some(members) = state.presence.untrack(&topic, conn_id) {
        debug!(conn_id = %conn_id, topic = %topic, count = members.len(), "UNTRACK (presence leave)");
        publish_presence(&topic, members, auth, state, conn_id).await;
    }
    Action::Continue
}

/// Publish a presence snapshot for `topic` over the bus so all subscribers
/// (local and, on a multi-node bus, remote) receive the change.
async fn publish_presence(
    topic: &str,
    members: Vec<PresenceMember>,
    auth: &AuthState,
    state: &AppState,
    conn_id: ConnectionId,
) {
    let body = serde_json::json!({ "topic": topic, "members": members });
    let payload_bytes = match serde_json::to_vec(&body) {
        Ok(b) => b,
        Err(e) => {
            warn!(conn_id = %conn_id, "Failed to serialize presence payload: {}", e);
            return;
        }
    };
    let mut envelope =
        EventEnvelope::new(TopicPath::new(topic), "presence", Bytes::from(payload_bytes));
    envelope.source = api_source(auth);
    if let Err(e) = state
        .bus_publisher
        .publish(envelope.topic.as_str(), &envelope)
        .await
    {
        error!(conn_id = %conn_id, "Failed to publish presence: {}", e);
    }
}
