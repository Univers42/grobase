//! Post-execution success handling for the query hot path, split out of
//! `run_query_inner`. Given the committed `DataResult`, it runs (in order) the
//! audit emit, Track-B metering, the bypass outbox/automation/nano fan-out, the
//! Rust-side ABAC mask, and the response projection — every arm flag-gated OFF by
//! default exactly as before, so at parity this is the same sequence of no-ops
//! and the same `200 OK` body. The captured request fields travel in `EmitCtx`
//! (its cfg-gated fields mirror the locals' cfg attributes verbatim).
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use data_plane_core::{DataResult, EnginePool, RequestIdentity};

use super::helpers::{api_err, map_data_plane_error};
use super::state::AppState;

/// Request fields captured before the pool consumed the operation, carried into
/// the success path. Cfg-gated fields mirror the locals they replace so a lean
/// build compiles to the identical set.
pub(super) struct EmitCtx {
    pub(super) audit_tenant: String,
    pub(super) audit_engine: String,
    pub(super) audit_op: data_plane_core::DataOperationKind,
    pub(super) audit_resource: String,
    pub(super) mask_action: &'static str,
    pub(super) is_mutation: bool,
    pub(super) outbox_identity: RequestIdentity,
    pub(super) projection: Option<Vec<String>>,
    pub(super) emit_outbox: bool,
    #[cfg(any(feature = "control-pg", feature = "nano"))]
    pub(super) automation_db_id: String,
    #[cfg(any(feature = "control-pg", feature = "nano"))]
    pub(super) op_wire: &'static str,
    #[cfg(any(feature = "control-pg", feature = "nano"))]
    pub(super) outbox_data: Option<serde_json::Value>,
    #[cfg(any(feature = "control-pg", feature = "nano"))]
    pub(super) outbox_filter: Option<serde_json::Value>,
    #[cfg(feature = "control-pg")]
    pub(super) outbox_idem: Option<String>,
}

/// The success arm of `run_query_inner`: audit + metering + fan-out + ABAC mask +
/// projection, then `200 OK`. `pool` is needed only by the control-pg automation
/// hook; `emit_outbox` lives on `ctx`. Order is identical to the inlined arm.
pub(super) async fn finalize_success(
    state: &AppState,
    ctx: &EmitCtx,
    pool: &dyn EnginePool,
    mut result: DataResult,
) -> axum::response::Response {
    emit_audit_and_metering(state, ctx, &result);
    fan_out_mutation(state, ctx, pool, &result).await;
    if let Err(resp) = apply_abac_mask(state, ctx, &mut result) {
        return resp;
    }
    // `fields` projection: engine-neutral, post-mask, response-only.
    data_plane_core::DataOperation::project_rows(&ctx.projection, &mut result.rows);
    (StatusCode::OK, Json(result)).into_response()
}

/// Phase 6 audit trail + Track-B metering (B1a). MUTATIONs are audited (reads are
/// not, by volume; denials are audited at their rejection sites); reads are
/// optionally audited under `DATA_PLANE_AUDIT_READS`. Metering arms are OFF by
/// default and short-circuit on the flag BEFORE any field access (byte-parity).
fn emit_audit_and_metering(state: &AppState, ctx: &EmitCtx, result: &DataResult) {
    if ctx.is_mutation {
        tracing::info!(
            target: "audit",
            event = "mutation",
            tenant = %ctx.audit_tenant,
            engine = %ctx.audit_engine,
            op = ?ctx.audit_op,
            resource = %ctx.audit_resource,
            affected_rows = result.affected_rows,
            "data mutation committed"
        );
    }
    if state.config.metering && ctx.is_mutation {
        state
            .usage
            .record(&ctx.audit_tenant, "write.rows", result.affected_rows);
    }
    if !ctx.is_mutation && state.config.audit_reads {
        tracing::info!(
            target: "audit",
            event = "read",
            tenant = %ctx.audit_tenant,
            engine = %ctx.audit_engine,
            op = ?ctx.audit_op,
            resource = %ctx.audit_resource,
            returned_rows = result.rows.len(),
            "data read served"
        );
    }
    if state.config.metering && !ctx.is_mutation {
        state.usage.record(&ctx.audit_tenant, "query.count", 1);
        state
            .usage
            .record(&ctx.audit_tenant, "query.rows", result.rows.len() as u64);
    }
}

/// Bypass-path row-change fan-out (outbox enqueue + set_property automations +
/// nano SSE). All best-effort, never failing the committed write, and gated to
/// the bypass (`emit_outbox`) so the internal `/v1/query` (where the query-router
/// fires them) never doubles. On the default build this body is empty.
async fn fan_out_mutation(
    state: &AppState,
    ctx: &EmitCtx,
    pool: &dyn EnginePool,
    result: &DataResult,
) {
    let _ = (state, ctx, pool, result); // all consumers are feature-gated below
    // Phase 7d: on the bypass write path, emit the row-change event the query-
    // router would have. No-op for reads, the internal path (emit_outbox=false),
    // and when the outbox DSN is unset.
    #[cfg(feature = "control-pg")]
    if ctx.emit_outbox && ctx.is_mutation {
        if let Some(ob) = state.outbox.as_ref() {
            // D-write-tail: non-blocking enqueue — the INSERT runs on the
            // background worker, OFF this request's latency path.
            ob.enqueue(
                &ctx.audit_engine,
                &ctx.outbox_identity,
                ctx.audit_op.clone(),
                &ctx.audit_resource,
                ctx.outbox_data.as_ref(),
                ctx.outbox_filter.as_ref(),
                result,
                ctx.outbox_idem.as_deref(),
            );
        }
    }
    #[cfg(feature = "control-pg")]
    if ctx.emit_outbox && ctx.is_mutation {
        if let Some(au) = state.automations.as_ref() {
            let row = result.rows.first().cloned().unwrap_or_else(|| {
                let mut m = serde_json::Map::new();
                if let Some(serde_json::Value::Object(d)) = ctx.outbox_data.as_ref() {
                    for (k, v) in d {
                        m.insert(k.clone(), v.clone());
                    }
                }
                if let Some(serde_json::Value::Object(f)) = ctx.outbox_filter.as_ref() {
                    for (k, v) in f {
                        m.insert(k.clone(), v.clone());
                    }
                }
                serde_json::Value::Object(m)
            });
            let pk = row
                .get("id")
                .cloned()
                .or_else(|| ctx.outbox_data.as_ref().and_then(|d| d.get("id")).cloned())
                .or_else(|| ctx.outbox_filter.as_ref().and_then(|f| f.get("id")).cloned());
            au.run_for_write(
                pool,
                &ctx.outbox_identity,
                &ctx.automation_db_id,
                &ctx.audit_resource,
                ctx.op_wire,
                &row,
                pk.as_ref(),
            )
            .await;
        }
    }
    // Nano edition: fan the committed mutation out to the in-process SSE bus.
    #[cfg(feature = "nano")]
    if ctx.emit_outbox && ctx.is_mutation {
        if let Some(nano) = state.nano.as_ref() {
            let pk = result
                .rows
                .first()
                .and_then(|r| r.get("id"))
                .cloned()
                .or_else(|| ctx.outbox_data.as_ref().and_then(|d| d.get("id")).cloned())
                .or_else(|| ctx.outbox_filter.as_ref().and_then(|f| f.get("id")).cloned());
            nano.publish_mutation(
                &ctx.automation_db_id,
                &ctx.audit_resource,
                ctx.op_wire,
                pk.as_ref(),
                result.affected_rows,
                ctx.outbox_identity.user_id.as_deref().unwrap_or(""),
            );
        }
    }
}

/// Phase D — apply ABAC field masks in Rust (cutover prep). Flag-gated
/// (`DATA_PLANE_APPLY_MASKS`, OFF by default → byte-parity); user identities only
/// (api-key callers are scope-based → no mask, matching the query-router).
/// Applied AFTER the fan-out so the server-side event keeps the FULL row — only
/// the per-user RESPONSE is masked. `Err` ⇒ a 403 deny short-circuits.
fn apply_abac_mask(
    state: &AppState,
    ctx: &EmitCtx,
    result: &mut DataResult,
) -> Result<(), axum::response::Response> {
    if !state.config.apply_masks {
        return Ok(());
    }
    let (Some(ev), Some(user)) = (
        state.evaluator.as_ref(),
        ctx.outbox_identity
            .user_id
            .as_deref()
            .filter(|u| !u.starts_with("api-key:")),
    ) else {
        return Ok(());
    };
    let decision = ev.decide(user, &ctx.audit_engine, &ctx.audit_resource, ctx.mask_action);
    if !decision.allow {
        tracing::warn!(
            target: "audit",
            event = "abac_denied",
            tenant = %ctx.audit_tenant,
            engine = %ctx.audit_engine,
            resource = %ctx.audit_resource,
            "ABAC denied a user request (403)"
        );
        return Err(api_err(StatusCode::FORBIDDEN, "forbidden", &decision.reason));
    }
    if let Some(mask) = decision.mask {
        crate::abac::apply_field_mask(&mut result.rows, &mask);
    }
    Ok(())
}

/// Map a pool/execution error to its wire response — the `Err` arm of the
/// execute match, kept here so both arms live together.
pub(super) fn finalize_error(err: &data_plane_core::DataPlaneError) -> axum::response::Response {
    map_data_plane_error(err)
}
