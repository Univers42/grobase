/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   bench_micro.rs                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Micro-benchmarks: `SequenceGenerator` + `TopicPattern` matching.
//!
//! Run with: `cargo bench -p realtime-engine --bench bench_micro`
#![allow(clippy::expect_used)]

use std::time::Duration;

use criterion::{black_box, criterion_group, criterion_main, Criterion};
use realtime_core::{TopicPath, TopicPattern};
use realtime_engine::SequenceGenerator;

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

criterion_group!(benches, bench_sequence_generator, bench_topic_pattern,);
criterion_main!(benches);
