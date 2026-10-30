/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   main.rs                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:33:06 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 14:00:00 by dlesieur         ###   ########.fr       */
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

    // Before any TLS dial: a `--features dynamodb` build links ring and aws-lc-rs,
    // which leaves rustls no default, and a driver that builds its own config
    // (redis on `rediss://`, mysql_async) would panic on the first connect (R5).
    data_plane_pool::ensure_crypto_provider();

    let config = ServerConfig::try_from_env()?;

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
    probe(&host, &port)?;
    // A configured TLS port is part of health: an image too old to bind it must not
    // look healthy while clients dial it (DT11).
    let plain_port = port.trim().parse().unwrap_or(0);
    if let Some(tls) = data_plane_server::tls_listener::settings_from_env(plain_port)? {
        probe(&host, &tls.port.to_string())?;
    }
    Ok(())
}

fn probe(host: &str, port: &str) -> anyhow::Result<()> {
    let addr = format!("{host}:{port}")
        .to_socket_addrs()?
        .next()
        .ok_or_else(|| anyhow::anyhow!("healthcheck address did not resolve"))?;
    TcpStream::connect_timeout(&addr, Duration::from_secs(2))?;
    Ok(())
}
