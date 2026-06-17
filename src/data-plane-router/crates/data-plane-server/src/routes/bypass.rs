//! The Phase-7 `/data/v1` bypass front door: Rust-native API-key auth (verify +
//! resolve mount + scope gate) feeding the SAME cores as the internal routes, so
//! a Node-free tier serves api-key callers with identical authorization.
use axum::extract::State;
use axum::http::header;
use axum::Json;
use data_plane_core::{DataOperation, SchemaDdlRequest};
use serde::Deserialize;

use super::state::AppState;
use super::query::{run_query, QueryRequest};
use super::schema::{run_apply_schema_ddl, run_describe_schema};
// Auth/scope/envelope plumbing now lives in `bypass_auth`; re-export the
// `pub(crate)` items so their `bypass::X` paths (and the mod.rs facade) hold.
use super::bypass_auth::bypass_auth;
pub(crate) use super::bypass_auth::{
    bypass_envelope, bypass_ratelimit, bypass_verify, require_scope, scope_denied,
};

/// Phase 7 bypass front door (`POST /data/v1/query`). Kong routes a client's
/// `X-Baas-Api-Key` here directly; Rust authenticates it itself (Go stays the
/// identity authority via tenant-control), resolves the mount, then runs the
/// SAME `run_query` as the internal `/v1/query` — so enforcement (tier gate,
/// rate limit, owner scoping) is identical on both paths. Only mounted when
/// `DATA_PLANE_BYPASS_ENABLED=1`; otherwise this code is never reachable.
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct DataQueryRequest {
    #[serde(alias = "databaseId", alias = "dbId")]
    db_id: String,
    operation: DataOperation,
}

/// Phase C — API-key scope gate for the `/data/v1` bypass (ports the
/// query-router's `decideByApiKeyScope`): `admin` ⇒ any op; `read` ⇒
/// list/get/aggregate; `write` ⇒ insert/update/delete/upsert/batch. Returns the
/// missing scope name on denial. This is what lets a Node-free basic tier serve
/// api-key callers with the same authorization the query-router enforced.
fn api_key_scope_gate(
    scopes: &[String],
    op: &data_plane_core::DataOperationKind,
) -> Result<(), &'static str> {
    use data_plane_core::DataOperationKind::*;
    let needed = match op {
        List | Get | Aggregate => "read",
        Insert | Update | Delete | Upsert | Batch => "write",
    };
    require_scope(scopes, needed)
}

pub(crate) async fn data_query(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Json(req): Json<DataQueryRequest>,
) -> axum::response::Response {
    let (id, mount_info) = match bypass_auth(&state, &headers, &req.db_id).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    // API-key scope gate (admin/read/write) — mirrors the query-router.
    if let Err(missing) = api_key_scope_gate(&id.scopes, &req.operation.op) {
        return scope_denied(&id, "query", missing);
    }
    let (identity, mount) = bypass_envelope(&id, &req.db_id, mount_info);
    // Identical execution path — Rust emits the outbox event here (the
    // query-router is out of the bypass path), so row-change fan-out keeps firing.
    run_query(
        state,
        QueryRequest {
            identity,
            mount,
            operation: req.operation,
        },
        true,
    )
    .await
}

// ── /data/v1/schema + /data/v1/schema/ddl (Phase D) ─────────────────────────
// The api-key-authed twins of /v1/schema[/ddl]: SAME Rust core, but Rust does
// the auth (verify_key + resolve_mount + scope gate) so a Node-free tier can
// introspect + create tables through the bypass. Introspect = read scope; DDL =
// write scope (it mutates the schema). Additive + bypass-gated (shadow); the
// engine capability gates (introspect / schema_ddl) still apply inside the core.

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct DataSchemaRequest {
    #[serde(alias = "databaseId", alias = "dbId")]
    db_id: String,
}

pub(crate) async fn data_describe_schema(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Json(req): Json<DataSchemaRequest>,
) -> axum::response::Response {
    let (id, mount_info) = match bypass_auth(&state, &headers, &req.db_id).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    if let Err(missing) = require_scope(&id.scopes, "read") {
        return scope_denied(&id, "schema", missing);
    }
    if let Err(resp) =
        bypass_ratelimit(&state, &id.tenant_id, mount_info.capability_overrides.as_ref(), "schema")
            .await
    {
        return resp;
    }
    let (identity, mount) = bypass_envelope(&id, &req.db_id, mount_info);
    run_describe_schema(state, identity, mount).await
}

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct DataSchemaDdlRequest {
    #[serde(alias = "databaseId", alias = "dbId")]
    db_id: String,
    ddl: SchemaDdlRequest,
}

pub(crate) async fn data_apply_schema_ddl(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Json(req): Json<DataSchemaDdlRequest>,
) -> axum::response::Response {
    let (id, mount_info) = match bypass_auth(&state, &headers, &req.db_id).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    // DDL mutates the schema — requires write (or admin).
    if let Err(missing) = require_scope(&id.scopes, "write") {
        return scope_denied(&id, "schema_ddl", missing);
    }
    if let Err(resp) = bypass_ratelimit(
        &state,
        &id.tenant_id,
        mount_info.capability_overrides.as_ref(),
        "schema_ddl",
    )
    .await
    {
        return resp;
    }
    let (identity, mount) = bypass_envelope(&id, &req.db_id, mount_info);
    run_apply_schema_ddl(state, identity, mount, req.ddl).await
}
