//! Liveness, capability advertisement, and Prometheus metrics: the probe/scrape
//! surface plus the `track_metrics` middleware. Engine descriptors live here.
use axum::body::Body;
use axum::extract::{Request, State};
use axum::http::header;
use axum::middleware::Next;
use axum::response::Response;
use axum::Json;
use data_plane_core::EngineCapabilities;
use serde::Serialize;

use super::state::AppState;

/// Counts every finished request by status class, except the scrape/probe
/// paths so the counters reflect real API traffic.
pub(super) async fn track_metrics(
    State(state): State<AppState>,
    req: Request,
    next: Next,
) -> Response {
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
/// `baas_*` shape as the Go control plane. The body is the concatenation, in
/// order, of one append-helper per metric family — the wire output is byte-for-
/// byte what the inline builder produced.
pub(super) async fn metrics_handler(State(state): State<AppState>) -> Response {
    use super::metrics_text::{
        write_outbox_and_pool_conns, write_pool_and_cache_counters, write_service_and_requests,
    };
    let mut out = String::new();
    write_service_and_requests(&mut out, &state);
    write_pool_and_cache_counters(&mut out, &state);
    write_outbox_and_pool_conns(&mut out, &state).await;
    Response::builder()
        .header(
            header::CONTENT_TYPE,
            "text/plain; version=0.0.4; charset=utf-8",
        )
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
// ponytail: irreducible descriptor table — one EngineDescriptor literal per engine, cfg-gated
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
