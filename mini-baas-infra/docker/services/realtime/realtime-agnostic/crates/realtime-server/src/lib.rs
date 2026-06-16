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

//! # realtime-server
//!
//! Binary entrypoint and assembly logic for the Realtime-Agnostic event engine.
//!
//! This crate has **zero business logic** — it only wires together the other crates:
//!
//! 1. Creates the [`InProcessBus`](realtime_bus_inprocess::InProcessBus)
//! 2. Creates the auth provider ([`NoAuthProvider`](realtime_auth::NoAuthProvider) or [`JwtAuthProvider`](realtime_auth::JwtAuthProvider))
//! 3. Creates the engine components (registry, sequence gen, router)
//! 4. Starts the fan-out worker pool
//! 5. Registers database adapters via [`ProducerRegistry`](realtime_engine::ProducerRegistry)
//! 6. Builds the axum HTTP/WebSocket server
//!
//! ## Configuration
//!
//! Three methods (in priority order):
//! 1. **JSON config file**: `REALTIME_CONFIG=/path/to/config.json`
//! 2. **Environment variables**: `REALTIME_HOST`, `REALTIME_PORT`, `REALTIME_PG_URL`, etc.
//! 3. **Defaults**: `0.0.0.0:9090`, `NoAuth`, InProcessBus(65536)

pub mod config;
pub mod server;
pub mod signal;
