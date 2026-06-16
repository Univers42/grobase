/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   subscription.rs                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Subscription handle for the Rust client SDK.
//!
//! [`ClientSubscription`] wraps an `mpsc::Receiver<EventPayload>` and provides
//! a convenient `.next()` method for pulling events one at a time.

use realtime_core::EventPayload;
use tokio::sync::mpsc;

/// A handle to a client subscription.
///
/// Holds the subscription metadata and a channel receiver for incoming events.
pub struct ClientSubscription {
    pub sub_id: String,
    pub topic: String,
    event_rx: mpsc::Receiver<EventPayload>,
}

impl ClientSubscription {
    /// Create a new subscription handle.
    ///
    /// # Arguments
    ///
    /// * `sub_id` — The subscription identifier.
    /// * `topic` — The subscribed topic.
    /// * `event_rx` — The channel receiver for incoming events.
    #[must_use]
    pub const fn new(
        sub_id: String,
        topic: String,
        event_rx: mpsc::Receiver<EventPayload>,
    ) -> Self {
        Self {
            sub_id,
            topic,
            event_rx,
        }
    }

    /// Receive the next event, or `None` if the channel is closed.
    pub async fn next(&mut self) -> Option<EventPayload> {
        self.event_rx.recv().await
    }
}
