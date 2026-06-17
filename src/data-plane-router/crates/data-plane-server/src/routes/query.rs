//! The query hot path: the internal `/v1/query` handler and the shared
//! `run_query` / `run_query_inner` core that both doors (internal + bypass)
//! funnel through — owner-scoping, tier rate-limit, metering, planner, dispatch.
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use data_plane_core::{
    DataOperation, DataOperationKind, RequestIdentity, DatabaseMount, PoolRegistry, WorkloadContext,
    Plan,
};
use serde::Deserialize;

use crate::ratelimit::{tier_max_rows, tier_rate};
use super::state::AppState;
use super::helpers::{
    api_err, bad_request, forbidden_suspended, map_data_plane_error, not_implemented,
    payment_required, spend_capped, too_many_requests, validate_identity_mount,
};

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
    // B5 per-tenant observability (Pillar 3, OPTIONAL) — record ONE request for
    // this tenant into the BOUNDED per-tenant counter. AND-gated: only when BOTH
    // the parent log-field flag AND the counter sub-flag are ON (`tenant_obs_counter`
    // is already AND(tenant_obs, DATA_PLANE_TENANT_OBS_COUNTER) from config). The
    // flag short-circuits BEFORE any work, so at parity this branch is a single
    // `bool` test that takes nothing — `/metrics` stays byte-identical. The
    // counter is hard-capped at N+1 series inside `record_tenant_request`, so it
    // can never explode at 10K+ tenants. Recorded at handler entry (off the global
    // status buckets) so it covers a read AND a write on both doors.
    if state.config.tenant_obs_counter {
        state
            .metrics
            .record_tenant_request(&request.identity.tenant_id);
    }
    // B5 per-tenant observability (Pillar 1) — emit ONE per-request log event
    // carrying tenant_id as a STRUCTURED FIELD, gated by config.tenant_obs
    // (DATA_PLANE_TENANT_OBS, default OFF). The `.instrument(span)` wrapper alone
    // is NOT enough: a span only surfaces its fields when an event fires *inside*
    // it, and the success path's usage signal drains in a background task (outside
    // this span), so without an explicit event no request log line would carry the
    // tenant. This event is the field promtail extracts (`| json | tenant_id="X"`).
    // When the flag is OFF this branch is skipped entirely → zero new log lines =
    // byte-parity with the pre-B5 baseline (kernel rule #5). tenant_id is a FIELD
    // only — never a Loki label or a Prometheus label — so it adds no cardinality.
    if state.config.tenant_obs {
        tracing::info!(tenant_id = %request.identity.tenant_id, "data-plane request");
    }
    if let Err(message) = validate_identity_mount(&state, &request.identity, &request.mount) {
        return bad_request(message);
    }
    if request.operation.resource.trim().is_empty() {
        return bad_request("operation.resource is required".to_string());
    }

    // Engines with a live Rust pool IN THIS BUILD (feature-gated; the default
    // build lists all nine, a nano build only sqlite). MariaDB rides the MySQL
    // adapter. Engines beyond this list (jdbc, cassandra, neo4j, es, qdrant,
    // influx) stay contract-only and are rejected here.
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
        return not_implemented(
            "engine_execution_not_enabled",
            &format!(
                "engine has no Rust pool in this build; supported engines: {}",
                executable_engines.join(", ")
            ),
        );
    }

    // Phase 4 tiering — per-tenant rate limit (token bucket). The mount's tier
    // mask carries rps/burst; an untiered mount (no mask) is unlimited, so this
    // is a no-op until a package is assigned. Keyed on the TRUSTED envelope
    // tenant, so it survives the Phase-7 TS bypass; Kong's per-IP limit is the
    // coarse outer shell.
    if let Some((rps, burst)) = tier_rate(request.mount.capability_overrides.as_ref()) {
        if !state.ratelimiter.allow(&request.identity.tenant_id, rps, burst).await {
            tracing::warn!(
                target: "audit",
                event = "rate_limited",
                tenant = %request.identity.tenant_id,
                engine = %request.mount.engine,
                op = ?request.operation.op,
                rps,
                "tenant exceeded package rate limit (429)"
            );
            return too_many_requests(rps);
        }
    }

    // Track-B quota enforcement (B2) — CUMULATIVE per-period usage quota. The
    // control-plane QuotaGuard (which CONSUMES B1's tenant_usage, never re-meters)
    // publishes the over-quota tenant set to Redis; the data plane keeps a cheap
    // in-memory snapshot (refreshed off the request path) and rejects an over-quota
    // tenant with 402 here. Distinct from the 429 rate cap above (per-request) and
    // the max_rows clamp below (per-query): this is the period-cumulative budget.
    // OFF by default (`config.quota_enforcement`) → the snapshot is empty, this
    // branch's flag short-circuits before any lookup, so it is byte-parity.
    if state.config.quota_enforcement
        && state.quota_over.is_over(&request.identity.tenant_id)
    {
        tracing::warn!(
            target: "audit",
            event = "quota_exceeded",
            tenant = %request.identity.tenant_id,
            engine = %request.mount.engine,
            op = ?request.operation.op,
            "tenant exceeded package usage quota (402)"
        );
        return payment_required();
    }

    // Track-B spend-cap enforcement — ABSOLUTE per-tenant spend budget. The
    // control-plane spend-cap guard publishes the over-spend tenant set to Redis
    // (`spend:over`); the data plane keeps a cheap in-memory snapshot (refreshed
    // off the request path, mirroring quota) and rejects an over-spend tenant with
    // 402 (`spend_capped`) here. DISTINCT signal from the quota 402 above (usage
    // quota vs. money cap). OFF by default (`config.spend_caps`) → the snapshot is
    // empty and this branch's flag short-circuits BEFORE any lookup, so it is
    // byte-parity (the check is unreachable with the flag off).
    if state.config.spend_caps && state.spend_over.is_over(&request.identity.tenant_id) {
        tracing::warn!(
            target: "audit",
            event = "spend_capped",
            tenant = %request.identity.tenant_id,
            engine = %request.mount.engine,
            op = ?request.operation.op,
            "tenant exceeded spend cap (402)"
        );
        return spend_capped();
    }

    // Track-B abuse/KYC suspension — administrative block. The control-plane abuse
    // guard publishes the suspended tenant set to Redis (`tenant:suspended`); the
    // data plane keeps a cheap in-memory snapshot (refreshed off the request path,
    // mirroring quota) and rejects a suspended tenant with 403 (`tenant_suspended`)
    // here — a 403 (account blocked), NOT a 402 (which says "pay/upgrade"). OFF by
    // default (`config.suspend_reader`) → the snapshot is empty and this branch's
    // flag short-circuits BEFORE any lookup, so it is byte-parity (the check is
    // unreachable with the flag off).
    if state.config.suspend_reader && state.suspended.is_over(&request.identity.tenant_id) {
        tracing::warn!(
            target: "audit",
            event = "tenant_suspended",
            tenant = %request.identity.tenant_id,
            engine = %request.mount.engine,
            op = ?request.operation.op,
            "suspended tenant request rejected (403)"
        );
        return forbidden_suspended();
    }

    // Capability-aware planner (G6, two-phase). Phase 1 rejects an impossible
    // (engine, op) pair (supports_op + batch ceiling); Phase 2 routes by op
    // shape over the const cost table. No-op for the engines mounted today —
    // plain CRUD has an empty shape, so every current request stays Native
    // (parity-safe). `/v1/query` is never inside a tx or streaming, so the
    // workload context is plain; the tx route guards transactions separately.
    if let Some(descriptor) = state
        .engines
        .iter()
        .find(|e| e.engine == request.mount.engine)
    {
        // Phase 4 tiering — capability gate. The descriptor says what the ENGINE
        // can do; the tenant's package mask (mount.capability_overrides) may
        // narrow it. A masked-off-but-engine-supported op is a 403 (upgrade your
        // package), DISTINCT from the planner's 422 for an op the engine can't
        // serve at all. No-op when there's no mask (parity).
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
            return map_data_plane_error(&err);
        }
        let decision = data_plane_core::plan(
            &request.operation,
            &request.mount.engine,
            &descriptor.capabilities,
            &WorkloadContext::default(),
            state.config.planner_federation_enabled,
        );
        match decision.plan {
            Plan::Native => {} // fall through to pool execution (unchanged)
            Plan::Reject(err) => {
                tracing::info!(reason = decision.reason, engine = %request.mount.engine, "planner rejected operation");
                return map_data_plane_error(&err);
            }
            Plan::Federate { target } => {
                // The federation seam (resolve_federation) lowers Federate to a
                // Reject while the flag is off, so this arm is reachable only
                // once federation is wired. Until then it is a clean 501.
                tracing::info!(reason = decision.reason, target, "planner selected federation target (not yet executable)");
                return map_data_plane_error(&data_plane_core::DataPlaneError::NotImplemented {
                    feature: format!("federation to {target}"),
                });
            }
        }
    }

    // FTS / vector search are Postgres-native ops (to_tsvector + ts_rank / pgvector
    // distance operators). Any other engine rejects with a clean 422 rather than
    // silently ignoring the clause and returning unfiltered rows — engine-agnostic
    // by construction (capability honestly declared, only Postgres serves it).
    if (request.operation.search.is_some() || request.operation.vector.is_some())
        && request.mount.engine != "postgresql"
    {
        return map_data_plane_error(&data_plane_core::DataPlaneError::UnsupportedCapability {
            engine: request.mount.engine.clone(),
            capability: if request.operation.search.is_some() {
                "fulltext_search".to_string()
            } else {
                "vector_search".to_string()
            },
        });
    }

    // Capture audit + outbox fields before the request is consumed by the pool.
    let audit_tenant = request.identity.tenant_id.clone();
    let audit_engine = request.mount.engine.clone();
    #[cfg(any(feature = "control-pg", feature = "nano"))]
    let automation_db_id = request.mount.id.clone();
    let audit_op = request.operation.op.clone();
    let audit_resource = request.operation.resource.clone();
    let mask_action = mask_action_for(&audit_op);
    #[cfg(any(feature = "control-pg", feature = "nano"))]
    let op_wire = audit_op.wire_name();
    // Consumed only by the control-pg / nano post-write hooks below.
    #[cfg(not(any(feature = "control-pg", feature = "nano")))]
    let _ = emit_outbox;
    let is_mutation = matches!(
        audit_op,
        DataOperationKind::Insert
            | DataOperationKind::Update
            | DataOperationKind::Delete
            | DataOperationKind::Upsert
            | DataOperationKind::Batch
    );
    let outbox_identity = request.identity.clone();
    // Response projection (`fields`) — applied LAST, after outbox/realtime
    // emission and masks, so server-side consumers keep full rows.
    let projection = request.operation.fields.clone();
    #[cfg(any(feature = "control-pg", feature = "nano"))]
    let outbox_data = request.operation.data.clone();
    #[cfg(any(feature = "control-pg", feature = "nano"))]
    let outbox_filter = request.operation.filter.clone();
    #[cfg(feature = "control-pg")]
    let outbox_idem = request.operation.idempotency_key.clone();

    // G-QoS sliceA (A6): clamp the rows returned per query to the tier cap. The
    // cap comes from the mount's tier mask (`max_rows`); absent/zero → no clamp
    // (today's behavior, parity). Engine-agnostic — every adapter honors
    // `operation.limit` — so a present cap bounds a missing/larger client limit
    // without touching any adapter. A client limit already at/under the cap is
    // left as-is. Applied just before execution so it covers the bypass path too.
    if let Some(cap) = tier_max_rows(request.mount.capability_overrides.as_ref()) {
        request.operation.limit =
            Some(request.operation.limit.map_or(cap, |l| l.min(cap)));
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
        && !is_mutation
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
        Err(err) => return map_data_plane_error(&err),
    };
    match pool.execute(request.operation, request.identity).await {
        Ok(mut result) => {
            // Phase 6 audit trail: every successful data MUTATION is logged to
            // the `audit` tracing target (routed to Loki by promtail). Reads are
            // not audited (volume); denials are audited at their rejection sites.
            if is_mutation {
                tracing::info!(
                    target: "audit",
                    event = "mutation",
                    tenant = %audit_tenant,
                    engine = %audit_engine,
                    op = ?audit_op,
                    resource = %audit_resource,
                    affected_rows = result.affected_rows,
                    "data mutation committed"
                );
            }
            // Track-B metering (B1a) — mutation arm. OFF by default
            // (`config.metering` requires METERING_ENABLED AND DATA_PLANE_METERING)
            // → byte-parity: the flag short-circuits BEFORE any extra field access,
            // so the write hot path is untouched at parity. When ON, record the
            // work done (`write.rows` = affected_rows) into the in-memory aggregate
            // (cheap, non-blocking); the background flusher emits the `usage`
            // event. Engine-agnostic — reuses the already-bound `audit_tenant` /
            // `result.affected_rows`, no adapter code.
            if state.config.metering && is_mutation {
                state
                    .usage
                    .record(&audit_tenant, "write.rows", result.affected_rows);
            }
            // G-ReadAudit (A6): optionally audit successful READS too. OFF by
            // default (volume); when `DATA_PLANE_AUDIT_READS` is on, emit a
            // sibling `read` event. The flag short-circuits BEFORE any field
            // access, so the read hot path is untouched at parity (today's
            // behavior — no read audit).
            if !is_mutation && state.config.audit_reads {
                tracing::info!(
                    target: "audit",
                    event = "read",
                    tenant = %audit_tenant,
                    engine = %audit_engine,
                    op = ?audit_op,
                    resource = %audit_resource,
                    returned_rows = result.rows.len(),
                    "data read served"
                );
            }
            // Track-B metering (B1a) — read arm. Sibling to the read-audit emit:
            // OFF by default (`config.metering`) → byte-parity, the flag short-
            // circuits BEFORE `result.rows.len()` is touched, so the read hot path
            // is untouched at parity. When ON, record one query (`query.count`)
            // plus the rows returned (`query.rows` = pre-projection row count,
            // the honest read-cost signal) into the in-memory aggregate. Cheap,
            // non-blocking; the background flusher emits the `usage` events.
            if state.config.metering && !is_mutation {
                state.usage.record(&audit_tenant, "query.count", 1);
                state
                    .usage
                    .record(&audit_tenant, "query.rows", result.rows.len() as u64);
            }
            // Phase 7d: on the bypass write path, emit the row-change event the
            // query-router would have — best-effort, never fails the (committed)
            // write. No-op for reads, for the internal path (emit_outbox=false),
            // and when the outbox DSN is unset.
            #[cfg(feature = "control-pg")]
            if emit_outbox && is_mutation {
                if let Some(ob) = state.outbox.as_ref() {
                    // D-write-tail: non-blocking enqueue — the INSERT runs on the
                    // background worker, OFF this request's latency path. The
                    // write already committed; a dropped event (full queue) is
                    // counted, never an error to the (already-served) caller.
                    ob.enqueue(
                        &audit_engine,
                        &outbox_identity,
                        audit_op,
                        &audit_resource,
                        outbox_data.as_ref(),
                        outbox_filter.as_ref(),
                        &result,
                        outbox_idem.as_deref(),
                    );
                }
            }
            // Phase D — fire set_property automations on the bypass write path
            // (best-effort; never fails the committed write). Gated to the bypass
            // so /query/v1 (where the query-router fires them inline) never doubles.
            #[cfg(feature = "control-pg")]
            if emit_outbox && is_mutation {
                if let Some(au) = state.automations.as_ref() {
                    let row = result.rows.first().cloned().unwrap_or_else(|| {
                        let mut m = serde_json::Map::new();
                        if let Some(serde_json::Value::Object(d)) = outbox_data.as_ref() {
                            for (k, v) in d {
                                m.insert(k.clone(), v.clone());
                            }
                        }
                        if let Some(serde_json::Value::Object(f)) = outbox_filter.as_ref() {
                            for (k, v) in f {
                                m.insert(k.clone(), v.clone());
                            }
                        }
                        serde_json::Value::Object(m)
                    });
                    let pk = row
                        .get("id")
                        .cloned()
                        .or_else(|| outbox_data.as_ref().and_then(|d| d.get("id")).cloned())
                        .or_else(|| outbox_filter.as_ref().and_then(|f| f.get("id")).cloned());
                    au.run_for_write(
                        &*pool,
                        &outbox_identity,
                        &automation_db_id,
                        &audit_resource,
                        op_wire,
                        &row,
                        pk.as_ref(),
                    )
                    .await;
                }
            }
            // Nano edition: fan the committed mutation out to the in-process SSE
            // bus (the single-binary equivalent of the outbox → realtime path).
            // Best-effort; lagging subscribers drop events, never the write.
            #[cfg(feature = "nano")]
            if emit_outbox && is_mutation {
                if let Some(nano) = state.nano.as_ref() {
                    let pk = result
                        .rows
                        .first()
                        .and_then(|r| r.get("id"))
                        .cloned()
                        .or_else(|| outbox_data.as_ref().and_then(|d| d.get("id")).cloned())
                        .or_else(|| outbox_filter.as_ref().and_then(|f| f.get("id")).cloned());
                    nano.publish_mutation(
                        &automation_db_id,
                        &audit_resource,
                        op_wire,
                        pk.as_ref(),
                        result.affected_rows,
                        outbox_identity.user_id.as_deref().unwrap_or(""),
                    );
                }
            }
            // Phase D — apply ABAC field masks in Rust (cutover prep). Flag-gated;
            // user identities only (api-key callers are scope-based → no mask,
            // matching the query-router). Applied AFTER the outbox emit so the
            // server-side event keeps the FULL row — only the per-user RESPONSE
            // is masked. OFF by default (`DATA_PLANE_APPLY_MASKS`) → byte-parity.
            if state.config.apply_masks {
                if let (Some(ev), Some(user)) = (
                    state.evaluator.as_ref(),
                    outbox_identity
                        .user_id
                        .as_deref()
                        .filter(|u| !u.starts_with("api-key:")),
                ) {
                    let decision = ev.decide(user, &audit_engine, &audit_resource, mask_action);
                    if !decision.allow {
                        tracing::warn!(
                            target: "audit",
                            event = "abac_denied",
                            tenant = %audit_tenant,
                            engine = %audit_engine,
                            resource = %audit_resource,
                            "ABAC denied a user request (403)"
                        );
                        return api_err(StatusCode::FORBIDDEN, "forbidden", &decision.reason);
                    }
                    if let Some(mask) = decision.mask {
                        crate::abac::apply_field_mask(&mut result.rows, &mask);
                    }
                }
            }
            // `fields` projection: engine-neutral, post-mask, response-only.
            data_plane_core::DataOperation::project_rows(&projection, &mut result.rows);
            (StatusCode::OK, Json(result)).into_response()
        }
        Err(err) => map_data_plane_error(&err),
    }
}
