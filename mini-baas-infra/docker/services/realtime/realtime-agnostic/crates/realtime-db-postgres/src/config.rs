/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   config.rs                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Configuration types for the `PostgreSQL` CDC producer.

use serde::{Deserialize, Serialize};

/// `PostgreSQL` CDC configuration.
///
/// ## JSON example
///
/// ```json
/// {
///   "connection_string": "host=localhost dbname=myapp user=postgres",
///   "channel": "realtime_events",
///   "topic_prefix": "pg",
///   "tables": [],
///   "poll_interval_ms": 100
/// }
/// ```
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PostgresConfig {
    /// Connection string: "host=localhost user=postgres dbname=mydb"
    pub connection_string: String,

    /// Channel name for LISTEN/NOTIFY.
    /// The default channel is "`realtime_events`".
    #[serde(default = "default_channel")]
    pub channel: String,

    /// Tables to watch (if using trigger-based approach).
    /// Empty means watch all tables configured with triggers.
    #[serde(default)]
    pub tables: Vec<TableConfig>,

    /// Topic prefix for events from this database.
    /// Events will be published as "{prefix}/{table}/{operation}".
    #[serde(default = "default_prefix")]
    pub topic_prefix: String,

    /// Poll interval for checking new notifications (milliseconds).
    #[serde(default = "default_poll_interval")]
    pub poll_interval_ms: u64,
}

/// Per-table configuration for fine-grained CDC control.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TableConfig {
    /// Table name (schema-qualified: "public.orders").
    pub name: String,

    /// Operations to watch: insert, update, delete.
    #[serde(default = "default_operations")]
    pub operations: Vec<String>,

    /// Custom topic override (default: "{prefix}/{table}").
    pub topic: Option<String>,
}

fn default_channel() -> String {
    "realtime_events".to_string()
}

fn default_prefix() -> String {
    "db".to_string()
}

const fn default_poll_interval() -> u64 {
    100
}

fn default_operations() -> Vec<String> {
    vec!["INSERT".into(), "UPDATE".into(), "DELETE".into()]
}

impl Default for PostgresConfig {
    fn default() -> Self {
        Self {
            connection_string: "host=localhost user=postgres dbname=postgres".to_string(),
            channel: default_channel(),
            tables: vec![],
            topic_prefix: default_prefix(),
            poll_interval_ms: default_poll_interval(),
        }
    }
}
