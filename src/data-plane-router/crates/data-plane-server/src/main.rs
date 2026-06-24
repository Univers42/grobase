/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   main.rs                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:33:06 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:33:07 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

use data_plane_server::config::ServerConfig;
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

    let config = ServerConfig::from_env();

    // binocle-one ("our PocketBase"): nano + user accounts/JWT — the superset
    // single-binary edition. Checked FIRST because `one` implies `nano`.
    #[cfg(feature = "one")]
    {
        return data_plane_server::one::run(config).await;
    }

    // Nano edition: one static binary, embedded SQLite, in-process auth —
    // the control-plane round-trips below never exist in this build.
    #[cfg(all(feature = "nano", not(feature = "one")))]
    {
        return data_plane_server::nano::run(config).await;
    }

    #[cfg(not(feature = "nano"))]
    {
        tracing::info!(
            product_mode = %config.product_mode,
            adapter_registry_url = %config.adapter_registry_url,
            "starting Rust data-plane-router"
        );
        data_plane_server::server::run(config).await
    }
}

fn healthcheck() -> anyhow::Result<()> {
    let host =
        std::env::var("DATA_PLANE_ROUTER_HEALTH_HOST").unwrap_or_else(|_| "127.0.0.1".to_string());
    let port = std::env::var("DATA_PLANE_ROUTER_PORT").unwrap_or_else(|_| "4011".to_string());
    let addr = format!("{host}:{port}")
        .to_socket_addrs()?
        .next()
        .ok_or_else(|| anyhow::anyhow!("healthcheck address did not resolve"))?;
    TcpStream::connect_timeout(&addr, Duration::from_secs(2))?;
    Ok(())
}
