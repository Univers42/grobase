/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   parser.rs                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Parsing of `MongoDB` change stream BSON documents into [`EventEnvelope`]s.

use std::collections::HashMap;

use async_trait::async_trait;
use bytes::Bytes;
use mongodb::bson::{doc, Document};
use realtime_core::{EventEnvelope, EventSource, EventStream, SourceKind, TopicPath};
use tokio::sync::mpsc;

/// Internal event stream backed by an `mpsc::Receiver`.
pub struct MongoEventStream {
    rx: mpsc::Receiver<EventEnvelope>,
}

impl MongoEventStream {
    pub(crate) const fn new(rx: mpsc::Receiver<EventEnvelope>) -> Self {
        Self { rx }
    }
}

#[async_trait]
impl EventStream for MongoEventStream {
    async fn next_event(&mut self) -> Option<EventEnvelope> {
        self.rx.recv().await
    }
}

/// Parse a `MongoDB` change stream BSON document into an [`EventEnvelope`].
///
/// Maps `MongoDB` operation types to event types:
/// `insert → inserted`, `update → updated`, `replace → replaced`, `delete → deleted`.
pub fn parse_change_event(
    doc: &Document,
    topic_prefix: &str,
    database: &str,
) -> Option<EventEnvelope> {
    let (collection, event_type) = extract_change_fields(doc)?;
    let topic = format!("{topic_prefix}/{collection}/{event_type}");
    let payload_bytes = build_payload(doc, collection, database)?;
    Some(build_envelope(
        &topic,
        event_type,
        payload_bytes,
        database,
        collection,
    ))
}

fn extract_change_fields(doc: &Document) -> Option<(&str, &str)> {
    let operation_type = doc.get_str("operationType").ok()?;
    let ns = doc.get_document("ns").ok()?;
    let collection = ns.get_str("coll").ok()?;
    let event_type = match operation_type {
        "insert" => "inserted",
        "update" => "updated",
        "replace" => "replaced",
        "delete" => "deleted",
        other => other,
    };
    Some((collection, event_type))
}

fn build_payload(doc: &Document, collection: &str, database: &str) -> Option<Vec<u8>> {
    let operation_type = doc.get_str("operationType").ok()?;
    let null = mongodb::bson::Bson::Null;
    let payload_doc = doc! {
        "operation": operation_type,
        "collection": collection,
        "database": database,
        "fullDocument": doc.get("fullDocument").cloned().unwrap_or_else(|| null.clone()),
        "documentKey": doc.get("documentKey").cloned().unwrap_or(null),
    };
    let json_value = bson_to_json(&mongodb::bson::Bson::Document(payload_doc));
    serde_json::to_vec(&json_value).ok()
}

fn build_envelope(
    topic: &str,
    event_type: &str,
    payload_bytes: Vec<u8>,
    database: &str,
    collection: &str,
) -> EventEnvelope {
    let mut metadata = HashMap::new();
    metadata.insert("database".to_string(), database.to_string());
    metadata.insert("collection".to_string(), collection.to_string());
    let mut envelope = EventEnvelope::new(
        TopicPath::new(topic),
        event_type,
        Bytes::from(payload_bytes),
    );
    envelope.source = Some(EventSource {
        kind: SourceKind::Database,
        id: format!("mongodb:{database}.{collection}"),
        metadata,
    });
    envelope
}

/// Convert a BSON value to a `serde_json::Value`.
pub fn bson_to_json(bson: &mongodb::bson::Bson) -> serde_json::Value {
    match bson {
        mongodb::bson::Bson::Null => serde_json::Value::Null,
        mongodb::bson::Bson::Boolean(b) => serde_json::Value::Bool(*b),
        mongodb::bson::Bson::Int32(i) => serde_json::Value::Number((*i).into()),
        mongodb::bson::Bson::Int64(i) => serde_json::Value::Number((*i).into()),
        mongodb::bson::Bson::Double(f) => serde_json::Number::from_f64(*f)
            .map_or(serde_json::Value::Null, serde_json::Value::Number),
        mongodb::bson::Bson::String(s) => serde_json::Value::String(s.clone()),
        mongodb::bson::Bson::Array(arr) => {
            serde_json::Value::Array(arr.iter().map(bson_to_json).collect())
        }
        mongodb::bson::Bson::Document(doc) => bson_doc_to_json(doc),
        mongodb::bson::Bson::ObjectId(oid) => serde_json::Value::String(oid.to_hex()),
        mongodb::bson::Bson::DateTime(dt) => serde_json::Value::String(dt.to_string()),
        _ => serde_json::Value::String(bson.to_string()),
    }
}

fn bson_doc_to_json(doc: &Document) -> serde_json::Value {
    let map: serde_json::Map<String, serde_json::Value> = doc
        .iter()
        .map(|(k, v)| (k.clone(), bson_to_json(v)))
        .collect();
    serde_json::Value::Object(map)
}

#[allow(clippy::unwrap_used)]
#[cfg(test)]
mod tests {
    use super::*;
    use mongodb::bson::doc;
    use realtime_core::SourceKind;

    #[test]
    fn test_parse_insert_change_event() {
        let change_doc = doc! {
            "operationType": "insert",
            "ns": { "db": "testdb", "coll": "orders" },
            "fullDocument": {
                "_id": "abc123", "status": "pending", "total": 99.99
            },
            "documentKey": { "_id": "abc123" }
        };

        let event = parse_change_event(&change_doc, "mongo", "testdb").unwrap();
        assert_eq!(event.topic.as_str(), "mongo/orders/inserted");
        assert_eq!(event.event_type, "inserted");

        let source = event.source.unwrap();
        assert!(matches!(source.kind, SourceKind::Database));
        assert_eq!(source.id, "mongodb:testdb.orders");
    }

    #[test]
    fn test_parse_update_change_event() {
        let change_doc = doc! {
            "operationType": "update",
            "ns": { "db": "testdb", "coll": "orders" },
            "fullDocument": {
                "_id": "abc123", "status": "completed", "total": 99.99
            },
            "documentKey": { "_id": "abc123" },
            "updateDescription": {
                "updatedFields": { "status": "completed" },
                "removedFields": []
            }
        };

        let event = parse_change_event(&change_doc, "mongo", "testdb").unwrap();
        assert_eq!(event.topic.as_str(), "mongo/orders/updated");
        assert_eq!(event.event_type, "updated");
    }

    #[test]
    fn test_parse_delete_change_event() {
        let change_doc = doc! {
            "operationType": "delete",
            "ns": { "db": "testdb", "coll": "users" },
            "documentKey": { "_id": "xyz789" }
        };

        let event = parse_change_event(&change_doc, "db", "testdb").unwrap();
        assert_eq!(event.topic.as_str(), "db/users/deleted");
        assert_eq!(event.event_type, "deleted");
    }

    #[test]
    fn test_bson_to_json() {
        let bson = mongodb::bson::Bson::Document(doc! {
            "name": "test",
            "value": 42,
            "nested": { "key": "val" }
        });

        let json = bson_to_json(&bson);
        assert_eq!(json["name"], "test");
        assert_eq!(json["value"], 42);
        assert_eq!(json["nested"]["key"], "val");
    }
}
