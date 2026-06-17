//! Engine-agnostic schema introspection (`/v1/schema`) + DDL (`/v1/schema/ddl`):
//! the envelope handlers and the shared `run_*` cores the bypass twins reuse.
use axum::extract::State;
use axum::Json;
use data_plane_core::{DatabaseMount, PoolRegistry, RequestIdentity, SchemaDdlRequest};
use serde::Deserialize;

use super::state::AppState;
use super::helpers::{bad_request, json_result, map_data_plane_error, require_capability, validate_identity_mount};

// ── /v1/schema ───────────────────────────────────────────────────────────────
//
// Engine-agnostic schema introspection (M22, live-database mode). Returns the
// mount's tables/collections with normalized column types, PK/FK metadata and
// enum values (`SchemaDescriptor` in data-plane-core). NOT admin-gated: any
// authenticated identity that passes `validate_identity_mount` may read its
// OWN mount's schema (same gating as `begin_transaction` — identity/mount
// validation + a capability gate, nothing more). Engines without an
// introspection surface (redis, http) advertise `introspect: false` and are
// rejected here with a clean 422 instead of a deep 501.

#[derive(Debug, Clone, Deserialize)]
pub(super) struct DescribeSchemaRequest {
    identity: RequestIdentity,
    mount: DatabaseMount,
}

pub(super) async fn describe_schema(
    State(state): State<AppState>,
    Json(request): Json<DescribeSchemaRequest>,
) -> axum::response::Response {
    run_describe_schema(state, request.identity, request.mount).await
}

/// Shared schema-introspection core (the envelope `/v1/schema` path and the
/// api-key `/data/v1/schema` bypass both call this).
pub(super) async fn run_describe_schema(
    state: AppState,
    identity: RequestIdentity,
    mount: DatabaseMount,
) -> axum::response::Response {
    if let Err(message) = validate_identity_mount(&state, &identity, &mount) {
        return bad_request(message);
    }
    // Honesty gate: only engines advertising `introspect` serve the schema
    // surface (a route capability like `ddl`, not an operation kind).
    if let Err(resp) = require_capability(&state, &mount.engine, "introspect", |c| c.introspect) {
        return resp;
    }
    let pool = match state.registry.get_or_create(mount).await {
        Ok(pool) => pool,
        Err(err) => return map_data_plane_error(&err),
    };
    json_result(pool.describe_schema(identity).await)
}

// ── /v1/schema/ddl ────────────────────────────────────────────────────────────
//
// Engine-agnostic schema DDL (M22, step 2): ONE operation per request
// (add_column | drop_column | alter_column_type | create_table | drop_table)
// — single-op by contract because MySQL DDL self-commits, so a batch would
// fake atomicity. NOT admin-gated (mirrors /v1/schema): mount ownership is
// enforced upstream by the query-router's resolveConnection, the same trust
// model as /v1/query writes. Gated on the `schema_ddl` capability flag —
// deliberately distinct from `ddl` (the /v1/admin/migrate gate), because
// mongodb serves this surface but not migrations.

#[derive(Debug, Clone, Deserialize)]
pub(super) struct SchemaDdlEnvelope {
    identity: RequestIdentity,
    mount: DatabaseMount,
    ddl: SchemaDdlRequest,
}

pub(super) async fn apply_schema_ddl(
    State(state): State<AppState>,
    Json(request): Json<SchemaDdlEnvelope>,
) -> axum::response::Response {
    run_apply_schema_ddl(state, request.identity, request.mount, request.ddl).await
}

/// Shared schema-DDL core (the envelope `/v1/schema/ddl` path and the api-key
/// `/data/v1/schema/ddl` bypass both call this).
pub(super) async fn run_apply_schema_ddl(
    state: AppState,
    identity: RequestIdentity,
    mount: DatabaseMount,
    ddl: SchemaDdlRequest,
) -> axum::response::Response {
    if let Err(message) = validate_identity_mount(&state, &identity, &mount) {
        return bad_request(message);
    }
    if ddl.table.trim().is_empty() {
        return bad_request("ddl.table is required".to_string());
    }
    // Honesty gate: only engines advertising `schema_ddl` serve this surface.
    if let Err(resp) = require_capability(&state, &mount.engine, "schema_ddl", |c| c.schema_ddl) {
        return resp;
    }
    let pool = match state.registry.get_or_create(mount).await {
        Ok(pool) => pool,
        Err(err) => return map_data_plane_error(&err),
    };
    json_result(pool.apply_schema_ddl(ddl, identity).await)
}
