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

//! # realtime-client
//!
//! Rust client SDK for the Realtime-Agnostic event engine.
//!
//! Features:
//!
//! - **Auto-reconnect** with exponential backoff + jitter (prevents thundering herd)
//! - **Automatic re-subscribe** on reconnection with `resume_from` sequence tracking
//! - **Client-side deduplication** via sliding-window `HashSet` of seen event IDs
//! - **Builder pattern** for ergonomic configuration
//!
//! ## Quick Start
//!
//! ```rust,ignore
//! let client = RealtimeClient::builder("ws://localhost:4002/ws")
//!     .token("my-auth-token")
//!     .reconnect(true)
//!     .build()?;
//!
//! let mut events = client.connect()?;
//! client.subscribe("my-sub", "orders/*", None).await?;
//!
//! while let Some(event) = events.recv().await {
//!     println!("{}: {}", event.topic, event.event_type);
//! }
//! ```

mod client;
mod subscription;

pub use client::{RealtimeClient, RealtimeClientBuilder};
pub use subscription::ClientSubscription;
