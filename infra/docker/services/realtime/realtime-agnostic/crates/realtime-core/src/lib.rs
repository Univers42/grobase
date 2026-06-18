/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   lib.rs                                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/04/07 11:11:38 by dlesieur          #+#    #+#             */
/*   Updated: 2026/04/07 11:11:39 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! # realtime-core
//!
//! Core types, trait contracts, wire protocol, error types, and filter expressions
//! for the Realtime-Agnostic event routing engine.
//!
//! This crate defines the **vocabulary** of the entire system. Every other crate
//! depends on it. It contains zero business logic — only types, traits, and the
//! wire protocol.
//!
//! ## Key Types
//!
//! - [`EventEnvelope`] — The canonical event representation, stable across all transport layers.
//! - [`TopicPattern`] — Subscription patterns: exact, prefix, or glob matching.
//! - [`FilterExpr`] — Predicate expressions evaluated against event fields.
//! - [`ConnectionId`], [`SubscriptionId`], [`EventId`] — Type-safe newtypes.
//!
//! ## Key Traits
//!
//! - [`EventBus`] — The pub/sub message backbone (implement for Redis, NATS, Kafka, etc.).
//! - [`DatabaseProducer`] — Database CDC adapter (implement for each database).
//! - [`ProducerFactory`] — Factory pattern for runtime adapter registration.
//! - [`AuthProvider`] — Token verification and authorization.
//!
//! ## Protocol
//!
//! - [`ClientMessage`] — Messages sent from client to server (AUTH, SUBSCRIBE, PUBLISH, etc.).
//! - [`ServerMessage`] — Messages sent from server to client (`AUTH_OK`, EVENT, ERROR, etc.).

pub mod error;
pub mod filter;
pub mod protocol;
pub mod traits;
pub mod types;

pub use error::*;
pub use filter::*;
pub use protocol::*;
pub use traits::*;
pub use types::*;
