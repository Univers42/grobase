/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   getter.rs                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Field extraction from [`EventEnvelope`](crate::types::EventEnvelope).

use super::{FieldPath, FilterValue};

/// Extract a field value from an
/// [`EventEnvelope`](crate::types::EventEnvelope) by [`FieldPath`].
///
/// Supports envelope-level fields (`event_type`, `topic`, `source.*`)
/// and payload-level fields (any path inside the JSON payload).
pub fn envelope_field_getter(
    event: &crate::types::EventEnvelope,
    field: &FieldPath,
) -> Option<FilterValue> {
    match field.0.as_str() {
        "event_type" => Some(FilterValue::String(event.event_type.clone())),
        "topic" => Some(FilterValue::String(event.topic.as_str().to_string())),
        "source.kind" => event
            .source
            .as_ref()
            .map(|s| FilterValue::String(format!("{:?}", s.kind))),
        "source.id" => event
            .source
            .as_ref()
            .map(|s| FilterValue::String(s.id.clone())),
        s if s.starts_with("source.metadata.") => {
            extract_source_metadata(event, &s["source.metadata.".len()..])
        }
        s if s.starts_with("payload.") => {
            extract_payload_field(&event.payload, &s["payload.".len()..])
        }
        bare => extract_payload_field(&event.payload, bare),
    }
}

/// Extract a metadata field from the event source.
fn extract_source_metadata(event: &crate::types::EventEnvelope, key: &str) -> Option<FilterValue> {
    event
        .source
        .as_ref()
        .and_then(|s| s.metadata.get(key).map(|v| FilterValue::String(v.clone())))
}

/// Extract a field from a JSON payload byte slice.
///
/// Supports dot-separated nested paths like `"user.name"`.
fn extract_payload_field(payload: &[u8], path: &str) -> Option<FilterValue> {
    let parsed: serde_json::Value = serde_json::from_slice(payload).ok()?;
    let mut current = &parsed;
    for segment in path.split('.') {
        current = current.get(segment)?;
    }
    json_value_to_filter_value(current)
}

/// Convert a JSON value into a [`FilterValue`], returning `None` for
/// arrays and objects (which are not directly filterable).
#[allow(clippy::option_if_let_else)]
fn json_value_to_filter_value(v: &serde_json::Value) -> Option<FilterValue> {
    match v {
        serde_json::Value::String(s) => Some(FilterValue::String(s.clone())),
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Some(FilterValue::Integer(i))
            } else {
                n.as_f64().map(FilterValue::Float)
            }
        }
        serde_json::Value::Bool(b) => Some(FilterValue::Bool(*b)),
        serde_json::Value::Null => Some(FilterValue::Null),
        _ => None,
    }
}

/// Extract a field value using a **pre-parsed** JSON payload.
///
/// Avoids re-parsing `event.payload` on every call — critical when
/// evaluating multiple fields against the same event in the bitmap
/// lookup path.
///
/// If `parsed_payload` is `None` (e.g. the payload is not valid JSON),
/// payload field lookups return `None` while envelope-level fields
/// still work.
pub fn envelope_field_getter_cached(
    event: &crate::types::EventEnvelope,
    field: &FieldPath,
    parsed_payload: Option<&serde_json::Value>,
) -> Option<FilterValue> {
    match field.0.as_str() {
        "event_type" => Some(FilterValue::String(event.event_type.clone())),
        "topic" => Some(FilterValue::String(event.topic.as_str().to_string())),
        "source.kind" => event
            .source
            .as_ref()
            .map(|s| FilterValue::String(format!("{:?}", s.kind))),
        "source.id" => event
            .source
            .as_ref()
            .map(|s| FilterValue::String(s.id.clone())),
        s if s.starts_with("source.metadata.") => {
            extract_source_metadata(event, &s["source.metadata.".len()..])
        }
        s if s.starts_with("payload.") => {
            extract_payload_field_cached(parsed_payload, &s["payload.".len()..])
        }
        bare => extract_payload_field_cached(parsed_payload, bare),
    }
}

/// Extract a field from a pre-parsed JSON value (zero re-parse cost).
fn extract_payload_field_cached(
    parsed: Option<&serde_json::Value>,
    path: &str,
) -> Option<FilterValue> {
    let root = parsed?;
    let mut current = root;
    for segment in path.split('.') {
        current = current.get(segment)?;
    }
    json_value_to_filter_value(current)
}
