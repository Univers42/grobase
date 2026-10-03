/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   tests.rs                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

#![allow(clippy::unwrap_used)]

#[cfg(test)]
use super::*;
#[cfg(test)]
use crate::types::{EventEnvelope, TopicPath};
#[cfg(test)]
use bytes::Bytes;

#[test]
fn test_filter_eq() {
    let filter = FilterExpr::Eq(
        FieldPath::new("event_type"),
        FilterValue::String("created".to_string()),
    );
    let event = EventEnvelope::new(
        TopicPath::new("orders/created"),
        "created",
        Bytes::from("{}"),
    );
    let result = filter.evaluate(&|field| envelope_field_getter(&event, field));
    assert!(result);
}

#[test]
fn test_filter_ne() {
    let filter = FilterExpr::Ne(
        FieldPath::new("event_type"),
        FilterValue::String("deleted".to_string()),
    );
    let event = EventEnvelope::new(TopicPath::new("test"), "created", Bytes::from("{}"));
    let result = filter.evaluate(&|field| envelope_field_getter(&event, field));
    assert!(result);
}

#[test]
fn test_filter_in() {
    let filter = FilterExpr::In(
        FieldPath::new("event_type"),
        vec![
            FilterValue::String("created".to_string()),
            FilterValue::String("updated".to_string()),
        ],
    );
    let event = EventEnvelope::new(TopicPath::new("test"), "updated", Bytes::from("{}"));
    let result = filter.evaluate(&|field| envelope_field_getter(&event, field));
    assert!(result);
}

#[test]
fn test_filter_and() {
    let filter = FilterExpr::And(
        Box::new(FilterExpr::Eq(
            FieldPath::new("event_type"),
            FilterValue::String("created".to_string()),
        )),
        Box::new(FilterExpr::Eq(
            FieldPath::new("topic"),
            FilterValue::String("orders/created".to_string()),
        )),
    );
    let event = EventEnvelope::new(
        TopicPath::new("orders/created"),
        "created",
        Bytes::from("{}"),
    );
    let result = filter.evaluate(&|field| envelope_field_getter(&event, field));
    assert!(result);
}

#[test]
fn test_filter_or() {
    let filter = FilterExpr::Or(
        Box::new(FilterExpr::Eq(
            FieldPath::new("event_type"),
            FilterValue::String("created".to_string()),
        )),
        Box::new(FilterExpr::Eq(
            FieldPath::new("event_type"),
            FilterValue::String("updated".to_string()),
        )),
    );
    let event1 = EventEnvelope::new(TopicPath::new("test"), "updated", Bytes::from("{}"));
    assert!(filter.evaluate(&|field| envelope_field_getter(&event1, field)));

    let event2 = EventEnvelope::new(TopicPath::new("test"), "deleted", Bytes::from("{}"));
    assert!(!filter.evaluate(&|field| envelope_field_getter(&event2, field)));
}

#[test]
fn test_filter_not() {
    let filter = FilterExpr::Not(Box::new(FilterExpr::Eq(
        FieldPath::new("event_type"),
        FilterValue::String("created".to_string()),
    )));
    let event1 = EventEnvelope::new(TopicPath::new("test"), "created", Bytes::from("{}"));
    assert!(!filter.evaluate(&|field| envelope_field_getter(&event1, field)));

    let event2 = EventEnvelope::new(TopicPath::new("test"), "deleted", Bytes::from("{}"));
    assert!(filter.evaluate(&|field| envelope_field_getter(&event2, field)));
}

#[test]
fn test_filter_ne_rejects_equal() {
    let filter = FilterExpr::Ne(
        FieldPath::new("event_type"),
        FilterValue::String("created".to_string()),
    );
    let event = EventEnvelope::new(TopicPath::new("test"), "created", Bytes::from("{}"));
    assert!(!filter.evaluate(&|field| envelope_field_getter(&event, field)));
}

#[test]
fn test_filter_in_rejects_missing() {
    let filter = FilterExpr::In(
        FieldPath::new("event_type"),
        vec![FilterValue::String("a".to_string())],
    );
    let event = EventEnvelope::new(TopicPath::new("test"), "b", Bytes::from("{}"));
    assert!(!filter.evaluate(&|field| envelope_field_getter(&event, field)));
}

#[test]
fn test_filter_from_json() {
    let json = serde_json::json!({
        "event_type": { "in": ["created", "updated"] }
    });
    let filter = FilterExpr::from_json(&json).unwrap();
    let event = EventEnvelope::new(TopicPath::new("test"), "created", Bytes::from("{}"));
    let result = filter.evaluate(&|field| envelope_field_getter(&event, field));
    assert!(result);

    // Empty object must return None
    assert!(FilterExpr::from_json(&serde_json::json!({})).is_none());
    // Unknown operator must return None
    assert!(FilterExpr::from_json(&serde_json::json!({"field": {"unknown_op": 123}})).is_none());
    // Non-object must return None
    assert!(FilterExpr::from_json(&serde_json::json!("not_an_object")).is_none());
}

#[test]
fn test_envelope_field_getter_payload_and_source() {
    use crate::types::{EventSource, SourceKind};
    use std::collections::HashMap;

    let mut metadata = HashMap::new();
    metadata.insert("region".to_string(), "eu-west-1".to_string());

    let payload = Bytes::from(r#"{"user":{"id":42,"active":true,"score":9.5,"details":null}}"#);
    let mut event = EventEnvelope::new(TopicPath::new("orders/1"), "created", payload);
    event.source = Some(EventSource {
        kind: SourceKind::Database,
        id: "pg-primary".to_string(),
        metadata,
    });

    assert_eq!(
        envelope_field_getter(&event, &FieldPath::new("event_type")),
        Some(FilterValue::String("created".to_string()))
    );
    assert_eq!(
        envelope_field_getter(&event, &FieldPath::new("topic")),
        Some(FilterValue::String("orders/1".to_string()))
    );
    assert_eq!(
        envelope_field_getter(&event, &FieldPath::new("source.id")),
        Some(FilterValue::String("pg-primary".to_string()))
    );
    assert_eq!(
        envelope_field_getter(&event, &FieldPath::new("source.metadata.region")),
        Some(FilterValue::String("eu-west-1".to_string()))
    );
    assert_eq!(
        envelope_field_getter(&event, &FieldPath::new("payload.user.id")),
        Some(FilterValue::Integer(42))
    );
    assert_eq!(
        envelope_field_getter(&event, &FieldPath::new("user.active")),
        Some(FilterValue::Bool(true))
    );
    assert_eq!(
        envelope_field_getter(&event, &FieldPath::new("user.details")),
        Some(FilterValue::Null)
    );
    assert_eq!(
        envelope_field_getter(&event, &FieldPath::new("nonexistent")),
        None
    );
}

#[test]
fn test_envelope_field_getter_cached() {
    let payload_val = serde_json::json!({"order_id": 999});
    let event = EventEnvelope::new(TopicPath::new("orders"), "created", Bytes::from("{}"));

    let res = envelope_field_getter_cached(&event, &FieldPath::new("order_id"), Some(&payload_val));
    assert_eq!(res, Some(FilterValue::Integer(999)));

    let topic_res =
        envelope_field_getter_cached(&event, &FieldPath::new("topic"), Some(&payload_val));
    assert_eq!(topic_res, Some(FilterValue::String("orders".to_string())));
}
