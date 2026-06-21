/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   metrics_text.rs                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:32:20 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:32:21 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Prometheus exposition text builders for `/metrics`, one append-helper per
//! metric family. Split out of `health::metrics_handler` so each writer stays
//! small; concatenated in order, the wire output is byte-for-byte what the
//! single inline builder produced. All consume a shared `&mut String` buffer.
use crate::metrics::escape_label;
use data_plane_core::PoolRegistry;

use super::state::AppState;

/// service_up + uptime + HTTP request counts (incl. the optional per-tenant
/// counter line). First block of the exposition.
pub(super) fn write_service_and_requests(out: &mut String, state: &AppState) {
    let (_, c2, c4, c5) = state.metrics.snapshot();
    out.push_str("# HELP baas_service_up 1 while the service is serving\n");
    out.push_str("# TYPE baas_service_up gauge\n");
    out.push_str("baas_service_up{service=\"data-plane-router\"} 1\n");
    out.push_str("# HELP baas_uptime_seconds Seconds since process start\n");
    out.push_str("# TYPE baas_uptime_seconds gauge\n");
    out.push_str(&format!(
        "baas_uptime_seconds{{service=\"data-plane-router\"}} {}\n",
        state.metrics.uptime_secs()
    ));
    out.push_str("# HELP baas_http_requests_total HTTP requests by status class\n");
    out.push_str("# TYPE baas_http_requests_total counter\n");
    for (class, n) in [("2xx", c2), ("4xx", c4), ("5xx", c5)] {
        out.push_str(&format!(
            "baas_http_requests_total{{service=\"data-plane-router\",status=\"{class}\"}} {n}\n"
        ));
    }
    // B5 per-tenant observability (Pillar 3, OPTIONAL) — additionally emit a
    // tenant_id-labeled line on THIS counter ONLY (never a histogram, never the
    // cache/pool/outbox counters). The set is HARD-CAPPED at N+1 distinct tenants
    // (the over-cap fold is the `tenant_id="_over_cap"` sentinel), so this adds at
    // most N+1 series regardless of tenant count. The snapshot is EMPTY at parity
    // (the counter is only written when `tenant_obs_counter` is ON), so when the
    // flag is OFF this loop emits ZERO lines and `/metrics` is byte-identical to
    // today. The labels are already `escape_label`-sanitized (they are the stored
    // keys), so they are emitted verbatim inside the quotes. No `status` label on
    // these lines (one series per tenant) keeps the ceiling at exactly N+1.
    for (tenant_id, n) in state.metrics.tenant_requests_snapshot() {
        out.push_str(&format!(
            "baas_http_requests_total{{service=\"data-plane-router\",tenant_id=\"{tenant_id}\"}} {n}\n"
        ));
    }
}

/// Pool lifecycle + verify/mount cache + ratelimit-tracked gauge. Second block.
pub(super) fn write_pool_and_cache_counters(out: &mut String, state: &AppState) {
    // Scale counters (B3): pool lifecycle, cache effectiveness, limiter map —
    // the signals the 10K-tenant experiments watch. evicted_total climbing at
    // steady state == the mount working set exceeds DATA_PLANE_MAX_POOLS.
    let (pools_created, pools_evicted, pools_reaped, pools_open) = state.registry.scale_counters();
    out.push_str("# HELP baas_data_plane_pools_open Engine pools currently cached\n");
    out.push_str("# TYPE baas_data_plane_pools_open gauge\n");
    out.push_str(&format!(
        "baas_data_plane_pools_open{{service=\"data-plane-router\"}} {pools_open}\n"
    ));
    out.push_str("# HELP baas_data_plane_pool_events_total Pool lifecycle events since start\n");
    out.push_str("# TYPE baas_data_plane_pool_events_total counter\n");
    for (event, n) in [
        ("created", pools_created),
        ("evicted", pools_evicted),
        ("reaped", pools_reaped),
    ] {
        out.push_str(&format!(
            "baas_data_plane_pool_events_total{{service=\"data-plane-router\",event=\"{event}\"}} {n}\n"
        ));
    }
    write_cache_and_ratelimit(out, state);
}

/// Verify/mount cache hit/miss counters + the ratelimit-tracked gauge. Tail of
/// the second exposition block (kept separate so each writer stays ≤40 lines).
fn write_cache_and_ratelimit(out: &mut String, state: &AppState) {
    let (verify_hit, verify_miss, mount_hit, mount_miss) = state.metrics.cache_snapshot();
    out.push_str(
        "# HELP baas_data_plane_cache_events_total Verify/mount cache lookups by result\n",
    );
    out.push_str("# TYPE baas_data_plane_cache_events_total counter\n");
    for (cache, result, n) in [
        ("verify", "hit", verify_hit),
        ("verify", "miss", verify_miss),
        ("mount", "hit", mount_hit),
        ("mount", "miss", mount_miss),
    ] {
        out.push_str(&format!(
            "baas_data_plane_cache_events_total{{service=\"data-plane-router\",cache=\"{cache}\",result=\"{result}\"}} {n}\n"
        ));
    }
    out.push_str(
        "# HELP baas_data_plane_ratelimit_tracked Tenant token buckets currently tracked\n",
    );
    out.push_str("# TYPE baas_data_plane_ratelimit_tracked gauge\n");
    out.push_str(&format!(
        "baas_data_plane_ratelimit_tracked{{service=\"data-plane-router\"}} {}\n",
        state.ratelimiter.tracked()
    ));
}

/// Background-outbox queue health + live per-mount pool connection gauges (the
/// only `.await` block, reading `PoolRegistry::stats()`). Final block.
pub(super) async fn write_outbox_and_pool_conns(out: &mut String, state: &AppState) {
    // D-write-tail: background outbox queue health. `dropped` > 0 means the
    // worker can't keep up (widen DATA_PLANE_OUTBOX_QUEUE or add capacity);
    // enqueued − written − dropped ≈ queue depth in flight.
    let (ob_enq, ob_wr, ob_drop, ob_fail) = state.metrics.outbox_snapshot();
    out.push_str(
        "# HELP baas_data_plane_outbox_events_total Background outbox emission by stage\n",
    );
    out.push_str("# TYPE baas_data_plane_outbox_events_total counter\n");
    for (stage, n) in [
        ("enqueued", ob_enq),
        ("written", ob_wr),
        ("dropped", ob_drop),
        ("failed", ob_fail),
    ] {
        out.push_str(&format!(
            "baas_data_plane_outbox_events_total{{service=\"data-plane-router\",stage=\"{stage}\"}} {n}\n"
        ));
    }
    out.push_str("# HELP baas_data_plane_pool_connections Pool connections per mount and state\n");
    out.push_str("# TYPE baas_data_plane_pool_connections gauge\n");
    if let Ok(stats) = state.registry.stats().await {
        for s in stats {
            let mount = escape_label(&s.mount_id);
            let engine = escape_label(&s.engine);
            for (st, v) in [
                ("active", s.active_connections),
                ("idle", s.idle_connections),
                ("waiting", s.waiting_requests),
            ] {
                out.push_str(&format!(
                    "baas_data_plane_pool_connections{{service=\"data-plane-router\",mount=\"{mount}\",engine=\"{engine}\",state=\"{st}\"}} {v}\n"
                ));
            }
        }
    }
}
