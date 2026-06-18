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
fn test_filter_from_json() {
    let json = serde_json::json!({
        "event_type": { "in": ["created", "updated"] }
    });
    let filter = FilterExpr::from_json(&json).unwrap();
    let event = EventEnvelope::new(TopicPath::new("test"), "created", Bytes::from("{}"));
    let result = filter.evaluate(&|field| envelope_field_getter(&event, field));
    assert!(result);
}
