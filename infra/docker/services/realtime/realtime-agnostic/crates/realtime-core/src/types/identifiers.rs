/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   identifiers.rs                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

use serde::{Deserialize, Serialize};
use smol_str::SmolStr;
use std::fmt;

/// Unique connection identifier assigned by the gateway.
///
/// # Purpose
/// Uses `u64` for memory efficiency. Allocated via atomic increment,
/// guaranteeing uniqueness within a single node.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ConnectionId(pub u64);

impl fmt::Display for ConnectionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "conn-{}", self.0)
    }
}

/// Client-assigned subscription identifier, scoped to a connection.
///
/// # Purpose
/// Uses [`SmolStr`] for stack allocation of short strings (≤23 bytes),
/// avoiding heap allocations for typical subscription IDs.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct SubscriptionId(pub SmolStr);

impl fmt::Display for SubscriptionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// Correlation identifier for distributed tracing.
///
/// # Purpose
/// Propagated through the entire event pipeline for end-to-end tracing.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct TraceId(pub String);

/// Node identifier for multi-node cluster routing.
///
/// # Purpose
/// Used for future horizontal scaling — events route to the gateway
/// node holding target connections.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct NodeId(pub u64);

impl fmt::Display for NodeId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "node-{}", self.0)
    }
}
