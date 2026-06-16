/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   producer_registry.rs                               :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/04/07 11:13:08 by dlesieur          #+#    #+#             */
/*   Updated: 2026/04/07 13:05:07 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Producer factory registry — the adapter extension point.
//!
//! This module implements the **Strategy + Registry** pattern that makes
//! the engine database-agnostic. At startup, each database adapter crate
//! registers a [`ProducerFactory`] by name (e.g. `"postgresql"`, `"mongodb"`).
//! When the server reads its config and encounters a database section,
//! it looks up the factory by name and calls `create(config_json)` to
//! get a configured [`DatabaseProducer`].
//!
//! ## Adding a new adapter
//!
//! 1. Create a crate implementing [`DatabaseProducer`] + `EventStream`.
//! 2. Implement [`ProducerFactory`] for your factory struct.
//! 3. In `main.rs`, call `registry.register(Box::new(MyFactory))`.

use std::collections::HashMap;
use std::sync::RwLock;

use realtime_core::{DatabaseProducer, ProducerFactory, RealtimeError, Result};

/// Registry of database producer factories.
///
/// Allows runtime registration of database adapters by name.
/// The server iterates its config, looks up the adapter name in the
/// registry, and calls `create()` with the adapter-specific JSON config.
#[derive(Default)]
pub struct ProducerRegistry {
    factories: RwLock<HashMap<String, Box<dyn ProducerFactory>>>,
}

impl ProducerRegistry {
    /// Create an empty producer registry.
    #[must_use]
    pub fn new() -> Self {
        Self {
            factories: RwLock::new(HashMap::new()),
        }
    }

    /// Register a producer factory by name.
    ///
    /// If a factory with the same name already exists, it is overwritten.
    /// This allows test code to replace real adapters with mocks.
    ///
    /// # Errors
    ///
    /// Returns [`RealtimeError::Internal`] if the `RwLock` is poisoned.
    pub fn register(&self, factory: Box<dyn ProducerFactory>) -> Result<()> {
        let name = factory.name().to_string();
        self.factories
            .write()
            .map_err(|e| RealtimeError::Internal(format!("RwLock poisoned: {e}")))?
            .insert(name, factory);
        Ok(())
    }

    /// Create a [`DatabaseProducer`] by looking up the adapter name.
    ///
    /// # Arguments
    ///
    /// * `adapter` — The adapter name (e.g. `"postgresql"`).
    /// * `config` — Adapter-specific JSON configuration.
    ///
    /// # Errors
    ///
    /// Returns [`RealtimeError::Internal`] if the adapter is not registered.
    #[allow(clippy::significant_drop_tightening)]
    pub fn create_producer(
        &self,
        adapter: &str,
        config: serde_json::Value,
    ) -> Result<Box<dyn DatabaseProducer>> {
        let factories = self
            .factories
            .read()
            .map_err(|e| RealtimeError::Internal(format!("RwLock poisoned: {e}")))?;
        let factory = factories.get(adapter).ok_or_else(|| {
            RealtimeError::Internal(format!(
                "Unknown database adapter '{}'. Registered adapters: [{}]",
                adapter,
                factories.keys().cloned().collect::<Vec<_>>().join(", ")
            ))
        })?;
        factory.create(config)
    }

    /// List the names of all registered adapters.
    ///
    /// # Errors
    ///
    /// Returns [`RealtimeError::Internal`] if the `RwLock` is poisoned.
    pub fn adapters(&self) -> Result<Vec<String>> {
        let factories = self
            .factories
            .read()
            .map_err(|e| RealtimeError::Internal(format!("RwLock poisoned: {e}")))?;
        Ok(factories.keys().cloned().collect())
    }

    /// Check whether an adapter with the given name is registered.
    ///
    /// # Errors
    ///
    /// Returns [`RealtimeError::Internal`] if the `RwLock` is poisoned.
    pub fn has_adapter(&self, name: &str) -> Result<bool> {
        let factories = self
            .factories
            .read()
            .map_err(|e| RealtimeError::Internal(format!("RwLock poisoned: {e}")))?;
        Ok(factories.contains_key(name))
    }
}

#[allow(clippy::unwrap_used)]
#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use realtime_core::{EventEnvelope, EventStream};

    struct DummyProducer;

    #[async_trait]
    impl DatabaseProducer for DummyProducer {
        async fn start(&self) -> Result<Box<dyn EventStream>> {
            Ok(Box::new(DummyStream))
        }
        async fn stop(&self) -> Result<()> {
            Ok(())
        }
        async fn health_check(&self) -> Result<()> {
            Ok(())
        }
        fn name(&self) -> &'static str {
            "dummy"
        }
    }

    struct DummyStream;

    #[async_trait]
    impl EventStream for DummyStream {
        async fn next_event(&mut self) -> Option<EventEnvelope> {
            None
        }
    }

    struct DummyFactory;

    impl ProducerFactory for DummyFactory {
        fn name(&self) -> &'static str {
            "dummy"
        }
        fn create(&self, _config: serde_json::Value) -> Result<Box<dyn DatabaseProducer>> {
            Ok(Box::new(DummyProducer))
        }
    }

    #[test]
    fn test_register_and_create() {
        let registry = ProducerRegistry::new();
        registry.register(Box::new(DummyFactory)).unwrap();

        assert!(registry.has_adapter("dummy").unwrap());
        assert!(!registry.has_adapter("mysql").unwrap());
        assert_eq!(registry.adapters().unwrap(), vec!["dummy".to_string()]);

        let producer = registry.create_producer("dummy", serde_json::json!({}));
        assert!(producer.is_ok());
        assert_eq!(producer.unwrap().name(), "dummy");
    }

    #[test]
    fn test_unknown_adapter_error() {
        let registry = ProducerRegistry::new();
        let result = registry.create_producer("mysql", serde_json::json!({}));
        assert!(result.is_err());
    }
}
