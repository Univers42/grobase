/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   server.rs                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:33:43 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:33:45 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

use crate::{config::ServerConfig, routes, signal, tls_listener};
use std::time::Duration;
use tokio_util::sync::CancellationToken;

/// How often the background reaper runs: drains idle pools past their
/// `idle_ttl_ms` and rolls back + unpins transactions past their TTL. 15s is
/// short relative to both the default pool idle TTL (30s) and the tx TTL (30s),
/// so an idle pool / abandoned tx is reclaimed within roughly one extra tick.
const REAPER_INTERVAL: Duration = Duration::from_secs(15);

pub async fn run(config: ServerConfig) -> anyhow::Result<()> {
    let addr = format!("{}:{}", config.host, config.port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    // Both sockets bound before anything serves: a bad TLS cert, key or port
    // refuses the boot instead of leaving a plaintext-only router (DT7).
    let tls = tls_listener::bind_from_env(&config.host, config.port).await?;

    // R2 + R3: the registry is built inside [`routes::AppState::new`] —
    // one `Arc<dyn EngineAdapter>` per engine. Adding engines (R7 MySQL,
    // etc.) is a one-line vec edit there, not a server.rs change.
    let state = routes::AppState::new(config);
    spawn_background_loops(&state);

    // Keep a handle for the post-serve flush (the router consumes `state`).
    let shutdown_state = state.clone();
    let app = routes::router(state);

    tracing::info!(address = %addr, "Rust data-plane-router listening");
    serve_until_shutdown(listener, tls, app).await?;
    // Track-B metering (B1a): flush the last pending usage window on graceful
    // shutdown (no-op when metering is OFF → parity). Both listeners have
    // drained by now, so no TLS request lands after the flush (DT6).
    shutdown_state.flush_usage();
    Ok(())
}

/// One shutdown signal reaches both listeners; returns once both have drained.
async fn serve_until_shutdown(
    listener: tokio::net::TcpListener,
    tls: Option<tls_listener::TlsListener>,
    app: axum::Router,
) -> anyhow::Result<()> {
    let shutdown = CancellationToken::new();
    let trigger = shutdown.clone();
    tokio::spawn(async move {
        signal::shutdown_signal().await;
        trigger.cancel();
    });
    let tls_task =
        tls.map(|tls| tokio::spawn(tls_listener::serve(tls, app.clone(), shutdown.clone())));
    let served = axum::serve(listener, app)
        .with_graceful_shutdown(shutdown.clone().cancelled_owned())
        .await;
    shutdown.cancel();
    if let Some(task) = tls_task {
        task.await?;
    }
    Ok(served?)
}

fn spawn_background_loops(state: &routes::AppState) {
    // Background reaper: without this, idle pools never drain past their
    // idle_ttl and an abandoned (begun-but-never-finalised) transaction pins
    // its pool forever. `AppState` is a cheap Arc-backed clone, so the task
    // shares the same registry + transaction map the request path uses.
    let reaper_state = state.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(REAPER_INTERVAL);
        loop {
            interval.tick().await;
            reaper_state.reap_once().await;
        }
    });

    // Track-B honor sets (B2 quota + spend-cap + suspend): a DEDICATED
    // snapshot-refresh loop, separate from the 15s pool reaper, so enforcement
    // reacts at `quota_refresh_ms` (default 15s, REUSED by all three sets) rather
    // than being coupled to pool reaping. Spawned ONLY when ANY honor set is ON —
    // at parity this task never exists (no Redis traffic, no timer). The refresh
    // runs OFF the request path; the hot path only reads the in-memory snapshots it
    // maintains. `refresh_honor_sets` refreshes every ENABLED set (each disabled
    // one is a `None` no-op).
    if state.honor_sets_enabled() {
        let honor_state = state.clone();
        let refresh_ms = state.quota_refresh_ms().max(1);
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_millis(refresh_ms));
            loop {
                interval.tick().await;
                honor_state.refresh_honor_sets().await;
            }
        });
    }
}
