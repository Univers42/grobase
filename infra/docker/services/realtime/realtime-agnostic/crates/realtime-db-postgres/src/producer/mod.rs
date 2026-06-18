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

//! `PostgreSQL` CDC (Change Data Capture) producer using `LISTEN/NOTIFY`.

mod lifecycle;
mod parser;
mod trigger;

use std::sync::atomic::AtomicBool;
use std::sync::Arc;

use crate::config::PostgresConfig;

/// `PostgreSQL` CDC producer using LISTEN/NOTIFY.
///
/// Watches for `PostgreSQL` notifications on a configured channel
/// and converts them into `EventEnvelopes` published to the event bus.
pub struct PostgresProducer {
    pub(crate) config: PostgresConfig,
    pub(crate) running: Arc<AtomicBool>,
    pub(crate) client: std::sync::Mutex<Option<tokio_postgres::Client>>,
}

impl PostgresProducer {
    /// Create a new `PostgreSQL` CDC producer from config.
    ///
    /// Does **not** connect to the database yet — call
    /// [`start()`](realtime_core::DatabaseProducer::start) to begin listening.
    #[must_use]
    pub fn new(config: PostgresConfig) -> Self {
        Self {
            config,
            running: Arc::new(AtomicBool::new(false)),
            client: std::sync::Mutex::new(None),
        }
    }

    /// Generate the SQL DDL for the notification trigger function.
    #[must_use]
    pub fn generate_trigger_sql(table: &str, channel: &str) -> String {
        trigger::generate_trigger_sql(table, channel)
    }
}
