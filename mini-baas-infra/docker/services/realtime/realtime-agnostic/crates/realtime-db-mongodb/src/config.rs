/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   config.rs                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Configuration types for the `MongoDB` change stream producer.

use serde::{Deserialize, Serialize};

/// `MongoDB` change stream configuration.
///
/// ## JSON example
///
/// ```json
/// {
///   "uri": "mongodb://localhost:27017/?replicaSet=rs0",
///   "database": "syncspace",
///   "topic_prefix": "mongo",
///   "collections": [],
///   "full_document": "updateLookup"
/// }
/// ```
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MongoConfig {
    /// `MongoDB` connection URI.
    pub uri: String,

    /// Database name to watch.
    pub database: String,

    /// Collections to watch. Empty means watch all collections.
    #[serde(default)]
    pub collections: Vec<CollectionConfig>,

    /// Topic prefix for events from this database.
    /// Events will be published as "{prefix}/{collection}/{operation}".
    #[serde(default = "default_prefix")]
    pub topic_prefix: String,

    /// Full document mode: "default", "updateLookup", "whenAvailable", "required".
    #[serde(default = "default_full_document")]
    pub full_document: String,
}

/// Per-collection configuration for fine-grained CDC control.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CollectionConfig {
    /// Collection name.
    pub name: String,
    /// Operations to watch: insert, update, replace, delete.
    #[serde(default = "default_operations")]
    pub operations: Vec<String>,
    /// Custom topic override.
    pub topic: Option<String>,
}

fn default_prefix() -> String {
    "mongo".to_string()
}

fn default_full_document() -> String {
    "updateLookup".to_string()
}

fn default_operations() -> Vec<String> {
    vec![
        "insert".into(),
        "update".into(),
        "replace".into(),
        "delete".into(),
    ]
}

impl Default for MongoConfig {
    fn default() -> Self {
        Self {
            uri: "mongodb://localhost:27017".to_string(),
            database: "test".to_string(),
            collections: vec![],
            topic_prefix: default_prefix(),
            full_document: default_full_document(),
        }
    }
}
