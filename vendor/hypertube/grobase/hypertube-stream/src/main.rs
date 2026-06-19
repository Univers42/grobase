//! hypertube-stream: a high-speed range-proxy streaming engine. It resolves a
//! movie_id to its archive.org direct media URL and forwards byte ranges to the
//! browser <video> over a pooled keep-alive client, never buffering the body.

mod config;
mod error;
mod http;
mod proxy;
mod resolve;

use std::sync::Arc;
use std::time::Duration;

use anyhow::Context;
use reqwest::Client;
use tokio::net::TcpListener;

use crate::config::Config;
use crate::http::{router, AppState};
use crate::resolve::Resolver;

/// main reads config, builds the pooled client + resolver, and serves until SIGINT.
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let config = Config::from_env();
    let addr = config.addr.clone();
    let client = build_client()?;
    let resolver = Arc::new(Resolver::new(config, client.clone()));
    let app = router(AppState {
        http: client,
        resolver,
    });

    let listener = TcpListener::bind(&addr)
        .await
        .with_context(|| format!("bind {addr}"))?;
    tracing::info!("hypertube-stream listening on {addr}");
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .context("serve")?;
    Ok(())
}

/// build_client constructs the single pooled keep-alive reqwest client reused for
/// every upstream fetch (connection reuse is the hot-path win).
fn build_client() -> anyhow::Result<Client> {
    Client::builder()
        .pool_idle_timeout(Duration::from_secs(90))
        .pool_max_idle_per_host(32)
        .connect_timeout(Duration::from_secs(10))
        .build()
        .context("build http client")
}

/// shutdown_signal resolves on Ctrl-C so axum drains gracefully.
async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}
