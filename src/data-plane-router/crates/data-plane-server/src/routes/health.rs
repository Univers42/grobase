//! Liveness, capability advertisement, and Prometheus metrics: the probe/scrape
//! surface plus the `track_metrics` middleware. Engine descriptors live here.
use axum::body::Body;
use axum::extract::{Request, State};
use axum::http::header;
use axum::middleware::Next;
use axum::response::Response;
use axum::Json;
use data_plane_core::{EngineCapabilities, PoolRegistry};
use serde::Serialize;

use crate::metrics::escape_label;
use super::state::AppState;

/// Counts every finished request by status class, except the scrape/probe
/// paths so the counters reflect real API traffic.
pub(super) async fn track_metrics(State(state): State<AppState>, req: Request, next: Next) -> Response {
    let path = req.uri().path().to_string();
    let method = req.method().clone();
    // Capture the inbound W3C trace context + correlation id so data-plane logs
    // join the same distributed trace as the TS query-router and Go control
    // plane (wiki/05 §2 — cross-tier observability).
    let traceparent = header_str(&req, "traceparent");
    let request_id = header_str(&req, "x-request-id");
    let resp = next.run(req).await;
    if path != "/metrics" && path != "/v1/health" {
        let status = resp.status().as_u16();
        state.metrics.record(status);
        tracing::info!(
            %method,
            path = %path,
            status,
            traceparent = %traceparent,
            request_id = %request_id,
            "data-plane request"
        );
    }
    resp
}

fn header_str(req: &Request, name: &str) -> String {
    req.headers()
        .get(name)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string()
}

/// Prometheus exposition: service_up + uptime + request counts + per-mount pool
/// saturation (from the live `PoolRegistry::stats()`). Dependency-free, same
/// `baas_*` shape as the Go control plane.
pub(super) async fn metrics_handler(State(state): State<AppState>) -> Response {
    let (_, c2, c4, c5) = state.metrics.snapshot();
    let mut out = String::new();
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
    let (verify_hit, verify_miss, mount_hit, mount_miss) = state.metrics.cache_snapshot();
    out.push_str("# HELP baas_data_plane_cache_events_total Verify/mount cache lookups by result\n");
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
    out.push_str("# HELP baas_data_plane_ratelimit_tracked Tenant token buckets currently tracked\n");
    out.push_str("# TYPE baas_data_plane_ratelimit_tracked gauge\n");
    out.push_str(&format!(
        "baas_data_plane_ratelimit_tracked{{service=\"data-plane-router\"}} {}\n",
        state.ratelimiter.tracked()
    ));
    // D-write-tail: background outbox queue health. `dropped` > 0 means the
    // worker can't keep up (widen DATA_PLANE_OUTBOX_QUEUE or add capacity);
    // enqueued − written − dropped ≈ queue depth in flight.
    let (ob_enq, ob_wr, ob_drop, ob_fail) = state.metrics.outbox_snapshot();
    out.push_str("# HELP baas_data_plane_outbox_events_total Background outbox emission by stage\n");
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
    Response::builder()
        .header(header::CONTENT_TYPE, "text/plain; version=0.0.4; charset=utf-8")
        .body(Body::from(out))
        .expect("static metrics response is always valid")
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct HealthResponse {
    status: &'static str,
    service: &'static str,
    version: &'static str,
    product_mode: String,
}

pub(crate) async fn health(State(state): State<AppState>) -> Json<HealthResponse> {
    Json(HealthResponse {
        status: "ok",
        service: "data-plane-router",
        version: env!("CARGO_PKG_VERSION"),
        product_mode: state.config.product_mode.clone(),
    })
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct CapabilitiesResponse {
    router: RouterDescriptor,
    engines: Vec<EngineDescriptor>,
}

#[derive(Debug, Clone, Serialize)]
struct RouterDescriptor {
    language: &'static str,
    mode: String,
    query_execution: &'static str,
    transaction_sessions: &'static str,
    local_pdp: &'static str,
}

#[derive(Debug, Clone, Serialize)]
pub(super) struct EngineDescriptor {
    pub(super) engine: String,
    pub(super) phase: String,
    pub(super) capabilities: EngineCapabilities,
}

pub(crate) async fn capabilities(State(state): State<AppState>) -> Json<CapabilitiesResponse> {
    Json(CapabilitiesResponse {
        router: RouterDescriptor {
            language: "rust",
            mode: state.config.product_mode.clone(),
            query_execution: "postgresql_pool+mongodb_pool+mysql_pool+redis_pool+http_pool",
            transaction_sessions: "contract_only",
            local_pdp: "planned",
        },
        engines: state.engines.as_ref().clone(),
    })
}

/// The engines advertised at `/v1/capabilities` — feature-gated to match what
/// this build can actually pool (the honesty self-check compares the two).
pub(super) fn default_engines() -> Vec<EngineDescriptor> {
    vec![
        #[cfg(feature = "postgres")]
        EngineDescriptor {
            engine: "postgresql".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::postgresql(),
        },
        #[cfg(feature = "postgres")]
        EngineDescriptor {
            engine: "cockroachdb".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::cockroachdb(),
        },
        #[cfg(feature = "mongodb")]
        EngineDescriptor {
            engine: "mongodb".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::mongodb(),
        },
        #[cfg(feature = "mysql")]
        EngineDescriptor {
            engine: "mysql".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::mysql(),
        },
        #[cfg(feature = "mysql")]
        EngineDescriptor {
            engine: "mariadb".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::mariadb(),
        },
        #[cfg(feature = "redis")]
        EngineDescriptor {
            engine: "redis".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::redis(),
        },
        #[cfg(feature = "sqlite")]
        EngineDescriptor {
            engine: "sqlite".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::sqlite(),
        },
        #[cfg(feature = "mssql")]
        EngineDescriptor {
            engine: "mssql".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::mssql(),
        },
        #[cfg(feature = "http")]
        EngineDescriptor {
            engine: "http".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::http(),
        },
        // 8th engine (OFF by default): DynamoDB-compatible adapter. cfg-gated so
        // the default `/v1/capabilities` descriptor is byte-identical to the
        // 7-engine build; it appears ONLY when built `--features dynamodb`.
        #[cfg(feature = "dynamodb")]
        EngineDescriptor {
            engine: "dynamodb".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::dynamodb(),
        },
    ]
}
