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
    /// Check if these claims allow subscribing to the given pattern.
    ///
    /// # Arguments
    /// * `topic` — The topic pattern to check against.
    ///
    /// # Returns
    /// `true` if subscribing is allowed.
    ///
    /// # Panics
    /// Never panics.
    #[must_use]
    pub fn can_subscribe_to(&self, topic: &TopicPattern) -> bool {
        if !self.can_subscribe {
            return false;
        }
        // Deny-by-default: an empty namespace list grants nothing. All-access is
        // explicit (`["*"]`), never implied by absence.
        if self.namespaces.is_empty() {
            return false;
        }
        let topic_ns = extract_pattern_namespace(topic);
        self.namespaces.iter().any(|ns| ns == "*" || ns == topic_ns)
    }

    /// Check if these claims allow publishing to the given topic.
    ///
    /// # Arguments
    /// * `topic` — The concrete topic to check.
    ///
    /// # Returns
    /// `true` if publishing is allowed.
    ///
    /// # Panics
    /// Never panics.
    #[must_use]
    pub fn can_publish_to(&self, topic: &TopicPath) -> bool {
        if !self.can_publish {
            return false;
        }
        // Deny-by-default (see can_subscribe_to): empty namespaces grant nothing.
        if self.namespaces.is_empty() {
            return false;
        }
        let ns = topic.namespace();
        self.namespaces.iter().any(|n| n == "*" || n == ns)
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
