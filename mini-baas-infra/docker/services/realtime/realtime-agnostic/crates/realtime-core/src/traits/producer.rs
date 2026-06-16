/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   producer.rs                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

use async_trait::async_trait;

use crate::error::Result;
use crate::types::EventEnvelope;

/// Database change data capture (CDC) producer.
///
/// # Purpose
/// Watches a database for changes and translates them into
/// `EventEnvelope`s that flow through the event bus.
///
/// # Lifecycle
/// 1. [`start()`](Self::start) → spawns internal listener.
/// 2. Returned [`EventStream`] yields envelopes on DB changes.
/// 3. [`stop()`](Self::stop) during graceful shutdown.
#[async_trait]
pub trait DatabaseProducer: Send + Sync + 'static {
    /// Start watching for changes. Returns an event stream.
    ///
    /// # Errors
    /// Returns error if the database connection fails.
    async fn start(&self) -> Result<Box<dyn EventStream>>;

    /// Stop watching and release database resources.
    async fn stop(&self) -> Result<()>;

    /// Check that the database connection is healthy.
    async fn health_check(&self) -> Result<()>;

    /// Human-readable name (e.g. `"postgresql"`, `"mongodb"`).
    fn name(&self) -> &str;
}

/// Async stream of `EventEnvelope`s from any event source.
///
/// # Purpose
/// Returned by [`DatabaseProducer::start()`]. The engine polls this
/// in a loop, forwarding each event to the bus.
#[async_trait]
pub trait EventStream: Send + Sync {
    /// Yield the next event, or `None` if the stream ended.
    async fn next_event(&mut self) -> Option<EventEnvelope>;
}

/// Factory trait for creating database producers from config.
///
/// # Purpose
/// Implement this to register a new database adapter. The factory
/// receives JSON config and returns a configured `DatabaseProducer`.
///
/// # Example
/// ```rust,ignore
/// struct PostgresFactory;
/// impl ProducerFactory for PostgresFactory {
///     fn name(&self) -> &str { "postgresql" }
///     fn create(&self, config: serde_json::Value) -> Result<Box<dyn DatabaseProducer>> {
///         let pg_config: PostgresConfig = serde_json::from_value(config)?;
///         Ok(Box::new(PostgresProducer::new(pg_config)))
///     }
/// }
/// ```
pub trait ProducerFactory: Send + Sync + 'static {
    /// Adapter name (e.g. "postgresql", "mongodb").
    fn name(&self) -> &str;

    /// Create a producer from generic JSON config.
    ///
    /// # Errors
    /// Returns error if the config is malformed.
    fn create(&self, config: serde_json::Value) -> Result<Box<dyn DatabaseProducer>>;
}
