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

//! # realtime-bus-inprocess
//!
//! In-process event bus implementation using [`tokio::sync::broadcast`] channels.
//!
//! This is the simplest possible [`EventBus`] implementation:
//! zero external dependencies, zero serialization, zero network hops. Suitable for
//! single-node deployments and testing.
//!
//! ## Capacity
//!
//! The bus has a configurable capacity (default: 65,536 messages). When a subscriber
//! falls behind, it receives a `Lagged(n)` notification and skips ahead — no unbounded
//! memory growth, no blocking of publishers.
//!
//! ## Replacing with a Distributed Bus
//!
//! For multi-node deployments, implement [`EventBus`] for
//! Redis Streams, NATS `JetStream`, or Apache Kafka. The rest of the system works
//! unchanged — only this crate needs to be swapped.

mod bus;
mod publisher;
mod subscriber;

#[cfg(test)]
mod tests;

pub use bus::InProcessBus;
