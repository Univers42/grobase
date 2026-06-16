/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   server.rs                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Server assembly — wires every crate together into a running HTTP/WS server.
//!
//! This module is the **composition root** of the system. It reads
//! [`ServerConfig`], instantiates the event bus,
//! auth provider, router, fan-out pool, database producers, and HTTP routes,
//! then binds a TCP listener.

use std::sync::Arc;

use axum::{
    routing::{get, post},
    Router,
};
use realtime_auth::NoAuthProvider;
use realtime_bus_inprocess::InProcessBus;
use realtime_bus_irc::{IrcBus, IrcBusConfig};
use realtime_core::{AuthProvider, DatabaseProducer, EventBus, EventBusPublisher};
use realtime_engine::{
    registry::SubscriptionRegistry, router::EventRouter, sequence::SequenceGenerator,
    PresenceTracker, ProducerRegistry,
};
use realtime_gateway::{
    connection::ConnectionManager,
    fanout::FanOutWorkerPool,
    rest_api,
    ws_handler::{self, AppState},
};
use tokio::sync::mpsc;
use tower_http::cors::CorsLayer;
use tracing::{error, info};

use crate::config::{AuthConfig, EventBusConfig, ServerConfig};

/// Build and run the full realtime server.
///
/// Assembles all components from the given configuration and blocks
/// until the server is shut down.
///
/// # Errors
///
/// Returns an error if any component fails to initialize or the server
/// cannot bind to the configured address.
pub async fn run(config: ServerConfig) -> anyhow::Result<()> {
    let bus = build_event_bus(&config);
    let publisher: Arc<dyn EventBusPublisher> = Arc::from(bus.publisher().await?);
    let auth_provider = build_auth_provider(&config)?;
    let (registry, sequence_gen, conn_manager) = build_core(&config);
    let dispatch_tx = build_fanout(&conn_manager, config.performance.fanout_workers);
    let router = wire_router(&registry, &sequence_gen, dispatch_tx);
    spawn_bus_loop(&bus, &router).await?;
    start_producers(&config, &publisher);
    let app = build_http_router(
        conn_manager,
        registry,
        auth_provider,
        publisher,
        &config.static_dir,
    );

    let addr = format!("{}:{}", config.host, config.port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    info!("Realtime server listening on {}", addr);

    axum::serve(listener, app)
        .with_graceful_shutdown(crate::signal::shutdown_signal())
        .await?;

    bus.shutdown().await.ok();
    Ok(())
}

fn build_event_bus(config: &ServerConfig) -> Arc<dyn EventBus> {
    let bus: Arc<dyn EventBus> = match &config.event_bus {
        EventBusConfig::InProcess { capacity } => Arc::new(InProcessBus::new(*capacity)),
        EventBusConfig::Irc {
            host,
            port,
            password,
            nick,
            user,
            realname,
            channels,
            namespace,
            capacity,
        } => Arc::new(IrcBus::new(IrcBusConfig {
            host: host.clone(),
            port: *port,
            password: password.clone(),
            nick: nick.clone(),
            user: user.clone(),
            realname: realname.clone(),
            channels: channels.clone(),
            namespace: namespace.clone(),
            capacity: *capacity,
        })),
    };
    bus
}

fn build_auth_provider(config: &ServerConfig) -> anyhow::Result<Arc<dyn AuthProvider>> {
    match &config.auth {
        AuthConfig::NoAuth => {
            // Phase 5: NoAuth accepts ANY token with all-access claims. Refuse it
            // under SECURITY_MODE=max (use JWT) unless explicitly overridden;
            // baseline keeps working but logs a loud warning.
            let max = std::env::var("SECURITY_MODE").ok().as_deref() == Some("max");
            let allow = std::env::var("REALTIME_ALLOW_NOAUTH").ok().as_deref() == Some("1");
            if max && !allow {
                anyhow::bail!(
                    "NoAuth realtime provider refused under SECURITY_MODE=max — configure JWT, \
                     or set REALTIME_ALLOW_NOAUTH=1 to override"
                );
            }
            tracing::warn!(
                "realtime auth=NoAuth: ALL tokens accepted with all-access claims — not for \
                 production (use JWT; SECURITY_MODE=max refuses NoAuth)"
            );
            Ok(Arc::new(NoAuthProvider::new()))
        }
        AuthConfig::Jwt {
            secret,
            issuer,
            audience,
        } => {
            let mut jwt = realtime_auth::JwtConfig::hmac(secret.clone());
            jwt.issuer.clone_from(issuer);
            jwt.audience.clone_from(audience);
            Ok(Arc::new(realtime_auth::JwtAuthProvider::new(&jwt)?))
        }
    }
}

type CoreComponents = (
    Arc<SubscriptionRegistry>,
    Arc<SequenceGenerator>,
    Arc<ConnectionManager>,
);

fn build_core(config: &ServerConfig) -> CoreComponents {
    let registry = Arc::new(SubscriptionRegistry::with_limits(
        config.engine.limits.clone(),
    ));
    let sequence_gen = Arc::new(SequenceGenerator::new());
    let conn_mgr = Arc::new(ConnectionManager::new(
        config.performance.send_queue_capacity,
    ));
    (registry, sequence_gen, conn_mgr)
}

fn build_fanout(
    conn_manager: &Arc<ConnectionManager>,
    workers: usize,
) -> mpsc::Sender<realtime_engine::router::DispatchMessage> {
    let pool = FanOutWorkerPool::new(Arc::clone(conn_manager), workers);
    pool.start()
}

fn wire_router(
    registry: &Arc<SubscriptionRegistry>,
    seq_gen: &Arc<SequenceGenerator>,
    dispatch_tx: mpsc::Sender<realtime_engine::router::DispatchMessage>,
) -> Arc<EventRouter> {
    Arc::new(EventRouter::new(
        Arc::clone(registry),
        Arc::clone(seq_gen),
        dispatch_tx,
    ))
}

async fn spawn_bus_loop(bus: &Arc<dyn EventBus>, router: &Arc<EventRouter>) -> anyhow::Result<()> {
    let subscriber = bus.subscriber("*").await?;
    let r = Arc::clone(router);
    tokio::spawn(async move { r.run_with_subscriber(subscriber).await });
    Ok(())
}

fn start_producers(config: &ServerConfig, publisher: &Arc<dyn EventBusPublisher>) {
    let registry = default_producer_registry();
    if let Ok(adapters) = registry.adapters() {
        info!("Available adapters: {:?}", adapters);
    }
    for db_cfg in &config.databases {
        match registry.create_producer(&db_cfg.adapter, db_cfg.config.clone()) {
            Ok(producer) => {
                let name = db_cfg.adapter.clone();
                spawn_producer_task(producer, Arc::clone(publisher), name);
            }
            Err(e) => error!(adapter = %db_cfg.adapter, "Failed to create producer: {}", e),
        }
    }
}

fn build_http_router(
    conn_manager: Arc<ConnectionManager>,
    registry: Arc<SubscriptionRegistry>,
    auth_provider: Arc<dyn AuthProvider>,
    bus_publisher: Arc<dyn EventBusPublisher>,
    static_dir: &str,
) -> Router {
    let state = AppState {
        conn_manager,
        registry,
        auth_provider,
        bus_publisher,
        presence: Arc::new(PresenceTracker::new()),
        presence_shared: build_presence_shared(),
        usage: build_usage(),
    };
    Router::new()
        .route("/ws", get(ws_handler::ws_upgrade))
        .route("/v1/publish", post(rest_api::publish_event))
        .route("/v1/publish/batch", post(rest_api::publish_batch))
        .route("/v1/health", get(rest_api::health_check))
        .route("/v1/presence", get(rest_api::presence_query))
        .route("/metrics", get(rest_api::prometheus))
        .fallback_service(tower_http::services::ServeDir::new(static_dir))
        .layer(CorsLayer::permissive())
        .with_state(state)
}

/// Build the A5 cross-node presence backend IFF the `REALTIME_PRESENCE_SHARED`
/// sub-flag is ON (default OFF = byte-parity). When ON, wires a Redis-backed
/// shared store from `REALTIME_PRESENCE_REDIS_URL` (the `presence:*` namespace,
/// overridable via `REALTIME_PRESENCE_PREFIX`) so a member tracked on one node
/// is visible to a presence query served by another. When OFF returns `None`:
/// no shared store, no Redis connection, `TRACK`/`UNTRACK` only touch the local
/// in-process tracker and the presence query answers from the local set — the
/// connect/track/query path is byte-identical to today's single node.
fn build_presence_shared() -> Option<realtime_gateway::presence_shared::SharedPresence> {
    if !env_flag_on("REALTIME_PRESENCE_SHARED") {
        return None;
    }
    let redis_url = std::env::var("REALTIME_PRESENCE_REDIS_URL")
        .ok()
        .filter(|u| !u.trim().is_empty())
        .or_else(|| std::env::var("REDIS_URL").ok())
        .unwrap_or_default();
    if redis_url.trim().is_empty() {
        error!(
            "REALTIME_PRESENCE_SHARED=1 but no REALTIME_PRESENCE_REDIS_URL/REDIS_URL — \
             shared presence disabled (falling back to single-node, no cross-node merge)"
        );
        return None;
    }
    let mut shared = realtime_gateway::presence_shared::SharedPresence::new(&redis_url);
    if let Ok(prefix) = std::env::var("REALTIME_PRESENCE_PREFIX") {
        shared = shared.with_prefix(&prefix);
    }
    info!(
        "realtime cross-node presence ON (REALTIME_PRESENCE_SHARED) — shared Redis store at {}",
        redis_url
    );
    Some(shared)
}

/// Build the B1d metering handle (`realtime.connection.seconds`) IFF the
/// `REALTIME_METERING` sub-flag is ON (default OFF = byte-parity). When ON, wires
/// the durable `usage.events` Redis sink from `REALTIME_METERING_REDIS_URL` and
/// spawns the background flusher every `REALTIME_METERING_FLUSH_MS` (default
/// 60000). When OFF returns `None`: no handle, no flusher (not even an idle
/// timer), no Redis connection — the connect/close path is unchanged.
fn build_usage() -> Option<realtime_gateway::usage::Usage> {
    if !env_flag_on("REALTIME_METERING") {
        return None;
    }
    let redis_url = std::env::var("REALTIME_METERING_REDIS_URL").unwrap_or_default();
    let flush_ms = std::env::var("REALTIME_METERING_FLUSH_MS")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(60_000);
    let usage = realtime_gateway::usage::Usage::new().with_stream_url(&redis_url);
    usage.spawn_flusher(flush_ms);
    info!(
        "realtime metering ON (REALTIME_METERING) — flushing realtime.connection.seconds every {}ms to usage.events",
        flush_ms
    );
    Some(usage)
}

/// A boolean env flag is ON for `1`/`true`/`yes`/`on` (case-insensitive); any
/// other value, or absence, is OFF. Mirrors the data-plane / Go consumer
/// convention so the same `1` turns the whole metering pipeline on.
fn env_flag_on(key: &str) -> bool {
    matches!(
        std::env::var(key).unwrap_or_default().to_ascii_lowercase().as_str(),
        "1" | "true" | "yes" | "on"
    )
}

/// Build the default [`ProducerRegistry`] with built-in adapters.
#[must_use]
pub fn default_producer_registry() -> ProducerRegistry {
    let registry = ProducerRegistry::new();
    let _ = registry.register(Box::new(realtime_db_postgres::PostgresFactory));
    let _ = registry.register(Box::new(realtime_db_mongodb::MongoFactory));
    registry
}

fn spawn_producer_task(
    producer: Box<dyn DatabaseProducer>,
    bus_pub: Arc<dyn EventBusPublisher>,
    adapter_name: String,
) {
    tokio::spawn(async move {
        match producer.start().await {
            Ok(mut stream) => {
                while let Some(event) = stream.next_event().await {
                    if let Err(e) = bus_pub.publish(event.topic.as_str(), &event).await {
                        error!(adapter = %adapter_name, "Failed to publish event: {}", e);
                    }
                }
            }
            Err(e) => error!(adapter = %adapter_name, "Failed to start producer: {}", e),
        }
    });
}
