//! Pre-execution enforcement for the query hot path, split out of
//! `run_query_inner` so the handler body stays small. Every check here is a
//! READ over `(state, request)` that either short-circuits with a ready
//! `Response` (`Err`) or lets the request proceed (`Ok`). The order, the exact
//! log lines, and the exact status mapping are byte-identical to the previously-
//! inlined chain — moving them changes nothing observable.
use data_plane_core::{Plan, WorkloadContext};

use super::helpers::{
    bad_request, forbidden_suspended, map_data_plane_error, not_implemented, payment_required,
    spend_capped, too_many_requests, validate_identity_mount,
};
use super::query::QueryRequest;
use super::state::AppState;
use crate::ratelimit::tier_rate;

/// Run the full pre-execution guard chain. `Ok(())` ⇒ proceed to the planner-
/// approved pool dispatch; `Err(resp)` ⇒ return `resp` immediately. Side effects
/// limited to the two flag-gated B5 observability emits (a counter bump + a log
/// line), exactly as before.
pub(super) async fn enforce_pre_execution(
    state: &AppState,
    request: &QueryRequest,
) -> Result<(), axum::response::Response> {
    emit_tenant_obs(state, request);
    if let Err(message) = validate_identity_mount(state, &request.identity, &request.mount) {
        return Err(bad_request(message));
    }
    if request.operation.resource.trim().is_empty() {
        return Err(bad_request("operation.resource is required".to_string()));
    }
    reject_unexecutable_engine(request)?;
    enforce_rate_limit(state, request).await?;
    enforce_honor_sets(state, request)?;
    run_capability_planner(state, request)?;
    reject_unsupported_search(request)?;
    Ok(())
}

/// B5 per-tenant observability (Pillars 1 & 3). Both arms are flag-gated OFF by
/// default; when OFF this is two `bool` tests that emit nothing → `/metrics` and
/// the log stream are byte-identical to the pre-B5 baseline (kernel rule #5).
/// `tenant_id` is a FIELD only — never a Loki/Prometheus label — so it adds no
/// cardinality. Covers a read AND a write on both doors.
fn emit_tenant_obs(state: &AppState, request: &QueryRequest) {
    // Pillar 3: record ONE request into the BOUNDED per-tenant counter (hard-
    // capped at N+1 series inside `record_tenant_request`). AND-gated:
    // `tenant_obs_counter` is already AND(tenant_obs, …_COUNTER) from config.
    if state.config.tenant_obs_counter {
        state
            .metrics
            .record_tenant_request(&request.identity.tenant_id);
    }
    // Pillar 1: emit ONE per-request log event carrying tenant_id as a STRUCTURED
    // FIELD. The `.instrument(span)` wrapper alone is not enough — a span only
    // surfaces its fields when an event fires inside it — so this explicit event
    // is the field promtail extracts (`| json | tenant_id="X"`).
    if state.config.tenant_obs {
        tracing::info!(tenant_id = %request.identity.tenant_id, "data-plane request");
    }
}

/// Engines with a live Rust pool IN THIS BUILD (feature-gated; default = all
/// nine, nano = sqlite only). MariaDB rides the MySQL adapter. Engines beyond
/// this list (jdbc, cassandra, neo4j, es, qdrant, influx) stay contract-only and
/// are rejected with a 501 here.
// ponytail: irreducible engine allowlist — one cfg-gated entry per pooled engine
fn reject_unexecutable_engine(request: &QueryRequest) -> Result<(), axum::response::Response> {
    let executable_engines: &[&str] = &[
        #[cfg(feature = "postgres")]
        "postgresql",
        #[cfg(feature = "postgres")]
        "cockroachdb",
        #[cfg(feature = "mongodb")]
        "mongodb",
        #[cfg(feature = "mysql")]
        "mysql",
        #[cfg(feature = "mysql")]
        "mariadb",
        #[cfg(feature = "redis")]
        "redis",
        #[cfg(feature = "sqlite")]
        "sqlite",
        #[cfg(feature = "mssql")]
        "mssql",
        #[cfg(feature = "http")]
        "http",
        // 8th engine (OFF by default): DynamoDB-compatible adapter. cfg-gated so
        // the default executable-engine allowlist is byte-identical; a `dynamodb`
        // mount is dispatchable only in a `--features dynamodb` build.
        #[cfg(feature = "dynamodb")]
        "dynamodb",
    ];
    if !executable_engines.contains(&request.mount.engine.as_str()) {
        return Err(not_implemented(
            "engine_execution_not_enabled",
            &format!(
                "engine has no Rust pool in this build; supported engines: {}",
                executable_engines.join(", ")
            ),
        ));
    }
    Ok(())
}

/// Phase 4 tiering — per-tenant token-bucket rate limit. The mount's tier mask
/// carries rps/burst; an untiered mount (no mask) is unlimited, so this is a
/// no-op until a package is assigned. Keyed on the TRUSTED envelope tenant, so it
/// survives the Phase-7 TS bypass; Kong's per-IP limit is the coarse outer shell.
async fn enforce_rate_limit(
    state: &AppState,
    request: &QueryRequest,
) -> Result<(), axum::response::Response> {
    if let Some((rps, burst)) = tier_rate(request.mount.capability_overrides.as_ref()) {
        if !state
            .ratelimiter
            .allow(&request.identity.tenant_id, rps, burst)
            .await
        {
            tracing::warn!(
                target: "audit",
                event = "rate_limited",
                tenant = %request.identity.tenant_id,
                engine = %request.mount.engine,
                op = ?request.operation.op,
                rps,
                "tenant exceeded package rate limit (429)"
            );
            return Err(too_many_requests(rps));
        }
    }
    Ok(())
}

/// Track-B honor sets — three cumulative/administrative budgets, each OFF by
/// default and each short-circuiting on its `bool` before any snapshot lookup
/// (byte-parity when off): cumulative usage quota (402), absolute spend cap
/// (402, distinct `spend_capped` code), and abuse/KYC suspension (403).
fn enforce_honor_sets(
    state: &AppState,
    request: &QueryRequest,
) -> Result<(), axum::response::Response> {
    // CUMULATIVE per-period usage quota. Distinct from the 429 rate cap (per-
    // request) and the max_rows clamp (per-query): the period-cumulative budget.
    if state.config.quota_enforcement && state.quota_over.is_over(&request.identity.tenant_id) {
        tracing::warn!(
            target: "audit",
            event = "quota_exceeded",
            tenant = %request.identity.tenant_id,
            engine = %request.mount.engine,
            op = ?request.operation.op,
            "tenant exceeded package usage quota (402)"
        );
        return Err(payment_required());
    }
    // ABSOLUTE per-tenant spend budget. DISTINCT 402 signal from the quota 402
    // above (usage quota vs. money cap).
    if state.config.spend_caps && state.spend_over.is_over(&request.identity.tenant_id) {
        tracing::warn!(
            target: "audit",
            event = "spend_capped",
            tenant = %request.identity.tenant_id,
            engine = %request.mount.engine,
            op = ?request.operation.op,
            "tenant exceeded spend cap (402)"
        );
        return Err(spend_capped());
    }
    // Administrative block — a 403 (account blocked), NOT a 402 ("pay/upgrade").
    if state.config.suspend_reader && state.suspended.is_over(&request.identity.tenant_id) {
        tracing::warn!(
            target: "audit",
            event = "tenant_suspended",
            tenant = %request.identity.tenant_id,
            engine = %request.mount.engine,
            op = ?request.operation.op,
            "suspended tenant request rejected (403)"
        );
        return Err(forbidden_suspended());
    }
    Ok(())
}

/// Capability-aware planner (G6, two-phase) + the Phase-4 tier capability gate.
/// Phase 1 rejects an impossible (engine, op) pair; Phase 2 routes by op shape
/// over the const cost table. No-op for the engines mounted today (plain CRUD has
/// an empty shape → every current request stays Native, parity-safe). `/v1/query`
/// is never inside a tx or streaming, so the workload context is plain.
fn run_capability_planner(
    state: &AppState,
    request: &QueryRequest,
) -> Result<(), axum::response::Response> {
    let Some(descriptor) = state
        .engines
        .iter()
        .find(|e| e.engine == request.mount.engine)
    else {
        return Ok(());
    };
    // Phase 4 tiering — capability gate. The descriptor says what the ENGINE can
    // do; the tenant's package mask may narrow it. A masked-off-but-engine-
    // supported op is a 403 (upgrade), DISTINCT from the planner's 422 for an op
    // the engine can't serve at all. No-op when there's no mask (parity).
    if let Err(err) = data_plane_core::tier_gate(
        &request.operation,
        &descriptor.capabilities,
        request.mount.capability_overrides.as_ref(),
    ) {
        tracing::warn!(
            target: "audit",
            event = "capability_gated",
            tenant = %request.identity.tenant_id,
            engine = %request.mount.engine,
            op = ?request.operation.op,
            "package tier denied operation (403)"
        );
        return Err(map_data_plane_error(&err));
    }
    let decision = data_plane_core::plan(
        &request.operation,
        &request.mount.engine,
        &descriptor.capabilities,
        &WorkloadContext::default(),
        state.config.planner_federation_enabled,
    );
    match decision.plan {
        Plan::Native => Ok(()), // fall through to pool execution (unchanged)
        Plan::Reject(err) => {
            tracing::info!(reason = decision.reason, engine = %request.mount.engine, "planner rejected operation");
            Err(map_data_plane_error(&err))
        }
        Plan::Federate { target } => {
            // The federation seam (resolve_federation) lowers Federate to a
            // Reject while the flag is off, so this arm is reachable only once
            // federation is wired. Until then it is a clean 501.
            tracing::info!(
                reason = decision.reason,
                target,
                "planner selected federation target (not yet executable)"
            );
            Err(map_data_plane_error(
                &data_plane_core::DataPlaneError::NotImplemented {
                    feature: format!("federation to {target}"),
                },
            ))
        }
    }
}

/// FTS / vector search are Postgres-native ops (to_tsvector + ts_rank / pgvector
/// distance operators). Any other engine rejects with a clean 422 rather than
/// silently ignoring the clause and returning unfiltered rows — engine-agnostic
/// by construction (capability honestly declared, only Postgres serves it).
fn reject_unsupported_search(request: &QueryRequest) -> Result<(), axum::response::Response> {
    if (request.operation.search.is_some() || request.operation.vector.is_some())
        && request.mount.engine != "postgresql"
    {
        return Err(map_data_plane_error(
            &data_plane_core::DataPlaneError::UnsupportedCapability {
                engine: request.mount.engine.clone(),
                capability: if request.operation.search.is_some() {
                    "fulltext_search".to_string()
                } else {
                    "vector_search".to_string()
                },
            },
        ));
    }
    Ok(())
}
