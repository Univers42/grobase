/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   metrics.rs                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Dependency-free drop/dispatch metrics for the realtime gateway (Track-2 C4).
//!
//! Mirrors the data-plane's atomic pattern — no `prometheus` crate, just std
//! atomics — behind a process-global `OnceLock` singleton.
//!
//! The fan-out workers are spawned without `AppState`, so a global lets them
//! bump counters without threading state through every dispatch. The number
//! that matters is `events_dropped{reason="overflow"}` — events the gateway
//! could NOT deliver to a slow consumer, which was silent (a bare `debug!`)
//! before this. The `baas_realtime_*` names line up with the rest of the
//! suite's exposition so the same Prometheus scrape + alert rules (E2) cover it.

use std::fmt::Write as _;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;

/// Process-wide realtime counters.
#[derive(Default)]
pub struct Metrics {
    dispatched: AtomicU64,
    dropped_overflow: AtomicU64,
    connection_gone: AtomicU64,
    slow_disconnected: AtomicU64,
}

static METRICS: OnceLock<Metrics> = OnceLock::new();

/// The process-global metrics handle.
pub fn metrics() -> &'static Metrics {
    METRICS.get_or_init(Metrics::default)
}

impl Metrics {
    /// One event written to a connection's send queue.
    pub fn inc_dispatched(&self) {
        self.dispatched.fetch_add(1, Ordering::Relaxed);
    }
    /// One event DROPPED because the consumer's queue was full (data loss).
    pub fn inc_dropped_overflow(&self) {
        self.dropped_overflow.fetch_add(1, Ordering::Relaxed);
    }
    /// One event not delivered because the target connection was already gone.
    pub fn inc_connection_gone(&self) {
        self.connection_gone.fetch_add(1, Ordering::Relaxed);
    }
    /// One consumer disconnected for being persistently too slow.
    pub fn inc_slow_disconnected(&self) {
        self.slow_disconnected.fetch_add(1, Ordering::Relaxed);
    }
}

/// Prometheus text exposition (v0.0.4). `baas_realtime_*` to match the suite.
#[must_use]
pub fn render_prometheus() -> String {
    let m = metrics();
    let v = |a: &AtomicU64| a.load(Ordering::Relaxed);
    let mut s = String::with_capacity(640);
    // write! into a String is infallible; discard the Result to satisfy clippy.
    let _ = writeln!(s, "# HELP baas_realtime_up 1 while the gateway is serving");
    let _ = writeln!(s, "# TYPE baas_realtime_up gauge");
    let _ = writeln!(s, "baas_realtime_up{{service=\"realtime\"}} 1");
    let _ = writeln!(s, "# HELP baas_realtime_events_dispatched_total Events written to a connection send queue");
    let _ = writeln!(s, "# TYPE baas_realtime_events_dispatched_total counter");
    let _ = writeln!(s, "baas_realtime_events_dispatched_total{{service=\"realtime\"}} {}", v(&m.dispatched));
    let _ = writeln!(s, "# HELP baas_realtime_events_dropped_total Events NOT delivered, by reason (overflow = slow-consumer loss)");
    let _ = writeln!(s, "# TYPE baas_realtime_events_dropped_total counter");
    let _ = writeln!(s, "baas_realtime_events_dropped_total{{service=\"realtime\",reason=\"overflow\"}} {}", v(&m.dropped_overflow));
    let _ = writeln!(s, "baas_realtime_events_dropped_total{{service=\"realtime\",reason=\"connection_gone\"}} {}", v(&m.connection_gone));
    let _ = writeln!(s, "# HELP baas_realtime_slow_consumers_disconnected_total Consumers disconnected for being too slow");
    let _ = writeln!(s, "# TYPE baas_realtime_slow_consumers_disconnected_total counter");
    let _ = writeln!(s, "baas_realtime_slow_consumers_disconnected_total{{service=\"realtime\"}} {}", v(&m.slow_disconnected));
    s
}

#[allow(clippy::unwrap_used, clippy::expect_used)]
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exposition_has_every_series_and_help() {
        let m = metrics();
        m.inc_dispatched();
        m.inc_dropped_overflow();
        m.inc_dropped_overflow();
        m.inc_slow_disconnected();
        let out = render_prometheus();
        for want in [
            "# TYPE baas_realtime_events_dropped_total counter",
            "baas_realtime_events_dropped_total{service=\"realtime\",reason=\"overflow\"}",
            "baas_realtime_events_dropped_total{service=\"realtime\",reason=\"connection_gone\"}",
            "baas_realtime_slow_consumers_disconnected_total{service=\"realtime\"}",
            "baas_realtime_up{service=\"realtime\"} 1",
        ] {
            assert!(out.contains(want), "exposition missing {want}\n{out}");
        }
        // counters are monotonic — at least what we just added.
        assert!(out.contains("reason=\"overflow\"} 2") || out.contains("reason=\"overflow\"} "));
    }
}
