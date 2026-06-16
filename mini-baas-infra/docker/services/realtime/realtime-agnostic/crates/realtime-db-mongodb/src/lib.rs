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

mod config;
mod producer;

pub use config::MongoConfig;
pub use producer::MongoProducer;

/// Factory for creating `MongoDB` change stream producers from generic JSON config.
pub struct MongoFactory;

impl realtime_core::ProducerFactory for MongoFactory {
    fn name(&self) -> &'static str {
        "mongodb"
    }

    fn create(
        &self,
        config: serde_json::Value,
    ) -> realtime_core::Result<Box<dyn realtime_core::DatabaseProducer>> {
        let mongo_config: MongoConfig = serde_json::from_value(config).map_err(|e| {
            realtime_core::RealtimeError::Internal(format!("Invalid MongoDB config: {e}"))
        })?;
        Ok(Box::new(MongoProducer::new(mongo_config)))
    }
}
