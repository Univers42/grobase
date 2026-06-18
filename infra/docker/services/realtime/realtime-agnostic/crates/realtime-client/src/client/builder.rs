/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   builder.rs                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Builder pattern for [`RealtimeClient`].

use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::{Mutex, RwLock};

use super::RealtimeClient;

/// Builder for [`RealtimeClient`].
///
/// ```rust,ignore
/// RealtimeClientBuilder::new("ws://localhost:9090/ws")
///     .token("my-jwt")
///     .reconnect(true)
///     .max_reconnect_delay(Duration::from_secs(60))
///     .build()
///     .await?;
/// ```
pub struct RealtimeClientBuilder {
    url: String,
    token: String,
    reconnect: bool,
    max_reconnect_delay: Duration,
}

impl RealtimeClientBuilder {
    /// Create a new builder with the WebSocket server URL.
    pub fn new(url: impl Into<String>) -> Self {
        Self {
            url: url.into(),
            token: String::new(),
            reconnect: true,
            max_reconnect_delay: Duration::from_secs(30),
        }
    }

    /// Set the authentication token (JWT or opaque string).
    #[must_use]
    pub fn token(mut self, token: impl Into<String>) -> Self {
        self.token = token.into();
        self
    }

    /// Enable or disable automatic reconnection (default: `true`).
    #[must_use]
    pub const fn reconnect(mut self, enabled: bool) -> Self {
        self.reconnect = enabled;
        self
    }

    /// Set the maximum delay between reconnection attempts.
    #[must_use]
    pub const fn max_reconnect_delay(mut self, delay: Duration) -> Self {
        self.max_reconnect_delay = delay;
        self
    }

    /// Build the client. Does **not** connect yet.
    ///
    /// # Errors
    ///
    /// Returns an error if the client configuration is invalid.
    pub fn build(self) -> anyhow::Result<RealtimeClient> {
        Ok(RealtimeClient {
            url: self.url,
            token: self.token,
            reconnect_enabled: self.reconnect,
            max_reconnect_delay: self.max_reconnect_delay,
            subscriptions: Arc::new(RwLock::new(Vec::new())),
            event_tx: Arc::new(RwLock::new(None)),
            connected: Arc::new(RwLock::new(false)),
            seen_event_ids: Arc::new(Mutex::new(HashSet::new())),
        })
    }
}
