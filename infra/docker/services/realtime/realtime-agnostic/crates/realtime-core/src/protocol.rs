/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   protocol.rs                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/04/07 11:11:41 by dlesieur          #+#    #+#             */
/*   Updated: 2026/04/07 23:40:36 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! WebSocket and REST API protocol definitions.
//!
//! This module defines every message type that flows over the wire between
//! clients and the server. WebSocket messages use JSON with a `"type"` tag
//! for discriminated dispatch.
//!
//! ## WebSocket message flow
//!
//! ```text
//! Client                         Server
//!   │── AUTH {token} ──────────►│
//!   │◄── AUTH_OK {conn_id} ─────│
//!   │── SUBSCRIBE {sub_id} ───►│
//!   │◄── SUBSCRIBED {sub_id} ──│
//!   │◄── EVENT {sub_id, ...} ──│  (repeated)
//!   │── PING ────────────────►│
//!   │◄── PONG ───────────────│
//! ```

use crate::types::{EventEnvelope, EventSource};
use serde::{Deserialize, Serialize};

/// Messages sent from a client to the server over WebSocket.
///
/// Serialized as JSON with an internally-tagged `"type"` discriminator:
/// ```json
/// { "type": "SUBSCRIBE", "sub_id": "s1", "topic": "orders/*" }
/// ```
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ClientMessage {
    /// Authenticate the connection with a bearer token.
    /// Must be the **first** message sent after the WebSocket handshake.
    #[serde(rename = "AUTH")]
    Auth { token: String },

    /// Subscribe to events matching a topic pattern.
    #[serde(rename = "SUBSCRIBE")]
    Subscribe {
        /// Client-chosen subscription identifier (scoped to this connection).
        sub_id: String,
        /// Topic pattern string (parsed via [`TopicPattern::parse()`]).
        topic: String,
        /// Optional server-side filter expression (JSON).
        #[serde(default)]
        filter: Option<serde_json::Value>,
        /// Optional subscription configuration.
        #[serde(default)]
        options: Option<SubOptions>,
    },

    /// Subscribe to multiple topics in a single message.
    ///
    /// More efficient than sending N individual `SUBSCRIBE` messages
    /// because the engine batches the registry insertions.
    #[serde(rename = "SUBSCRIBE_BATCH")]
    SubscribeBatch { subscriptions: Vec<SubscribeItem> },

    /// Unsubscribe from a previously-created subscription.
    #[serde(rename = "UNSUBSCRIBE")]
    Unsubscribe { sub_id: String },

    /// Publish an ephemeral event directly over WebSocket.
    ///
    /// Used for low-latency events like cursor positions and typing
    /// indicators that don't need to go through the REST API.
    #[serde(rename = "PUBLISH")]
    Publish {
        /// Target topic path.
        topic: String,
        /// Semantic event type (e.g. `"cursor_move"`).
        event_type: String,
        /// JSON payload (must be ≤64 KB when serialized).
        payload: serde_json::Value,
    },

    /// Broadcast an ephemeral client→client message to every subscriber of a
    /// topic. Unlike [`ClientMessage::Publish`], a broadcast carries a fixed
    /// `event_type` of `"broadcast"` and an application-chosen `event` label
    /// nested inside the payload, mirroring the Supabase "broadcast channel"
    /// surface. No database is involved — the message flows over the `EventBus`
    /// and is delivered to topic subscribers as a normal [`ServerMessage::Event`].
    ///
    /// Because it travels over the bus, broadcast is multi-node-capable by
    /// construction: a client connected to node A reaches subscribers on node B
    /// whenever the bus is a multi-node implementation (e.g. the IRC bus).
    #[serde(rename = "BROADCAST")]
    Broadcast {
        /// Target topic path (subscribers of this topic receive the message).
        topic: String,
        /// Application-defined event label, surfaced under `payload.event`.
        event: String,
        /// JSON payload (must be ≤64 KB when serialized).
        payload: serde_json::Value,
    },

    /// Begin (or refresh) presence tracking for a topic.
    ///
    /// The connection is recorded as a member of the topic's presence set;
    /// the server emits a [`ServerMessage::Presence`] snapshot to every
    /// presence-tracking subscriber whenever the membership changes, and a
    /// `LEAVE` is emitted automatically when the connection unsubscribes or
    /// disconnects. `meta` is opaque application state (e.g. cursor color,
    /// display name) echoed back to other members.
    #[serde(rename = "TRACK")]
    Track {
        /// Topic whose presence set this connection joins.
        topic: String,
        /// Opaque per-member metadata echoed to other members.
        #[serde(default)]
        meta: serde_json::Value,
    },

    /// Stop presence tracking for a topic (explicit leave). A subsequent
    /// disconnect is idempotent.
    #[serde(rename = "UNTRACK")]
    Untrack {
        /// Topic whose presence set this connection leaves.
        topic: String,
    },

    /// Keepalive ping. Server responds with [`ServerMessage::Pong`].
    #[serde(rename = "PING")]
    Ping,
}

/// Optional subscription configuration sent alongside `SUBSCRIBE`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubOptions {
    /// Overflow policy name (`"drop_oldest"`, `"drop_newest"`, `"disconnect"`).
    #[serde(default)]
    pub overflow: Option<String>,
    /// Resume from this sequence number (for client reconnection).
    pub resume_from: Option<u64>,
    /// Maximum events per second for this subscription.
    pub rate_limit: Option<u32>,
}

/// A single item in a [`ClientMessage::SubscribeBatch`] request.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubscribeItem {
    /// Client-chosen subscription ID.
    pub sub_id: String,
    /// Topic pattern string.
    pub topic: String,
    /// Optional server-side filter.
    #[serde(default)]
    pub filter: Option<serde_json::Value>,
    /// Optional subscription configuration.
    #[serde(default)]
    pub options: Option<SubOptions>,
}

/// Messages sent from the server to a client over WebSocket.
///
/// Serialized as JSON with an internally-tagged `"type"` discriminator.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ServerMessage {
    /// Authentication succeeded. Sent exactly once per connection.
    #[serde(rename = "AUTH_OK")]
    AuthOk {
        /// The server-assigned connection ID (for debugging).
        conn_id: String,
        /// Server timestamp (ISO 8601) for clock-sync reference.
        server_time: String,
    },

    /// Subscription created successfully.
    #[serde(rename = "SUBSCRIBED")]
    Subscribed {
        /// Echoes the client's subscription ID.
        sub_id: String,
        /// Current topic sequence at subscribe time (for gap detection).
        seq: u64,
    },

    /// Subscription removed successfully.
    #[serde(rename = "UNSUBSCRIBED")]
    Unsubscribed { sub_id: String },

    /// An event delivery, tagged with the matching subscription ID.
    #[serde(rename = "EVENT")]
    Event {
        /// Which subscription matched this event.
        sub_id: String,
        /// The event payload.
        event: EventPayload,
    },

    /// A presence snapshot for a topic, emitted whenever the topic's presence
    /// set changes (a member joins, leaves, or disconnects). The `members`
    /// list is the **current** authoritative set as seen by this node.
    #[serde(rename = "PRESENCE")]
    Presence {
        /// Topic the presence set belongs to.
        topic: String,
        /// Current members of the topic's presence set.
        members: Vec<PresenceMember>,
    },

    /// Keepalive response to a client `PING`.
    #[serde(rename = "PONG")]
    Pong {
        /// Server timestamp.
        server_time: String,
    },

    /// Error response.
    #[serde(rename = "ERROR")]
    Error {
        /// Machine-readable error code (e.g. `"AUTH_FAILED"`, `"PAYLOAD_TOO_LARGE"`).
        code: String,
        /// Human-readable error description.
        message: String,
    },
}

/// Flattened event payload for JSON wire transfer.
///
/// This is a serialization-friendly projection of [`EventEnvelope`]
/// where all fields are primitive types (strings, numbers). The
/// binary `Bytes` payload is deserialized into a `serde_json::Value`
/// so it appears inline in the JSON frame.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EventPayload {
    /// `UUIDv7` event identifier (as string).
    pub event_id: String,
    /// Topic path string.
    pub topic: String,
    /// Semantic event type.
    pub event_type: String,
    /// Per-topic sequence number.
    pub sequence: u64,
    /// Server timestamp (RFC 3339).
    pub timestamp: String,
    /// Deserialized JSON payload.
    pub payload: serde_json::Value,
}

impl EventPayload {
    /// Convert an [`EventEnvelope`] into a wire-format [`EventPayload`].
    ///
    /// The binary payload is deserialized into a JSON value. If the
    /// payload is not valid JSON, it falls back to `null`.
    pub fn from_envelope(envelope: &EventEnvelope) -> Self {
        let payload = serde_json::from_slice(&envelope.payload).unwrap_or(serde_json::Value::Null);

        Self {
            event_id: envelope.event_id.to_string(),
            topic: envelope.topic.to_string(),
            event_type: envelope.event_type.clone(),
            sequence: envelope.sequence,
            timestamp: envelope.timestamp.to_rfc3339(),
            payload,
        }
    }
}

/// A single member of a topic's presence set.
///
/// Identifies the underlying connection plus the authenticated user (when the
/// auth provider supplied a subject) and any opaque application metadata the
/// member supplied via [`ClientMessage::Track`].
// `Eq` is intentionally NOT derived: the `meta` field is a `serde_json::Value`,
// which is only `PartialEq` (it can hold floats). `PartialEq` is enough for the
// presence-set tests.
#[allow(clippy::derive_partial_eq_without_eq)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PresenceMember {
    /// Stable per-connection identifier (string form of `ConnectionId`).
    pub conn_id: String,
    /// Authenticated subject (JWT `sub`) when known, else `None`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user_id: Option<String>,
    /// Opaque per-member metadata supplied at track time.
    #[serde(default, skip_serializing_if = "serde_json::Value::is_null")]
    pub meta: serde_json::Value,
}

/// REST API request body for publishing a single event.
///
/// Sent as JSON to `POST /api/events`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PublishRequest {
    /// Target topic path.
    pub topic: String,
    /// Semantic event type.
    pub event_type: String,
    /// JSON payload (max 64 KB when serialized).
    pub payload: serde_json::Value,
    /// Optional idempotency key for exactly-once delivery.
    #[serde(default)]
    pub idempotency_key: Option<String>,
    /// Optional event source metadata.
    #[serde(default)]
    pub source: Option<EventSource>,
    /// Optional TTL in milliseconds for ephemeral events.
    #[serde(default)]
    pub ttl_ms: Option<u32>,
}

/// REST API request body for publishing multiple events atomically.
///
/// Sent as JSON to `POST /api/events/batch`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BatchPublishRequest {
    /// Array of publish requests.
    pub events: Vec<PublishRequest>,
}

/// REST API response for a single publish operation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PublishResponse {
    /// Assigned `UUIDv7` event ID.
    pub event_id: String,
    /// Assigned per-topic sequence number.
    pub sequence: u64,
    /// Whether the event was delivered to the event bus.
    pub delivered_to_bus: bool,
}

/// REST API response for a batch publish operation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BatchPublishResponse {
    /// One response per event in the batch.
    pub results: Vec<PublishResponse>,
}

/// Response from the `GET /health` endpoint.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthResponse {
    /// `"ok"` or `"degraded"`.
    pub status: String,
    /// Number of active WebSocket connections.
    pub connections: u64,
    /// Number of active subscriptions across all connections.
    pub subscriptions: u64,
    /// Server uptime in seconds.
    pub uptime_seconds: u64,
    /// Filter-index telemetry snapshot (present when engine stats are available).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub filter_index: Option<serde_json::Value>,
    /// Dispatch-pipeline telemetry snapshot.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dispatch: Option<serde_json::Value>,
}

impl ServerMessage {
    /// Convenience constructor for error messages.
    ///
    /// # Arguments
    ///
    /// * `code` — Machine-readable error code (e.g. `"AUTH_FAILED"`).
    /// * `message` — Human-readable description.
    pub fn error(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self::Error {
            code: code.into(),
            message: message.into(),
        }
    }
}
