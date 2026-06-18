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

//! WebSocket connection handler — manages the full lifecycle of a client connection.
//!
//! Each WebSocket connection spawns two tasks:
//!
//! 1. **Writer task** (`writer_loop`) — reads from the per-connection send
//!    channel and a control channel, serializes messages to JSON, and
//!    writes WebSocket text frames. Includes slow-client detection.
//!
//! 2. **Reader task** (`reader_loop`) — reads WebSocket frames, deserializes
//!    [`ClientMessage`]s, and handles auth, subscribe, unsubscribe, publish,
//!    and ping commands.

mod connection;
mod handlers;
mod reader;
mod util;
mod writer;

use std::sync::Arc;

use axum::extract::ws::WebSocketUpgrade;
use axum::extract::State;
use axum::response::IntoResponse;
use realtime_core::AuthProvider;
use realtime_engine::registry::SubscriptionRegistry;
use realtime_engine::PresenceTracker;

use crate::connection::ConnectionManager;

/// Shared application state injected into Axum handlers via `State`.
#[derive(Clone)]
pub struct AppState {
    pub conn_manager: Arc<ConnectionManager>,
    pub registry: Arc<SubscriptionRegistry>,
    pub auth_provider: Arc<dyn AuthProvider>,
    pub bus_publisher: Arc<dyn realtime_core::EventBusPublisher>,
    /// Per-topic presence ("who's online") tracker. Single-node authoritative;
    /// changes are also published over the bus so a multi-node bus delivers the
    /// notification cluster-wide.
    pub presence: Arc<PresenceTracker>,
    /// A5 cross-node presence backend (Redis). `Some` ONLY when the
    /// `REALTIME_PRESENCE_SHARED` sub-flag is ON; `None` at parity — `TRACK`/
    /// `UNTRACK` then only touch the local tracker, the presence query answers
    /// from the local set, and no Redis connection is opened. Turning it ON makes
    /// a member that joined on node A visible to a query served by node B.
    pub presence_shared: Option<crate::presence_shared::SharedPresence>,
    /// B1d metering handle (`realtime.connection.seconds`). `Some` ONLY when the
    /// `REALTIME_METERING` sub-flag is ON; `None` at parity — the close path then
    /// records nothing, no flusher runs, no Redis connection is opened.
    pub usage: Option<crate::usage::Usage>,
}

/// Axum handler for WebSocket upgrade requests (`GET /ws`).
#[allow(clippy::unused_async)]
pub async fn ws_upgrade(ws: WebSocketUpgrade, State(state): State<AppState>) -> impl IntoResponse {
    ws.on_upgrade(move |socket| connection::handle_websocket(socket, state))
}
