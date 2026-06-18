/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mod.rs                                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Server configuration types.
//!
//! The configuration can be loaded from a **TOML** file (recommended),
//! a JSON file, or assembled from individual environment variables.
//! Set the `REALTIME_CONFIG` env var to the path of the config file;
//! the format is detected from the file extension (`.toml` or `.json`).
//!
//! Environment variables always override values from the config file.
//!
//! ## Defaults
//!
//! | Field | Default |
//! |---|---|
//! | `host` | `0.0.0.0` |
//! | `port` | `9090` |
//! | `static_dir` | `sandbox/static` |
//! | `event_bus` | in-process, 65 536 capacity |
//! | `auth` | no-auth |
//! | `send_queue_capacity` | 256 |
//! | `fanout_workers` | number of CPUs |
//! | `dispatch_channel_capacity` | 65 536 |

mod auth;
mod bus;
mod database;
mod engine;
mod performance;

pub use auth::AuthConfig;
pub use bus::EventBusConfig;
pub use database::{DatabaseConfig, LegacyDatabaseConfig};
pub use engine::EngineConfig;
pub use performance::PerformanceConfig;

use serde::{Deserialize, Serialize};

/// Top-level server configuration.
///
/// Loaded from TOML, JSON, or built programmatically. All sections have
/// sensible defaults so an empty config file produces a working server.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerConfig {
    /// Server host address.
    #[serde(default = "default_host")]
    pub host: String,

    /// Server port.
    #[serde(default = "default_port")]
    pub port: u16,

    /// Directory to serve static files from.
    #[serde(default = "default_static_dir")]
    pub static_dir: String,

    /// Event bus configuration.
    #[serde(default)]
    pub event_bus: EventBusConfig,

    /// Authentication configuration.
    #[serde(default)]
    pub auth: AuthConfig,

    /// Performance tuning.
    #[serde(default)]
    pub performance: PerformanceConfig,

    /// Engine-level configuration (filter index limits, etc.).
    #[serde(default)]
    pub engine: EngineConfig,

    /// Database producers.
    #[serde(default)]
    pub databases: Vec<DatabaseConfig>,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            host: default_host(),
            port: default_port(),
            static_dir: default_static_dir(),
            event_bus: EventBusConfig::default(),
            auth: AuthConfig::default(),
            performance: PerformanceConfig::default(),
            engine: EngineConfig::default(),
            databases: vec![],
        }
    }
}

fn default_host() -> String {
    "0.0.0.0".to_string()
}

const fn default_port() -> u16 {
    9090
}

fn default_static_dir() -> String {
    "sandbox/static".to_string()
}
