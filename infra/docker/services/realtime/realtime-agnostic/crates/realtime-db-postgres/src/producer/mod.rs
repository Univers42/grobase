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
    /// Shared with the supervisor task, which replaces it on every re-attach.
    pub(crate) client: Arc<std::sync::Mutex<Option<tokio_postgres::Client>>>,
    /// True only while a LISTEN is actually attached. `running` says the
    /// producer was asked to run; this says it is currently delivering.
    pub(crate) connected: Arc<AtomicBool>,
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
            client: Arc::new(std::sync::Mutex::new(None)),
            connected: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Whether a LISTEN is attached right now.
    ///
    /// A dead producer leaves the process serving `WebSockets` happily while no
    /// row change is ever delivered, so this is the difference between "the
    /// port is open" and "events are flowing".
    #[must_use]
    pub fn is_connected(&self) -> bool {
        self.connected.load(std::sync::atomic::Ordering::SeqCst)
    }

    /// Generate the SQL DDL for the notification trigger function.
    #[must_use]
    pub fn generate_trigger_sql(table: &str, channel: &str) -> String {
        trigger::generate_trigger_sql(table, channel)
    }
}
