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

pub use config::PostgresConfig;
pub use producer::PostgresProducer;

/// Factory for creating `PostgreSQL` CDC producers from generic JSON config.
pub struct PostgresFactory;

impl realtime_core::ProducerFactory for PostgresFactory {
    fn name(&self) -> &'static str {
        "postgresql"
    }

    fn create(
        &self,
        config: serde_json::Value,
    ) -> realtime_core::Result<Box<dyn realtime_core::DatabaseProducer>> {
        let pg_config: PostgresConfig = serde_json::from_value(config).map_err(|e| {
            realtime_core::RealtimeError::Internal(format!("Invalid PostgreSQL config: {e}"))
        })?;
        Ok(Box::new(PostgresProducer::new(pg_config)))
    }
}
