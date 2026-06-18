/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   dispatch.rs                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

use std::sync::Arc;

use super::{ConnectionId, EventEnvelope};

/// A batch of events destined for specific connections.
///
/// # Purpose
/// The `Arc<EventEnvelope>` is shared across all target connections,
/// achieving zero-copy fan-out. The router produces one batch per
/// event, listing every connection that should receive it.
#[derive(Debug, Clone)]
pub struct DispatchBatch {
    /// The event to deliver (reference-counted, zero-copy).
    pub event: Arc<EventEnvelope>,
    /// Connection IDs that should receive this event.
    pub conn_ids: Vec<ConnectionId>,
}

/// Wire encoding for WebSocket frames sent to clients.
///
/// # Purpose
/// Currently only JSON is used; `MsgPack` is reserved for future
/// binary-optimised transports.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum FrameEncoding {
    /// JSON text frames (current default).
    #[default]
    Json,
    /// `MessagePack` binary frames (reserved).
    MsgPack,
}
