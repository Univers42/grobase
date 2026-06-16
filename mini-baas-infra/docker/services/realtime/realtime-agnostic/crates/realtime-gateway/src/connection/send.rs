/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   send.rs                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

use std::sync::Arc;

use realtime_core::{ConnectionId, EventEnvelope, OverflowPolicy};
use tokio::sync::mpsc;
use tracing::{debug, warn};

use super::{ConnectionManager, SendResult};

impl ConnectionManager {
    pub fn try_send(&self, conn_id: ConnectionId, sub_id: String, event: Arc<EventEnvelope>) -> SendResult {
        let Some(state) = self.connections.get(&conn_id) else {
            return SendResult::ConnectionGone;
        };
        match state.send_tx.try_send((sub_id, event)) {
            Ok(()) => SendResult::Sent,
            Err(mpsc::error::TrySendError::Full(_)) => {
                apply_overflow_policy(conn_id, &state.overflow_policy)
            }
            Err(mpsc::error::TrySendError::Closed(_)) => SendResult::ConnectionGone,
        }
    }
}

fn apply_overflow_policy(conn_id: ConnectionId, policy: &OverflowPolicy) -> SendResult {
    match policy {
        OverflowPolicy::DropNewest => {
            debug!(conn_id = %conn_id, "Send queue full, dropping newest event");
            SendResult::DroppedNewest
        }
        OverflowPolicy::DropOldest => {
            debug!(conn_id = %conn_id, "Send queue full (drop-oldest), dropping");
            SendResult::DroppedOldest
        }
        OverflowPolicy::Disconnect => {
            warn!(conn_id = %conn_id, "Send queue full, disconnecting");
            SendResult::Disconnect
        }
    }
}
