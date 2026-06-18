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

//! `MongoDB` CDC (Change Data Capture) producer using change streams.

mod lifecycle;
mod parser;

use std::sync::atomic::AtomicBool;
use std::sync::Arc;

use crate::config::MongoConfig;

/// `MongoDB` change stream producer.
///
/// Watches `MongoDB` change streams and converts change events into
/// [`EventEnvelope`]s for the realtime event bus.
///
/// Requires a `MongoDB` replica set or sharded cluster (change streams
/// need the oplog).
pub struct MongoProducer {
    pub(crate) config: MongoConfig,
    pub(crate) running: Arc<AtomicBool>,
}

impl MongoProducer {
    /// Create a new `MongoDB` CDC producer from config.
    ///
    /// Does **not** connect yet — call
    /// [`start()`](realtime_core::DatabaseProducer::start) to open the change stream.
    #[must_use]
    pub fn new(config: MongoConfig) -> Self {
        Self {
            config,
            running: Arc::new(AtomicBool::new(false)),
        }
    }
}
