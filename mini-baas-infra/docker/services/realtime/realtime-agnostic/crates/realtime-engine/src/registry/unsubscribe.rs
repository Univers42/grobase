/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   unsubscribe.rs                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Unsubscribe and connection-removal operations.

use realtime_core::ConnectionId;
use tracing::{debug, info, warn};

use super::SubscriptionRegistry;

impl SubscriptionRegistry {
    /// Remove a specific subscription by connection + `sub_id`.
    ///
    /// Cleans all three indexes and the filter index. Returns `true`
    /// if the subscription existed and was removed.
    pub fn unsubscribe(&self, conn_id: ConnectionId, sub_id: &str) -> bool {
        let key = (conn_id, sub_id.to_string());
        let Some((_, entry)) = self.by_sub_id.remove(&key) else {
            warn!(conn_id = %conn_id, sub_id = sub_id, "Subscription not found for removal");
            return false;
        };
        if let Some(mut subs) = self.by_connection.get_mut(&conn_id) {
            subs.retain(|e| e.subscription.sub_id.0.as_str() != sub_id);
        }
        let pattern_key = entry.subscription.topic.as_str().to_string();
        if let Some(mut topic_subs) = self.by_topic.get_mut(&pattern_key) {
            topic_subs.retain(|(cid, sid)| !(*cid == conn_id && sid.0.as_str() == sub_id));
        }
        self.filter_index.remove_subscription(&entry.subscription);
        debug!(conn_id = %conn_id, sub_id = sub_id, "Subscription removed");
        true
    }

    /// Remove **all** subscriptions for a connection (called on disconnect).
    ///
    /// Iterates once through the connection's subscriptions and removes
    /// each from every index, avoiding O(N²) cleanup.
    pub fn remove_connection(&self, conn_id: ConnectionId) {
        let Some((_, subs)) = self.by_connection.remove(&conn_id) else {
            return;
        };
        for entry in &subs {
            let sub = &entry.subscription;
            let pattern_key = sub.topic.as_str().to_string();
            if let Some(mut topic_subs) = self.by_topic.get_mut(&pattern_key) {
                topic_subs.retain(|(cid, _)| *cid != conn_id);
            }
            self.by_sub_id.remove(&(conn_id, sub.sub_id.0.to_string()));
            self.filter_index.remove_subscription(sub);
        }
        info!(conn_id = %conn_id, count = subs.len(), "All subscriptions removed for connection");
    }
}
