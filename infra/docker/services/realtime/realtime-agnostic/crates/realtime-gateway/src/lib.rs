/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   lib.rs                                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! # realtime-gateway
//!
//! WebSocket gateway, connection lifecycle management, fan-out pipeline, and REST API
//! for the Realtime-Agnostic event engine.
//!
//! This crate handles the entire client-facing surface:
//!
//! - **WebSocket handling** ([`ws_handler`]) — Connection upgrade, authentication,
//!   subscribe/unsubscribe, event delivery, and client PUBLISH.
//! - **Connection management** ([`connection`]) — Per-connection bounded send queues,
//!   overflow policies (DropNewest/DropOldest/Disconnect), backpressure isolation.
//! - **Fan-out** ([`fanout`]) — N-worker pool that reads dispatch instructions from
//!   the event router and writes events to per-connection channels.
//! - **REST API** ([`rest_api`]) — HTTP endpoints for publishing events and health checks.
//!
//! ## Backpressure Architecture
//!
//! ```text
//! EventRouter → dispatch_tx(65536) → FanOutWorkerPool(N workers)
//!                                    → conn_manager.try_send(conn_id, event)
//!                                      → per-connection mpsc(256) → WS writer_loop
//! ```
//!
//! Each connection has an independent bounded queue. A slow client never blocks others.

pub mod connection;
pub mod fanout;
pub mod metrics;
pub mod presence_shared;
pub mod rest_api;
pub mod usage;
pub mod ws_handler;

pub use connection::ConnectionManager;
pub use fanout::FanOutWorkerPool;
