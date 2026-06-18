//! Privileged in-network surfaces (`/v1/admin/*`): raw statement, migration,
//! credential rotation, and verify-cache eviction — all `service_role`/`admin`
//! gated via `require_admin`.
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use data_plane_core::{
    DatabaseMount, MigrationRequest, PoolRegistry, RawStatement, RequestIdentity,
};
use serde::{Deserialize, Serialize};

use super::helpers::{
    bad_request, json_result, map_data_plane_error, require_admin, require_capability,
    validate_identity_mount,
};
use super::state::AppState;

// ── /v1/admin/raw ───────────────────────────────────────────────────────────
//
// Power-user endpoint: arbitrary engine-native statement (DDL, ALTER,
// indexes, raw SELECT for aggregations). The route enforces that the caller
// has the `service_role` role or the `admin` scope; engines TRUST the gate
// and execute the statement verbatim against the mount's connection.
//
// The endpoint exists so that "full DB control" stops being aspirational —
// the audit flagged it as a real product gap. Engines that don't support a
// raw surface return NotImplemented from the trait default.

#[derive(Debug, Clone, Deserialize)]
pub(super) struct AdminRawRequest {
    identity: RequestIdentity,
    mount: DatabaseMount,
    #[serde(flatten)]
    statement: RawStatement,
}

pub(super) async fn execute_raw_admin(
    State(state): State<AppState>,
    Json(request): Json<AdminRawRequest>,
) -> impl IntoResponse {
    if let Err(message) = validate_identity_mount(&state, &request.identity, &request.mount) {
        return bad_request(message);
    }
    if let Err(resp) = require_admin(&request.identity, "/v1/admin/raw") {
        return resp;
    }
    if request.statement.statement.trim().is_empty() {
        return bad_request("statement is required".to_string());
    }

    let pool = match state.registry.get_or_create(request.mount).await {
        Ok(pool) => pool,
        Err(err) => return map_data_plane_error(&err),
    };
    json_result(pool.execute_raw(request.statement, request.identity).await)
}

// ── /v1/admin/migrate ───────────────────────────────────────────────────────
//
// Apply a named migration to a tenant database as an atomic batch. The
// engine wraps every statement in a single transaction, then writes a
// marker into `_baas_migrations(name, applied_at)` so re-applying the same
// name is a no-op. Used by control-plane tools to evolve schema-per-tenant
// without bespoke per-engine wiring.
//
// Admin-gated: same `service_role` / `admin` scope rule as /v1/admin/raw.

#[derive(Debug, Clone, Deserialize)]
pub(super) struct AdminMigrateRequest {
    identity: RequestIdentity,
    mount: DatabaseMount,
    #[serde(flatten)]
    migration: MigrationRequest,
}

pub(super) async fn apply_migration_admin(
    State(state): State<AppState>,
    Json(request): Json<AdminMigrateRequest>,
) -> impl IntoResponse {
    if let Err(message) = validate_identity_mount(&state, &request.identity, &request.mount) {
        return bad_request(message);
    }
    if let Err(resp) = require_admin(&request.identity, "/v1/admin/migrate") {
        return resp;
    }
    if request.migration.name.trim().is_empty() {
        return bad_request("migration.name is required".to_string());
    }
    if request.migration.statements.is_empty() {
        return bad_request("migration.statements must not be empty".to_string());
    }
    // Honesty gate: only engines advertising `ddl` can apply migrations.
    if let Err(resp) = require_capability(&state, &request.mount.engine, "ddl", |c| c.ddl) {
        return resp;
    }

    let pool = match state.registry.get_or_create(request.mount).await {
        Ok(pool) => pool,
        Err(err) => return map_data_plane_error(&err),
    };
    json_result(
        pool.apply_migration(request.migration, request.identity)
            .await,
    )
}

// ── /v1/admin/rotate ─────────────────────────────────────────────────────────
//
// Credential-rotation trigger (gap G8 / S2). After a control-plane rotation
// bumps a mount's credential version (or re-issues its secret), this endpoint
// proactively invalidates the OLD credential's cached state so the next request
// rebuilds the pool with the freshly-resolved DSN instead of serving a stale
// one. It performs BOTH halves of a rotation — evict the resolver's DSN cache
// entry AND drain the registry pool — via `AppState::rotate`.
//
// The request carries the full `DatabaseMount` (same shape as /v1/admin/migrate)
// so the pool_key is reconstructed by the SAME `DatabaseMount::pool_key()` the
// hot path uses — no second key format to drift. Callers that already know the
// new version pass the OLD version in `credential_ref.version` to target the
// stale pool (the new version's pool keys distinctly and is left untouched).
//
// Admin-gated: identical `service_role` / `admin` rule + tenant match as
// /v1/admin/migrate (validate_identity_mount + is_admin). No secret is ever read,
// logged, or returned — only a drained-pool count.

#[derive(Debug, Clone, Deserialize)]
pub(super) struct AdminRotateRequest {
    identity: RequestIdentity,
    mount: DatabaseMount,
}

#[derive(Debug, Clone, Serialize)]
pub(super) struct AdminRotateResponse {
    pool_key: String,
    pools_drained: usize,
}

pub(super) async fn rotate_credential_admin(
    State(state): State<AppState>,
    Json(request): Json<AdminRotateRequest>,
) -> impl IntoResponse {
    if let Err(message) = validate_identity_mount(&state, &request.identity, &request.mount) {
        return bad_request(message);
    }
    if let Err(resp) = require_admin(&request.identity, "/v1/admin/rotate") {
        return resp;
    }
    // Reconstruct the pool_key with the same derivation the hot path uses (via
    // the registry's sharing policy), so the drained key is byte-identical to
    // the one `get_or_create` cached under — including B4-pools shared keys.
    let pool_key = state.registry.pool_key_for(&request.mount);
    let pools_drained = state.rotate(&pool_key).await;
    (
        StatusCode::OK,
        Json(AdminRotateResponse {
            pool_key,
            pools_drained,
        }),
    )
        .into_response()
}

// ── /v1/admin/evict-verify ────────────────────────────────────────────────────
//
// Credential-event hook (B3): the control plane calls this after revoking an
// API key so the cached VerifiedIdentity dies NOW, not after the verify-cache
// TTL (the revoked-key-valid-≤30s hole). In-network admin surface, same trust
// model as /v1/admin/raw: body-borne identity, service_role/admin gated.
// Wholesale eviction by design — entries are keyed by raw key material, so a
// per-key contract would put secrets on the wire for no win (re-verifies are
// ~ms post-fast-hash and credential events are rare).

#[derive(Debug, Clone, Deserialize)]
pub(super) struct AdminEvictVerifyRequest {
    identity: RequestIdentity,
}

#[derive(Debug, Clone, Serialize)]
pub(super) struct AdminEvictVerifyResponse {
    evicted: usize,
}

pub(super) async fn evict_verify_admin(
    State(state): State<AppState>,
    Json(request): Json<AdminEvictVerifyRequest>,
) -> impl IntoResponse {
    if let Err(resp) = require_admin(&request.identity, "/v1/admin/evict-verify") {
        return resp;
    }
    let evicted = state.evict_verify_cache();
    (StatusCode::OK, Json(AdminEvictVerifyResponse { evicted })).into_response()
}
