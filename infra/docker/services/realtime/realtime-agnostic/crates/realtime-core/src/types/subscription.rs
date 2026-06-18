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

use serde::{Deserialize, Serialize};

use super::TopicPattern;

/// Overflow policy for per-connection send queues.
///
/// # Purpose
/// Controls backpressure when a client reads too slowly.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub enum OverflowPolicy {
    /// Drop the oldest queued event.
    DropOldest,
    /// Drop the incoming event (default).
    #[default]
    DropNewest,
    /// Force-disconnect the slow client.
    Disconnect,
}

/// Per-subscription configuration sent at subscribe time.
///
/// # Purpose
/// All fields are optional with sensible defaults.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubConfig {
    /// How to handle send-queue overflow.
    #[serde(default)]
    pub overflow: OverflowPolicy,
    /// Optional events-per-second cap.
    pub rate_limit: Option<u32>,
    /// Replay events with `sequence > resume_from`.
    pub resume_from: Option<u64>,
}

impl Default for SubConfig {
    fn default() -> Self {
        Self {
            overflow: OverflowPolicy::DropNewest,
            rate_limit: None,
            resume_from: None,
        }
    }
}

/// A live subscription binding a connection to a topic pattern.
///
/// # Purpose
/// Created on `SUBSCRIBE`, stored in the `SubscriptionRegistry`,
/// matched against incoming events by `FilterIndex`.
#[derive(Debug, Clone)]
pub struct Subscription {
    /// Client-chosen subscription ID.
    pub sub_id: super::SubscriptionId,
    /// Connection that owns this subscription.
    pub conn_id: super::ConnectionId,
    /// Topic pattern to match against.
    pub topic: TopicPattern,
    /// Optional server-side filter expression.
    pub filter: Option<crate::filter::FilterExpr>,
    /// Per-subscription configuration.
    pub config: SubConfig,
}
