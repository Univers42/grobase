/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   engine_bench.rs                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Criterion benchmarks for the realtime-engine hot paths.
//!
//! Run with: `cargo bench -p realtime-engine`
//!
//! For faster parallel runs, use the split bench targets instead:
//!   `cargo bench -p realtime-engine --bench bench_micro` &
//!   `cargo bench -p realtime-engine --bench bench_filter` &
//!   `cargo bench -p realtime-engine --bench bench_registry` &
//!   wait
#![allow(clippy::expect_used)]
#![allow(clippy::unwrap_used)]

use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use criterion::{black_box, criterion_group, criterion_main, BatchSize, BenchmarkId, Criterion};
use realtime_core::{
    filter::{FieldPath, FilterExpr, FilterValue},
    ConnectionId, EventEnvelope, SubConfig, Subscription, SubscriptionId, TopicPath, TopicPattern,
};
use realtime_engine::{
    registry::SubscriptionRegistry, router::EventRouter, FilterIndex, SequenceGenerator,
};
use smol_str::SmolStr;
use tokio::sync::mpsc;

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
// 1. SequenceGenerator
// ───────────────────────────────────────────────────────────────────

fn bench_sequence_generator(c: &mut Criterion) {
    let mut group = c.benchmark_group("sequence_generator");
    group.warm_up_time(Duration::from_millis(500));
    group.measurement_time(Duration::from_secs(2));

    group.bench_function("next_same_topic", |b| {
        let gen = SequenceGenerator::new();
        b.iter(|| gen.next(black_box("orders/created")));
    });

    group.bench_function("next_rotating_topics_10", |b| {
        let gen = SequenceGenerator::new();
        let topics: Vec<String> = (0..10).map(|i| format!("topic/{i}")).collect();
        let mut idx = 0usize;
        b.iter(|| {
            let _ = gen.next(black_box(&topics[idx % topics.len()]));
            idx += 1;
        });
    });

    group.bench_function("current_existing", |b| {
        let gen = SequenceGenerator::new();
        let _ = gen.next("orders/created");
        b.iter(|| gen.current(black_box("orders/created")));
    });

    group.finish();
}

// ───────────────────────────────────────────────────────────────────
// 2. TopicPattern matching
// ───────────────────────────────────────────────────────────────────

fn bench_topic_pattern(c: &mut Criterion) {
    let mut group = c.benchmark_group("topic_pattern");
    group.warm_up_time(Duration::from_millis(500));
    group.measurement_time(Duration::from_secs(2));

    let topic = TopicPath::new("orders/created");

    group.bench_function("exact_match", |b| {
        let pattern = TopicPattern::parse("orders/created");
        b.iter(|| pattern.matches(black_box(&topic)));
    });

    group.bench_function("prefix_match", |b| {
        let pattern = TopicPattern::parse("orders/");
        b.iter(|| pattern.matches(black_box(&topic)));
    });

    group.bench_function("glob_wildcard", |b| {
        let pattern = TopicPattern::parse("orders/*");
        b.iter(|| pattern.matches(black_box(&topic)));
    });

    group.bench_function("glob_double_star", |b| {
        let pattern = TopicPattern::parse("**");
        b.iter(|| pattern.matches(black_box(&topic)));
    });

    group.bench_function("glob_deep_path", |b| {
        let deep = TopicPath::new("a/b/c/d/e/f/g");
        let pattern = TopicPattern::parse("a/b/*/d/*/f/*");
        b.iter(|| pattern.matches(black_box(&deep)));
    });

    group.finish();
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

// ───────────────────────────────────────────────────────────────────
// 5. SubscriptionRegistry (full lookup path)
// ───────────────────────────────────────────────────────────────────

fn bench_registry_lookup(c: &mut Criterion) {
    let mut group = c.benchmark_group("registry_lookup");
    group.warm_up_time(Duration::from_millis(500));
    group.measurement_time(Duration::from_secs(2));

    // ---- linear lookup path ----
    for &n in &[10, 100, 1_000, 10_000] {
        group.bench_with_input(BenchmarkId::new("linear_unfiltered", n), &n, |b, &n| {
            let registry = SubscriptionRegistry::new();
            for i in 0..n {
                let sub = make_sub(i, &format!("s-{i}"), "broadcast", None);
                registry.subscribe(sub, None).unwrap();
            }
            let event = make_event("broadcast", "notify");
            b.iter(|| registry.lookup_matches(black_box(&event)));
        });
    }

    // ---- bitmap lookup path ----
    for &n in &[10, 100, 1_000, 10_000] {
        group.bench_with_input(BenchmarkId::new("bitmap_unfiltered", n), &n, |b, &n| {
            let registry = SubscriptionRegistry::new();
            for i in 0..n {
                let sub = make_sub(i, &format!("s-{i}"), "broadcast", None);
                registry.subscribe(sub, None).unwrap();
            }
            let event = make_event("broadcast", "notify");
            b.iter(|| registry.lookup_matches_bitmap(black_box(&event)));
        });
    }

    // ---- bitmap with eq filter ----
    for &n in &[100, 1_000, 10_000] {
        group.bench_with_input(BenchmarkId::new("bitmap_eq_filter", n), &n, |b, &n| {
            let registry = SubscriptionRegistry::new();
            for i in 0..n {
                let f = eq_filter("event_type", if i % 2 == 0 { "created" } else { "updated" });
                let sub = make_sub(i, &format!("s-{i}"), "orders/*", Some(f));
                registry.subscribe(sub, None).unwrap();
            }
            let event = make_event("orders/123", "created");
            b.iter(|| registry.lookup_matches_bitmap(black_box(&event)));
        });
    }

    // ---- subscribe throughput ----
    group.bench_function("subscribe", |b| {
        let registry = SubscriptionRegistry::new();
        let mut counter = 0u64;
        b.iter(|| {
            let sub = make_sub(counter, &format!("s-{counter}"), "orders/*", None);
            registry.subscribe(black_box(sub), None).unwrap();
            counter += 1;
        });
    });

    // ---- unsubscribe ----
    group.bench_function("unsubscribe", |b| {
        b.iter_batched(
            || {
                let registry = SubscriptionRegistry::new();
                let sub = make_sub(999_999, "s-rm", "orders/*", None);
                registry.subscribe(sub, None).unwrap();
                registry
            },
            |registry| registry.unsubscribe(black_box(ConnectionId(999_999)), "s-rm"),
            BatchSize::SmallInput,
        );
    });

    // ---- remove_connection with 100 subscriptions ----
    group.bench_function("remove_connection_100_subs", |b| {
        b.iter_batched(
            || {
                let registry = SubscriptionRegistry::new();
                for i in 0..100u64 {
                    let sub = make_sub(42, &format!("s-{i}"), &format!("topic/{i}"), None);
                    registry.subscribe(sub, None).unwrap();
                }
                registry
            },
            |registry| registry.remove_connection(black_box(ConnectionId(42))),
            BatchSize::SmallInput,
        );
    });

    group.finish();
}

// ───────────────────────────────────────────────────────────────────
// 6. EventRouter (end-to-end route_event)
// ───────────────────────────────────────────────────────────────────

fn bench_router(c: &mut Criterion) {
    let mut group = c.benchmark_group("router");
    group.warm_up_time(Duration::from_millis(500));
    group.measurement_time(Duration::from_secs(2));

    for &n in &[1, 10, 100, 1_000, 10_000] {
        group.bench_with_input(BenchmarkId::new("route_event", n), &n, |b, &n| {
            let registry = Arc::new(SubscriptionRegistry::new());
            let seq_gen = Arc::new(SequenceGenerator::new());
            let (dispatch_tx, _dispatch_rx) = mpsc::channel(65536);
            let router = EventRouter::new(Arc::clone(&registry), seq_gen, dispatch_tx);
            for i in 0..n {
                let sub = make_sub(i, &format!("s-{i}"), "broadcast", None);
                registry.subscribe(sub, None).unwrap();
            }
            b.iter(|| {
                let event = make_event("broadcast", "notify");
                router.route_event(black_box(event))
            });
        });
    }

    // With eq filters (half match)
    for &n in &[100, 1_000, 10_000] {
        group.bench_with_input(BenchmarkId::new("route_event_eq_filter", n), &n, |b, &n| {
            let registry = Arc::new(SubscriptionRegistry::new());
            let seq_gen = Arc::new(SequenceGenerator::new());
            let (dispatch_tx, _dispatch_rx) = mpsc::channel(65536);
            let router = EventRouter::new(Arc::clone(&registry), seq_gen, dispatch_tx);
            for i in 0..n {
                let f = eq_filter("event_type", if i % 2 == 0 { "created" } else { "updated" });
                let sub = make_sub(i, &format!("s-{i}"), "orders/*", Some(f));
                registry.subscribe(sub, None).unwrap();
            }
            b.iter(|| {
                let event = make_event("orders/123", "created");
                router.route_event(black_box(event))
            });
        });
    }

    // No subscribers (fast path)
    group.bench_function("route_event_no_match", |b| {
        let registry = Arc::new(SubscriptionRegistry::new());
        let seq_gen = Arc::new(SequenceGenerator::new());
        let (dispatch_tx, _dispatch_rx) = mpsc::channel(65536);
        let router = EventRouter::new(Arc::clone(&registry), seq_gen, dispatch_tx);
        b.iter(|| {
            let event = make_event("no/match", "test");
            router.route_event(black_box(event))
        });
    });

    group.finish();
}

// ───────────────────────────────────────────────────────────────────
// 7. EventEnvelope serialization
// ───────────────────────────────────────────────────────────────────

fn bench_envelope(c: &mut Criterion) {
    let mut group = c.benchmark_group("envelope");
    group.warm_up_time(Duration::from_millis(500));
    group.measurement_time(Duration::from_secs(2));

    group.bench_function("create", |b| {
        b.iter(|| make_event(black_box("orders/created"), black_box("created")));
    });

    group.bench_function("serialize_json", |b| {
        let event = make_event("orders/created", "created");
        b.iter(|| serde_json::to_string(black_box(&event)));
    });

    group.bench_function("deserialize_json", |b| {
        let event = make_event("orders/created", "created");
        let json = serde_json::to_string(&event).expect("serialize");
        b.iter(|| serde_json::from_str::<EventEnvelope>(black_box(&json)));
    });

    group.bench_function("clone_arc", |b| {
        let event = Arc::new(make_event("orders/created", "created"));
        b.iter(|| Arc::clone(black_box(&event)));
    });

    group.bench_function("payload_parse", |b| {
        let event = make_event("orders/created", "created");
        b.iter(|| serde_json::from_slice::<serde_json::Value>(black_box(&event.payload)));
    });

    group.finish();
}

// ───────────────────────────────────────────────────────────────────
// 8. EventPayload::from_envelope (writer hot path)
// ───────────────────────────────────────────────────────────────────

fn bench_event_payload(c: &mut Criterion) {
    use realtime_core::EventPayload;

    let mut group = c.benchmark_group("event_payload");
    group.warm_up_time(Duration::from_millis(500));
    group.measurement_time(Duration::from_secs(2));

    group.bench_function("from_envelope", |b| {
        let event = make_event("orders/created", "created");
        b.iter(|| EventPayload::from_envelope(black_box(&event)));
    });

    group.bench_function("from_envelope_then_serialize", |b| {
        let event = make_event("orders/created", "created");
        b.iter(|| {
            let payload = EventPayload::from_envelope(&event);
            let msg = realtime_core::ServerMessage::Event {
                sub_id: String::new(),
                event: payload,
            };
            serde_json::to_string(black_box(&msg))
        });
    });

    group.finish();
}

// ───────────────────────────────────────────────────────────────────
// Groups
// ───────────────────────────────────────────────────────────────────

criterion_group!(
    benches,
    bench_sequence_generator,
    bench_topic_pattern,
    bench_filter_expr,
    bench_filter_index,
    bench_registry_lookup,
    bench_router,
    bench_envelope,
    bench_event_payload,
);

criterion_main!(benches);
