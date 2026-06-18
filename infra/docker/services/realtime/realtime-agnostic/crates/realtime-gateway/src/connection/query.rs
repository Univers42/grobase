/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   query.rs                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/04/07 13:06:35 by dlesieur          #+#    #+#             */
/*   Updated: 2026/04/07 13:06:36 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

use realtime_core::{ConnectionId, ConnectionMeta};
use tracing::info;

use super::ConnectionManager;

impl ConnectionManager {
    pub fn remove(&self, conn_id: ConnectionId) {
        if self.connections.remove(&conn_id).is_some() {
            info!(conn_id = %conn_id, "Connection removed");
        }
    }

    pub fn connection_count(&self) -> usize {
        self.connections.len()
    }

    pub fn has_connection(&self, conn_id: ConnectionId) -> bool {
        self.connections.contains_key(&conn_id)
    }

    pub fn get_meta(&self, conn_id: ConnectionId) -> Option<ConnectionMeta> {
        self.connections.get(&conn_id).map(|s| s.meta.clone())
    }

    pub fn all_connection_ids(&self) -> Vec<ConnectionId> {
        self.connections.iter().map(|e| *e.key()).collect()
    }
}
