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

//! Parsing of `PostgreSQL` `pg_notify()` JSON payloads into [`EventEnvelope`]s.

use std::collections::HashMap;

use async_trait::async_trait;
use bytes::Bytes;
use realtime_core::{EventEnvelope, EventSource, EventStream, SourceKind, TopicPath};
use tokio::sync::mpsc;

/// Internal event stream backed by an `mpsc::Receiver`.
pub struct PostgresEventStream {
    rx: mpsc::Receiver<EventEnvelope>,
}

impl PostgresEventStream {
    pub(crate) const fn new(rx: mpsc::Receiver<EventEnvelope>) -> Self {
        Self { rx }
    }
}

#[async_trait]
impl EventStream for PostgresEventStream {
    async fn next_event(&mut self) -> Option<EventEnvelope> {
        self.rx.recv().await
    }
}

/// Parse a `PostgreSQL` `pg_notify()` JSON payload into an [`EventEnvelope`].
///
/// Returns `Some(EventEnvelope)` on success, `None` if the JSON is invalid.
pub fn parse_pg_notification(payload: &str, topic_prefix: &str) -> Option<EventEnvelope> {
    let json: serde_json::Value = serde_json::from_str(payload).ok()?;
    let (table, schema, event_type) = extract_fields(&json)?;
    let topic = format!("{topic_prefix}/{table}/{event_type}");
    let metadata = build_metadata(&json, table, schema);
    let payload_bytes = serde_json::to_vec(&json).ok()?;
    Some(build_envelope(
        &topic,
        event_type,
        payload_bytes,
        schema,
        table,
        metadata,
    ))
}

fn extract_fields(json: &serde_json::Value) -> Option<(&str, &str, &str)> {
    let table = json.get("table")?.as_str()?;
    let schema = json.get("schema")?.as_str().unwrap_or("public");
    let operation = json.get("operation")?.as_str()?;
    json.get("data")?;
    let event_type = match operation {
        "INSERT" => "inserted",
        "UPDATE" => "updated",
        "DELETE" => "deleted",
        other => other,
    };
    Some((table, schema, event_type))
}

fn build_metadata(json: &serde_json::Value, table: &str, schema: &str) -> HashMap<String, String> {
    let mut metadata = HashMap::new();
    metadata.insert("schema".to_string(), schema.to_string());
    metadata.insert("table".to_string(), table.to_string());
    if let Some(old_data) = json.get("old_data") {
        if !old_data.is_null() {
            metadata.insert("has_old_data".to_string(), "true".to_string());
        }
    }
    metadata
}

fn build_envelope(
    topic: &str,
    event_type: &str,
    payload_bytes: Vec<u8>,
    schema: &str,
    table: &str,
    metadata: HashMap<String, String>,
) -> EventEnvelope {
    let mut event = EventEnvelope::new(
        TopicPath::new(topic),
        event_type,
        Bytes::from(payload_bytes),
    );
    event.source = Some(EventSource {
        kind: SourceKind::Database,
        id: format!("postgresql:{schema}.{table}"),
        metadata,
    });
    event
}

#[allow(clippy::unwrap_used)]
#[cfg(test)]
mod tests {
    use super::*;
    use realtime_core::SourceKind;

    #[test]
    fn test_parse_pg_notification_insert() {
        let payload = r#"{
            "table": "orders",
            "schema": "public",
            "operation": "INSERT",
            "data": {"id": 1, "status": "pending", "total": 99.99},
            "old_data": null
        }"#;

        let event = parse_pg_notification(payload, "db").unwrap();
        assert_eq!(event.topic.as_str(), "db/orders/inserted");
        assert_eq!(event.event_type, "inserted");
        assert!(event.source.is_some());

        let source = event.source.unwrap();
        assert!(matches!(source.kind, SourceKind::Database));
        assert_eq!(source.id, "postgresql:public.orders");
    }

    #[test]
    fn test_parse_pg_notification_update() {
        let payload = r#"{
            "table": "orders",
            "schema": "public",
            "operation": "UPDATE",
            "data": {"id": 1, "status": "completed", "total": 99.99},
            "old_data": {"id": 1, "status": "pending", "total": 99.99}
        }"#;

        let event = parse_pg_notification(payload, "db").unwrap();
        assert_eq!(event.topic.as_str(), "db/orders/updated");
        assert_eq!(event.event_type, "updated");
    }

    #[test]
    fn test_parse_pg_notification_delete() {
        let payload = r#"{
            "table": "users",
            "schema": "public",
            "operation": "DELETE",
            "data": {"id": 42, "name": "John"},
            "old_data": null
        }"#;

        let event = parse_pg_notification(payload, "mydb").unwrap();
        assert_eq!(event.topic.as_str(), "mydb/users/deleted");
        assert_eq!(event.event_type, "deleted");
    }

    #[test]
    fn test_parse_pg_notification_invalid_json() {
        let event = parse_pg_notification("not json", "db");
        assert!(event.is_none());
    }
}
