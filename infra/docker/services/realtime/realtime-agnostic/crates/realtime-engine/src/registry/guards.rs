/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   guards.rs                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Subscription guards — per-connection and global admission control.
//!
//! Guards are checked by [`SubscriptionRegistry::subscribe()`] before
//! indexing a new subscription. Violations return
//! `RealtimeError::CapacityExceeded`.

use realtime_core::{ConnectionId, RealtimeError, Result};

use super::SubscriptionRegistry;

impl SubscriptionRegistry {
    /// Validate that adding one more subscription for `conn_id` does not
    /// violate any capacity limits.
    ///
    /// Called internally by [`subscribe()`](Self::subscribe) before
    /// touching any indexes.
    pub(crate) fn check_subscription_guards(
        &self,
        conn_id: ConnectionId,
        max_per_connection: usize,
        max_total: usize,
    ) -> Result<()> {
        // Per-connection cap.
        if let Some(subs) = self.by_connection.get(&conn_id) {
            if subs.len() >= max_per_connection {
                return Err(RealtimeError::CapacityExceeded {
                    reason: format!(
                        "connection {} already has {} subscriptions (max: {})",
                        conn_id,
                        subs.len(),
                        max_per_connection,
                    ),
                });
            }
        }

        // Global cap.
        let total = self.by_sub_id.len();
        if total >= max_total {
            return Err(RealtimeError::CapacityExceeded {
                reason: format!("global subscription count {total} reached limit of {max_total}",),
            });
        }

        Ok(())
    }
}
