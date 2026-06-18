/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   main.rs                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 23:57:22 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Binary entry point for the realtime server.
//!
//! Initialises tracing, loads [`ServerConfig`](realtime_server::config::ServerConfig)
//! from environment / config file, and calls [`run()`](realtime_server::server::run).
//!
//! ## Configuration loading order
//!
//! 1. If `REALTIME_CONFIG` points to a **`.toml`** file → parse as TOML.
//! 2. If `REALTIME_CONFIG` points to a **`.json`** file → parse as JSON.
//! 3. Otherwise → build from individual env vars.
//! 4. Environment variables always override values from the config file.
//!
//! ## Environment variables
//!
//! | Variable | Description |
//! |---|---|
//! | `REALTIME_CONFIG` | Path to a TOML or JSON config file |
//! | `REALTIME_HOST` | Bind address (default `0.0.0.0`) |
//! | `REALTIME_PORT` | Bind port (default `9090`) |
//! | `REALTIME_STATIC_DIR` | Static file directory |
//! | `REALTIME_JWT_SECRET` | HMAC secret for JWT auth |
//! | `REALTIME_PG_URL` | PostgreSQL connection string |
//! | `REALTIME_MONGO_URI` | MongoDB connection URI |
//! | `RUST_LOG` | tracing filter (e.g. `info,realtime_engine=debug`) |

use realtime_server::config::{AuthConfig, DatabaseConfig, ServerConfig};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    if std::env::args().any(|arg| arg == "--healthcheck") {
        return healthcheck();
    }

    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .with_target(true)
        .init();

    let config = load_config()?;

    tracing::info!("Starting Realtime Engine v{}", env!("CARGO_PKG_VERSION"));
    tracing::info!("Event bus: {:?}", config.event_bus);
    tracing::info!("Auth: {:?}", config.auth);
    tracing::info!(
        "Performance: send_queue={}, fanout_workers={}, dispatch_capacity={}",
        config.performance.send_queue_capacity,
        config.performance.fanout_workers,
        config.performance.dispatch_channel_capacity,
    );
    tracing::info!(
        "Engine limits: max_patterns={}, max_subs_global={}, max_subs_per_conn={}",
        config.engine.limits.max_patterns,
        config.engine.limits.max_total_subscriptions,
        config.engine.limits.max_subscriptions_per_connection,
    );

    realtime_server::server::run(config).await
}

fn healthcheck() -> anyhow::Result<()> {
    let host = std::env::var("REALTIME_HEALTH_HOST").unwrap_or_else(|_| "127.0.0.1".to_string());
    let port = std::env::var("REALTIME_PORT").unwrap_or_else(|_| "4000".to_string());
    let addr = format!("{host}:{port}")
        .to_socket_addrs()?
        .next()
        .ok_or_else(|| anyhow::anyhow!("healthcheck address did not resolve"))?;
    TcpStream::connect_timeout(&addr, Duration::from_secs(2))?;
    Ok(())
}

fn load_config() -> anyhow::Result<ServerConfig> {
    let mut config = if let Ok(path) = std::env::var("REALTIME_CONFIG") {
        load_config_from_file(&path)?
    } else {
        ServerConfig::default()
    };

    // Environment variables always override the file-based config.
    apply_env_overrides(&mut config);
    add_pg_config(&mut config);
    add_mongo_config(&mut config);
    Ok(config)
}

fn load_config_from_file(path: &str) -> anyhow::Result<ServerConfig> {
    let content = std::fs::read_to_string(path)?;

    let ext = std::path::Path::new(path)
        .extension()
        .and_then(std::ffi::OsStr::to_str)
        .unwrap_or("");

    if ext.eq_ignore_ascii_case("toml") || ext.eq_ignore_ascii_case("conf") {
        tracing::info!("Loading TOML config from {}", path);
        let config: ServerConfig = toml::from_str(&content)?;
        Ok(config)
    } else {
        tracing::info!("Loading JSON config from {}", path);
        let config: ServerConfig = serde_json::from_str(&content)?;
        Ok(config)
    }
}

/// Apply individual `REALTIME_*` env vars on top of the loaded config.
fn apply_env_overrides(config: &mut ServerConfig) {
    if let Ok(host) = std::env::var("REALTIME_HOST") {
        config.host = host;
    }
    if let Ok(port) = std::env::var("REALTIME_PORT") {
        if let Ok(p) = port.parse() {
            config.port = p;
        }
    }
    if let Ok(dir) = std::env::var("REALTIME_STATIC_DIR") {
        config.static_dir = dir;
    }
    if let Ok(secret) = std::env::var("REALTIME_JWT_SECRET") {
        config.auth = AuthConfig::Jwt {
            secret,
            issuer: std::env::var("REALTIME_JWT_ISSUER").ok(),
            audience: std::env::var("REALTIME_JWT_AUDIENCE").ok(),
        };
    }
}

fn add_pg_config(config: &mut ServerConfig) {
    let Ok(pg_url) = std::env::var("REALTIME_PG_URL") else {
        return;
    };
    let channel =
        std::env::var("REALTIME_PG_CHANNEL").unwrap_or_else(|_| "realtime_events".to_string());
    let prefix = std::env::var("REALTIME_PG_PREFIX").unwrap_or_else(|_| "pg".to_string());
    config.databases.push(DatabaseConfig {
        adapter: "postgresql".to_string(),
        config: serde_json::json!({
            "connection_string": pg_url,
            "channel": channel,
            "tables": [],
            "topic_prefix": prefix,
            "poll_interval_ms": 100
        }),
    });
    tracing::info!("PostgreSQL CDC configured from env");
}

fn add_mongo_config(config: &mut ServerConfig) {
    let Ok(uri) = std::env::var("REALTIME_MONGO_URI") else {
        return;
    };
    let database = std::env::var("REALTIME_MONGO_DB").unwrap_or_else(|_| "syncspace".to_string());
    let prefix = std::env::var("REALTIME_MONGO_PREFIX").unwrap_or_else(|_| "mongo".to_string());
    config.databases.push(DatabaseConfig {
        adapter: "mongodb".to_string(),
        config: serde_json::json!({
            "uri": uri,
            "database": database,
            "collections": [],
            "topic_prefix": prefix,
            "full_document": "updateLookup"
        }),
    });
    tracing::info!("MongoDB Change Streams configured from env");
}
