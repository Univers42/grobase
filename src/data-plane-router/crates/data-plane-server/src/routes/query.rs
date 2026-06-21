/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   query.rs                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:32:32 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:32:33 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! The query hot path: the internal `/v1/query` handler and the shared
//! `run_query` / `run_query_inner` core that both doors (internal + bypass)
//! funnel through — owner-scoping, tier rate-limit, metering, planner, dispatch.
use axum::extract::State;
use axum::response::IntoResponse;
use axum::Json;
use data_plane_core::{
    DataOperation, DataOperationKind, DatabaseMount, PoolRegistry, RequestIdentity,
};
use serde::Deserialize;

use super::query_emit::{self, EmitCtx};
use super::state::AppState;
use crate::ratelimit::tier_max_rows;

#[derive(Debug, Clone, Deserialize)]
pub(super) struct QueryRequest {
    pub(super) identity: RequestIdentity,
    pub(super) mount: DatabaseMount,
    pub(super) operation: DataOperation,
}

pub(super) async fn execute_query(
    State(state): State<AppState>,
    Json(request): Json<QueryRequest>,
) -> impl IntoResponse {
    // The internal `/v1/query` is called by the query-router, which emits the
    // outbox event itself — so the data plane must NOT (would double-emit).
    run_query(state, request, false).await
}

/// Core query execution, shared by the internal `/v1/query` (envelope already
/// trusted — the query-router authenticated; `emit_outbox=false`) and the
/// Phase-7 `/data/v1/query` (Rust authenticated; `emit_outbox=true` — the
/// query-router is out of the path, so the data plane emits the row-change
/// event). Owns identity/mount validation, tier rate-limit + capability gate,
/// the planner, and pool dispatch, so both doors enforce IDENTICALLY.
/// Map an operation kind to the ABAC action the policy bundle matches on —
/// mirrors `action_for_op(&str)` (the `/v1/permissions/decide` mapping) so the
/// in-line mask decision is identical to the canonical PDP: list/get→select,
/// upsert→update, the rest pass through.
fn mask_action_for(op: &DataOperationKind) -> &'static str {
    use DataOperationKind::*;
    match op {
        List | Get => "select",
        Upsert | Update => "update",
        Insert => "insert",
        Delete => "delete",
        Batch => "batch",
        Aggregate => "aggregate",
    }
}

/// B5 per-tenant observability (Pillar 1) — thin span wrapper around the real
/// handler body ([`run_query_inner`]). When `config.tenant_obs` is ON, build a
/// per-request span carrying `tenant_id` as a STRUCTURED FIELD and `.instrument`
/// the whole `run_query_inner` future with it, so every event emitted while
/// serving this request (the per-request log line, the audit `mutation`/`read`
/// events, the planner/limit warns) carries the tenant as a log FIELD — exactly
/// what promtail's expressions-only extraction (slice O) reads with
/// `| json | tenant_id="X"`. `.instrument` is the async-correct way to attach a
/// span to a future (an `.entered()` guard held across `.await` would leak the
/// current-span across task boundaries on the multi-thread runtime). When OFF the
/// span is `Span::none()` — instrumenting with it is a no-op, so the tracing path
/// and log output are BYTE-IDENTICAL to baseline (kernel rule #5). `tenant_id` is
/// a FIELD only: never promoted to a Loki label or a Prometheus label here, so it
/// adds ZERO label-series cardinality. Both the internal `/v1/query` and the
/// bypass `/data/v1/query` paths funnel through here, so this single site covers
/// a read AND a write.
pub(super) async fn run_query(
    state: AppState,
    request: QueryRequest,
    emit_outbox: bool,
) -> axum::response::Response {
    use tracing::Instrument;
    let span = if state.config.tenant_obs {
        tracing::info_span!("request", tenant_id = %request.identity.tenant_id)
    } else {
        tracing::Span::none()
    };
    run_query_inner(state, request, emit_outbox)
        .instrument(span)
        .await
}

async fn run_query_inner(
    state: AppState,
    mut request: QueryRequest,
    emit_outbox: bool,
) -> axum::response::Response {
    // Full pre-execution enforcement chain (B5 obs emits, identity/mount + resource
    // validation, engine allowlist, rate limit, honor sets, capability planner +
    // tier gate, search-capability). `Err` short-circuits with the ready response;
    // see `query_guards` for the per-check rationale. Byte-identical order/log
    // lines/status mapping to the previously-inlined chain.
    if let Err(resp) = super::query_guards::enforce_pre_execution(&state, &request).await {
        return resp;
    }

    // Capture the audit/outbox/projection fields before the pool consumes the
    // operation, bundled into the `EmitCtx` the success path reads. Cfg-gated
    // fields mirror the locals they replace, so a lean build is byte-identical.
    let audit_op = request.operation.op.clone();
    #[allow(unused_variables)]
    let is_mutation = matches!(
        audit_op,
        DataOperationKind::Insert
            | DataOperationKind::Update
            | DataOperationKind::Delete
            | DataOperationKind::Upsert
            | DataOperationKind::Batch
    );
    let emit_ctx = EmitCtx {
        audit_tenant: request.identity.tenant_id.clone(),
        audit_engine: request.mount.engine.clone(),
        mask_action: mask_action_for(&audit_op),
        is_mutation,
        outbox_identity: request.identity.clone(),
        // Response projection (`fields`) — applied LAST, after outbox/realtime
        // emission and masks, so server-side consumers keep full rows.
        projection: request.operation.fields.clone(),
        emit_outbox,
        audit_resource: request.operation.resource.clone(),
        #[cfg(any(feature = "control-pg", feature = "nano"))]
        automation_db_id: request.mount.id.clone(),
        #[cfg(any(feature = "control-pg", feature = "nano"))]
        op_wire: audit_op.wire_name(),
        #[cfg(any(feature = "control-pg", feature = "nano"))]
        outbox_data: request.operation.data.clone(),
        #[cfg(any(feature = "control-pg", feature = "nano"))]
        outbox_filter: request.operation.filter.clone(),
        #[cfg(feature = "control-pg")]
        outbox_idem: request.operation.idempotency_key.clone(),
        audit_op,
    };

    // G-QoS sliceA (A6): clamp the rows returned per query to the tier cap. The
    // cap comes from the mount's tier mask (`max_rows`); absent/zero → no clamp
    // (today's behavior, parity). Engine-agnostic — every adapter honors
    // `operation.limit` — so a present cap bounds a missing/larger client limit
    // without touching any adapter. A client limit already at/under the cap is
    // left as-is. Applied just before execution so it covers the bypass path too.
    if let Some(cap) = tier_max_rows(request.mount.capability_overrides.as_ref()) {
        request.operation.limit = Some(request.operation.limit.map_or(cap, |l| l.min(cap)));
    }

    // S8 read-replica routing (DATA_PLANE_READ_REPLICA, default OFF). A pure READ
    // (!is_mutation: List/Get/Aggregate) on a mount carrying a replica DSN is
    // served from the replica's OWN pool (the variant routes inline_dsn ← replica
    // and keys to a distinct `/ro` pool); writes/tx/Batch + flag-OFF stay on the
    // primary, where read-after-write consistency lives by construction. Flag OFF
    // or no replica DSN ⇒ `request.mount` is used UNCHANGED = byte-parity.
    //
    // `read_replica_variant` consumes self, so we GUARD on the replica's presence
    // FIRST and only move `request.mount` when we will actually use the variant —
    // the `else` arm hands the ORIGINAL mount straight through (no clone, no
    // variant), preserving today's exact path at parity.
    let mount_to_open = if state.config.read_replica
        && !emit_ctx.is_mutation
        && request
            .mount
            .replica_inline_dsn
            .as_deref()
            .is_some_and(|d| !d.trim().is_empty())
    {
        request
            .mount
            .read_replica_variant()
            .expect("replica dsn checked present")
    } else {
        request.mount
    };
    let pool = match state.registry.get_or_create(mount_to_open).await {
        Ok(pool) => pool,
        Err(err) => return query_emit::finalize_error(&err),
    };
    match pool.execute(request.operation, request.identity).await {
        Ok(result) => query_emit::finalize_success(&state, &emit_ctx, &*pool, result).await,
        Err(err) => query_emit::finalize_error(&err),
    }
}
