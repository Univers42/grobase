/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   database.rs                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Database producer configuration.

use serde::{Deserialize, Serialize};

/// Generic database producer configuration.
///
/// Each entry names an adapter (e.g. `"postgresql"`, `"mongodb"`) and
/// provides adapter-specific JSON config that is passed to the
/// [`ProducerFactory`](realtime_core::ProducerFactory) at runtime.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatabaseConfig {
    /// Adapter name: "postgresql", "mongodb", "mysql", "redis", etc.
    pub adapter: String,
    /// Adapter-specific configuration (passed as JSON to the `ProducerFactory`).
    #[serde(default)]
    pub config: serde_json::Value,
}

/// Legacy enum kept for backward compatibility with old JSON configs.
/// Automatically converts to the new generic `DatabaseConfig`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum LegacyDatabaseConfig {
    #[serde(rename = "postgresql")]
    PostgreSQL(serde_json::Value),
    #[serde(rename = "mongodb")]
    MongoDB(serde_json::Value),
}

impl From<LegacyDatabaseConfig> for DatabaseConfig {
    fn from(legacy: LegacyDatabaseConfig) -> Self {
        match legacy {
            LegacyDatabaseConfig::PostgreSQL(config) => Self {
                adapter: "postgresql".to_string(),
                config,
            },
            LegacyDatabaseConfig::MongoDB(config) => Self {
                adapter: "mongodb".to_string(),
                config,
            },
        }
    }
}
