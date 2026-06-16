/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   bench_filter.rs                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Filter expression + filter index benchmarks.
//!
//! Run with: `cargo bench -p realtime-engine --bench bench_filter`
#![allow(clippy::expect_used)]
#![allow(clippy::unwrap_used)]

use std::time::Duration;

use bytes::Bytes;
use criterion::{black_box, criterion_group, criterion_main, BatchSize, BenchmarkId, Criterion};
use realtime_core::{
    filter::{FieldPath, FilterExpr, FilterValue},
    ConnectionId, EventEnvelope, SubConfig, Subscription, SubscriptionId, TopicPath, TopicPattern,
};
use realtime_engine::FilterIndex;
use smol_str::SmolStr;

// ───────────────────────────────────────────────────────────────────
// Helpers
// ───────────────────────────────────────────────────────────────────

fn make_sub(conn_id: u64, sub_id: &str, topic: &str, filter: Option<FilterExpr>) -> Subscription {
    Subscription {
        sub_id: SubscriptionId(SmolStr::new(sub_id)),
        conn_id: ConnectionId(conn_id),
        topic: TopicPattern::parse(topic),
        filter,
        config: SubConfig::default(),
    }
}

fn make_event(topic: &str, event_type: &str) -> EventEnvelope {
    EventEnvelope::new(
        TopicPath::new(topic),
        event_type,
        Bytes::from(r#"{"id":1,"name":"bench","status":"active","value":42}"#),
    )
}

fn eq_filter(field: &str, value: &str) -> FilterExpr {
    FilterExpr::Eq(
        FieldPath::new(field),
        FilterValue::String(value.to_string()),
    )
}

fn in_filter(field: &str, values: &[&str]) -> FilterExpr {
    FilterExpr::In(
        FieldPath::new(field),
        values
            .iter()
            .map(|v| FilterValue::String((*v).to_string()))
            .collect(),
    )
}

fn ne_filter(field: &str, value: &str) -> FilterExpr {
    FilterExpr::Ne(
        FieldPath::new(field),
        FilterValue::String(value.to_string()),
    )
}

// ───────────────────────────────────────────────────────────────────
// 3. FilterExpr evaluation
// ───────────────────────────────────────────────────────────────────

fn bench_filter_expr(c: &mut Criterion) {
    let mut group = c.benchmark_group("filter_expr");
    group.warm_up_time(Duration::from_millis(500));
    group.measurement_time(Duration::from_secs(2));

    let event = make_event("orders/created", "created");

    group.bench_function("eq_envelope_field", |b| {
        let f = eq_filter("event_type", "created");
        let parsed: Option<serde_json::Value> = serde_json::from_slice(&event.payload).ok();
        b.iter(|| {
            let getter = |fld: &FieldPath| {
                realtime_core::filter::envelope_field_getter_cached(&event, fld, parsed.as_ref())
            };
            f.evaluate(black_box(&getter))
        });
    });

    group.bench_function("eq_payload_field", |b| {
        let f = eq_filter("payload.status", "active");
        let parsed: Option<serde_json::Value> = serde_json::from_slice(&event.payload).ok();
        b.iter(|| {
            let getter = |fld: &FieldPath| {
                realtime_core::filter::envelope_field_getter_cached(&event, fld, parsed.as_ref())
            };
            f.evaluate(black_box(&getter))
        });
    });

    group.bench_function("in_3_values", |b| {
        let f = in_filter("event_type", &["created", "updated", "deleted"]);
        let parsed: Option<serde_json::Value> = serde_json::from_slice(&event.payload).ok();
        b.iter(|| {
            let getter = |fld: &FieldPath| {
                realtime_core::filter::envelope_field_getter_cached(&event, fld, parsed.as_ref())
            };
            f.evaluate(black_box(&getter))
        });
    });

    group.bench_function("ne_filter", |b| {
        let f = ne_filter("event_type", "deleted");
        let parsed: Option<serde_json::Value> = serde_json::from_slice(&event.payload).ok();
        b.iter(|| {
            let getter = |fld: &FieldPath| {
                realtime_core::filter::envelope_field_getter_cached(&event, fld, parsed.as_ref())
            };
            f.evaluate(black_box(&getter))
        });
    });

    group.bench_function("and_2_fields", |b| {
        let f = FilterExpr::And(
            Box::new(eq_filter("event_type", "created")),
            Box::new(eq_filter("payload.status", "active")),
        );
        let parsed: Option<serde_json::Value> = serde_json::from_slice(&event.payload).ok();
        b.iter(|| {
            let getter = |fld: &FieldPath| {
                realtime_core::filter::envelope_field_getter_cached(&event, fld, parsed.as_ref())
            };
            f.evaluate(black_box(&getter))
        });
    });

    group.bench_function("no_reparse_vs_reparse", |b| {
        let f = eq_filter("payload.status", "active");
        // Measure WITHOUT pre-parsed payload (re-parses every call)
        b.iter(|| {
            let getter =
                |fld: &FieldPath| realtime_core::filter::envelope_field_getter(&event, fld);
            f.evaluate(black_box(&getter))
        });
    });

    group.finish();
}

// ───────────────────────────────────────────────────────────────────
// 4. FilterIndex (bitmap inverted index)
// ───────────────────────────────────────────────────────────────────

fn bench_filter_index(c: &mut Criterion) {
    let mut group = c.benchmark_group("filter_index");
    group.warm_up_time(Duration::from_millis(500));
    group.measurement_time(Duration::from_secs(2));

    // ---- evaluate with N unfiltered subscriptions ----
    for &n in &[10, 100, 1_000, 10_000] {
        group.bench_with_input(BenchmarkId::new("evaluate_unfiltered", n), &n, |b, &n| {
            let index = FilterIndex::new();
            for i in 0..n {
                let sub = make_sub(i, &format!("s-{i}"), "broadcast", None);
                index.add_subscription(&sub, None).unwrap();
            }
            let event = make_event("broadcast", "notify");
            b.iter(|| index.evaluate(black_box(&event)));
        });
    }

    // ---- evaluate with N eq-filtered subscriptions ----
    for &n in &[10, 100, 1_000, 10_000] {
        group.bench_with_input(BenchmarkId::new("evaluate_eq_filter", n), &n, |b, &n| {
            let index = FilterIndex::new();
            for i in 0u64..n {
                let f = eq_filter("event_type", if i % 2 == 0 { "created" } else { "updated" });
                let sub = make_sub(i, &format!("s-{i}"), "orders/*", Some(f));
                index.add_subscription(&sub, None).unwrap();
            }
            let event = make_event("orders/123", "created");
            b.iter(|| index.evaluate(black_box(&event)));
        });
    }

    // ---- add_subscription throughput ----
    group.bench_function("add_subscription", |b| {
        let index = FilterIndex::new();
        let mut counter = 0u64;
        b.iter(|| {
            let f = eq_filter("event_type", "created");
            let sub = make_sub(counter, &format!("s-{counter}"), "orders/*", Some(f));
            index.add_subscription(black_box(&sub), None).unwrap();
            counter += 1;
        });
    });

    // ---- remove_subscription ----
    group.bench_function("remove_subscription", |b| {
        b.iter_batched(
            || {
                let index = FilterIndex::new();
                let f = eq_filter("event_type", "created");
                let sub = make_sub(999_999, "s-rm", "orders/*", Some(f));
                index.add_subscription(&sub, None).unwrap();
                (index, sub)
            },
            |(index, sub)| index.remove_subscription(black_box(&sub)),
            BatchSize::SmallInput,
        );
    });

    group.finish();
}

criterion_group!(benches, bench_filter_expr, bench_filter_index,);
criterion_main!(benches);
