/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   auth_claims.rs                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::SocketAddr;

use super::{ConnectionId, EventId, TopicPath, TopicPattern};

/// Metadata tracked for each active WebSocket connection.
///
/// # Purpose
/// Stored in the gateway's `ConnectionManager` for the lifetime
/// of the connection. Used for auth, logging, and admin introspection.
#[derive(Debug, Clone)]
pub struct ConnectionMeta {
    /// Unique connection identifier.
    pub conn_id: ConnectionId,
    /// Remote IP:port of the client.
    pub peer_addr: SocketAddr,
    /// When the WebSocket handshake completed.
    pub connected_at: DateTime<Utc>,
    /// Subject claim from the auth token.
    pub user_id: Option<String>,
    /// Full decoded auth claims.
    pub claims: Option<AuthClaims>,
}

/// Authentication claims extracted from a client's token.
///
/// # Purpose
/// Decoded by an `AuthProvider` during the AUTH handshake.
/// Controls which namespaces the client can access.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthClaims {
    /// Subject (user identifier).
    pub sub: String,
    /// Allowed namespaces. DENY-BY-DEFAULT: an EMPTY list grants NO access
    /// (Phase 5 security baseline). All-access is expressed EXPLICITLY as
    /// `["*"]` (the `NoAuth` provider, or the JWT provider's one-release
    /// permissive fallback). This closes the hole where a namespace-less token
    /// could subscribe/publish to every tenant's channels.
    pub namespaces: Vec<String>,
    /// Whether the client can publish events.
    pub can_publish: bool,
    /// Whether the client can subscribe to topics.
    pub can_subscribe: bool,
    /// Additional metadata from the token.
    #[serde(default)]
    pub metadata: HashMap<String, serde_json::Value>,
}

impl AuthClaims {
    /// Whether these claims allow subscribing to `topic`. Deny-by-default: an
    /// empty namespace list grants nothing; all-access is the explicit `"*"`.
    #[must_use]
    pub fn can_subscribe_to(&self, topic: &TopicPattern) -> bool {
        self.can_subscribe_to_scoped(topic, &[])
    }

    /// Like [`Self::can_subscribe_to`], but a `"*"` wildcard does NOT cover a
    /// namespace whose prefix is in `protected` — those require an EXACT grant
    /// (a wildcard token must not reach a `collab:` space it was not explicitly
    /// granted). An empty `protected` slice is byte-identical to the plain check.
    #[must_use]
    pub fn can_subscribe_to_scoped(&self, topic: &TopicPattern, protected: &[String]) -> bool {
        if !self.can_subscribe || self.namespaces.is_empty() {
            return false;
        }
        self.namespace_allowed(extract_pattern_namespace(topic), protected)
    }

    /// Whether these claims allow publishing to `topic` (deny-by-default).
    #[must_use]
    pub fn can_publish_to(&self, topic: &TopicPath) -> bool {
        self.can_publish_to_scoped(topic, &[])
    }

    /// Like [`Self::can_publish_to`], with the protected-prefix rule of
    /// [`Self::can_subscribe_to_scoped`].
    #[must_use]
    pub fn can_publish_to_scoped(&self, topic: &TopicPath, protected: &[String]) -> bool {
        if !self.can_publish || self.namespaces.is_empty() {
            return false;
        }
        self.namespace_allowed(topic.namespace(), protected)
    }

    /// Whether this claim's namespaces grant `topic_ns`: an exact grant always
    /// wins; `"*"` grants every namespace except those whose prefix is in
    /// `protected`.
    fn namespace_allowed(&self, topic_ns: &str, protected: &[String]) -> bool {
        let is_protected = protected
            .iter()
            .any(|prefix| !prefix.is_empty() && topic_ns.starts_with(prefix.as_str()));
        self.namespaces
            .iter()
            .any(|ns| ns == topic_ns || (ns == "*" && !is_protected))
    }
}

// Extract namespace from a topic pattern.
fn extract_pattern_namespace(topic: &TopicPattern) -> &str {
    match topic {
        TopicPattern::Exact(p) => p.namespace(),
        TopicPattern::Prefix(p) => p.split('/').next().unwrap_or(""),
        TopicPattern::Glob(p) => {
            if p.as_str() == "**" {
                return "*";
            }
            p.split('/').next().unwrap_or("")
        }
    }
}

/// Receipt returned after a successful publish.
///
/// # Purpose
/// Contains the assigned event ID, topic-scoped sequence number,
/// and whether the event reached the bus.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PublishReceipt {
    /// Assigned event identifier.
    pub event_id: EventId,
    /// Topic-scoped sequence number.
    pub sequence: u64,
    /// Whether the event was delivered to the bus.
    pub delivered_to_bus: bool,
}

/// Context passed alongside the token for auth verification.
///
/// # Purpose
/// Allows auth providers to make decisions based on transport
/// type or client IP.
#[derive(Debug, Clone)]
pub struct AuthContext {
    /// Remote address of the client.
    pub peer_addr: SocketAddr,
    /// Transport type (e.g. `"websocket"`, `"http"`).
    pub transport: String,
}
