/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   counters.rs                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Counter queries for observability and testing.

use crate::filter_index::stats::{FilterIndexStats, StatsSnapshot};

use super::SubscriptionRegistry;

impl SubscriptionRegistry {
    /// Return the total count of active subscriptions across all connections.
    #[must_use]
    pub fn subscription_count(&self) -> usize {
        self.by_sub_id.len()
    }

    /// Return the number of connections that have at least one subscription.
    #[must_use]
    pub fn connection_count(&self) -> usize {
        self.by_connection.len()
    }

    /// Return the number of unique topic patterns currently registered.
    #[must_use]
    pub fn pattern_count(&self) -> usize {
        self.patterns.len()
    }

    /// Access the live filter-index telemetry counters.
    #[must_use]
    pub fn filter_index_stats(&self) -> &FilterIndexStats {
        self.filter_index.stats()
    }

    /// Take a point-in-time snapshot of filter-index stats (for serialization).
    #[must_use]
    pub fn filter_index_snapshot(&self) -> StatsSnapshot {
        self.filter_index.stats().snapshot()
    }
}
