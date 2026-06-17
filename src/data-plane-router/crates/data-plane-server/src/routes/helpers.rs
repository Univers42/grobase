//! Cross-cutting response shaping + guards shared by every handler module:
//! the central `ApiError` body, the `map_data_plane_error` mapping, the status
//! builders (bad_request / 402 / 403 / 404 / 429 / 501), the admin + identity
//! guards, and `json_result` (the execute-on-pool result→response tail).
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::Json;
use data_plane_core::{DatabaseMount, DataPlaneError, EngineCapabilities, RequestIdentity};
use serde::Serialize;

use super::state::AppState;

#[derive(Debug, Clone, Serialize)]
pub(super) struct ApiError {
    pub(super) error: String,
    pub(super) message: String,
}

#[derive(Debug, Clone, Serialize)]
pub(super) struct NotImplementedResponse {
    error: String,
    message: String,
    next_step: &'static str,
    tx_id: Option<String>,
}

/// A JSON `ApiError` response with the given status.
pub(crate) fn api_err(status: StatusCode, error: &str, message: &str) -> axum::response::Response {
    (
        status,
        Json(ApiError {
            error: error.to_string(),
            message: message.to_string(),
        }),
    )
        .into_response()
}

pub(super) fn auth_error_response(err: crate::auth::AuthError) -> axum::response::Response {
    use crate::auth::AuthError;
    let (status, code, message) = match err {
        AuthError::Unauthorized(m) => (StatusCode::UNAUTHORIZED, "unauthorized", m),
        AuthError::NotFound(m) => (StatusCode::NOT_FOUND, "mount_not_found", m),
        AuthError::Upstream(m) => (StatusCode::BAD_GATEWAY, "upstream_unavailable", m),
    };
    (
        status,
        Json(ApiError {
            error: code.to_string(),
            message,
        }),
    )
        .into_response()
}

/// Reject a request whose engine advertises a required capability as `false`
/// with a clean 422 `UnsupportedCapability` (G6: a semantic, not syntactic,
/// rejection), instead of letting it die as a deep 501 inside the adapter (e.g.
/// `begin()` on mongo, `migrate` on a `ddl:false` engine). Uses the trusted
/// server-side descriptor, never request input. A no-op when the engine isn't in
/// the descriptor table (the adapter still guards).
pub(super) fn require_capability(
    state: &AppState,
    engine: &str,
    capability: &str,
    has: impl Fn(&EngineCapabilities) -> bool,
) -> Result<(), axum::response::Response> {
    if let Some(descriptor) = state.engines.iter().find(|e| e.engine == engine) {
        if !has(&descriptor.capabilities) {
            return Err(map_data_plane_error(
                &DataPlaneError::UnsupportedCapability {
                    engine: engine.to_string(),
                    capability: capability.to_string(),
                },
            ));
        }
    }
    Ok(())
}

pub(crate) fn map_data_plane_error(err: &DataPlaneError) -> axum::response::Response {
    let (status, code) = match err {
        DataPlaneError::NotImplemented { .. } => (StatusCode::NOT_IMPLEMENTED, "not_implemented"),
        // G6: an (engine, op) the engine cannot serve is a *semantically*
        // invalid request — the body is well-formed but the capability is
        // unavailable — so 422 Unprocessable Entity, distinct from a malformed
        // request (400). Only this variant flips; InvalidRequest/Identifier
        // stay 400.
        DataPlaneError::UnsupportedCapability { .. } => {
            (StatusCode::UNPROCESSABLE_ENTITY, "unsupported_capability")
        }
        // Phase 4: the engine CAN serve the op, but the tenant's package tier
        // excludes it — an authorization decision (403), not a 422. The client
        // must upgrade the package, not fix the request.
        DataPlaneError::CapabilityGated { .. } => (StatusCode::FORBIDDEN, "capability_gated"),
        DataPlaneError::InvalidIdentifier { .. } => (StatusCode::BAD_REQUEST, "invalid_identifier"),
        DataPlaneError::InvalidRequest { .. } => (StatusCode::BAD_REQUEST, "invalid_request"),
        DataPlaneError::MountNotFound { .. } => (StatusCode::NOT_FOUND, "mount_not_found"),
        DataPlaneError::TransactionNotFound { .. } => (StatusCode::NOT_FOUND, "transaction_not_found"),
        DataPlaneError::CredentialUnavailable { .. } => {
            (StatusCode::BAD_GATEWAY, "credential_unavailable")
        }
        // A configured provider was reached but failed (transport/non-2xx/missing
        // field). Mirror CredentialUnavailable's status (502) — an upstream
        // credential source we depend on did not deliver, so it is a gateway
        // failure, not a client (422) error.
        DataPlaneError::CredentialProviderFailed { .. } => {
            (StatusCode::BAD_GATEWAY, "credential_provider_failed")
        }
        DataPlaneError::Backend { .. } => (StatusCode::BAD_GATEWAY, "backend_error"),
        DataPlaneError::Conflict { .. } => (StatusCode::CONFLICT, "conflict"),
    };
    (
        status,
        Json(ApiError {
            error: code.to_string(),
            message: err.to_string(),
        }),
    )
        .into_response()
}

/// Shape a data-plane result into the wire response every execute-on-pool
/// handler returns: `200 OK` + the JSON payload on success, the central
/// `map_data_plane_error` mapping on failure. Collapses the identical
/// `match { Ok => (OK, Json).into_response(), Err => map_data_plane_error }`

pub(super) fn json_result<T: Serialize>(
    result: data_plane_core::DataPlaneResult<T>,
) -> axum::response::Response {
    match result {
        Ok(value) => (StatusCode::OK, Json(value)).into_response(),
        Err(err) => map_data_plane_error(&err),
    }
}

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

pub(super) async fn not_found() -> impl IntoResponse {
    (
        StatusCode::NOT_FOUND,
        Json(ApiError {
            error: "not_found".to_string(),
            message: "route is not exposed by the Rust data-plane-router".to_string(),
        }),
    )
}

pub(super) fn validate_identity_mount(
    state: &AppState,
    identity: &RequestIdentity,
    mount: &DatabaseMount,
) -> Result<(), String> {
    if !identity.is_tenant_scoped() {
        return Err("identity.tenant_id is required".to_string());
    }
    if identity.tenant_id != mount.tenant_id {
        return Err("identity tenant does not match mount tenant".to_string());
    }
    if !state.engines.iter().any(|engine| engine.engine == mount.engine) {
        return Err(format!("engine '{}' is not mounted in the Rust router", mount.engine));
    }
    Ok(())
}

pub(super) fn bad_request(message: String) -> axum::response::Response {
    (
        StatusCode::BAD_REQUEST,
        Json(ApiError {
            error: "invalid_request".to_string(),
            message,
        }),
    )
        .into_response()
}

/// The 404 returned by every transaction handler (execute/commit/rollback) when
/// the `tx_id` names no open transaction — shaped once so the three sites stay
/// byte-identical.
pub(super) fn transaction_not_found(tx_id: &str) -> axum::response::Response {
    api_err(
        StatusCode::NOT_FOUND,
        "transaction_not_found",
        &format!("no open transaction with id {tx_id}"),
    )
}

pub(super) fn not_implemented(error: &str, message: &str) -> axum::response::Response {
    (
        StatusCode::NOT_IMPLEMENTED,
        Json(NotImplementedResponse {
            error: error.to_string(),
            message: message.to_string(),
            next_step: "implement PoolRegistry, Postgres/Mongo pools, local PDP, then enable shadow routing",
            tx_id: None,
        }),
    )
        .into_response()
}

/// 429 for a tenant that exceeded its package tier's request rate (Phase 4).

/// Carries a `Retry-After: 1` hint (the bucket refills within a second at any
/// non-trivial rps).
pub(super) fn too_many_requests(rps: u32) -> axum::response::Response {
    (
        StatusCode::TOO_MANY_REQUESTS,
        [(header::RETRY_AFTER, "1")],
        Json(ApiError {
            error: "rate_limited".to_string(),
            message: format!("tenant exceeded package rate limit of {rps} req/s"),
        }),
    )
        .into_response()
}

/// Track-B quota enforcement (B2): the 402 a tenant over its tier's cumulative
/// per-period usage quota receives. 402 Payment Required is the canonical "you've
/// hit your plan's metered allowance — upgrade or wait for the period to roll"
/// signal, DISTINCT from the 429 rate cap (slow down) and the 403 capability gate

/// (upgrade your tier for this feature).
pub(super) fn payment_required() -> axum::response::Response {
    (
        StatusCode::PAYMENT_REQUIRED,
        Json(ApiError {
            error: "quota_exceeded".to_string(),
            message: "tenant exceeded package usage quota for the current period".to_string(),
        }),
    )
        .into_response()
}

/// Track-B spend-cap enforcement: the 402 a tenant over its ABSOLUTE spend cap
/// receives. Same 402 status as `payment_required` (both are "metered allowance"
/// signals) but a DISTINCT `spend_capped` error code, so a client can tell a

/// usage-quota exhaustion from a money-cap trip.
pub(super) fn spend_capped() -> axum::response::Response {
    (
        StatusCode::PAYMENT_REQUIRED,
        Json(ApiError {
            error: "spend_capped".to_string(),
            message: "tenant exceeded its spend cap".to_string(),
        }),
    )
        .into_response()
}

/// Track-B abuse/KYC suspension: the 403 a suspended tenant receives. 403
/// Forbidden (account administratively blocked), DISTINCT from the 402 spend/quota
/// signals (which say "pay or upgrade") — a suspended account cannot un-block by

/// paying.
pub(super) fn forbidden_suspended() -> axum::response::Response {
    (
        StatusCode::FORBIDDEN,
        Json(ApiError {
            error: "tenant_suspended".to_string(),
            message: "tenant is suspended".to_string(),
        }),
    )
        .into_response()
}

fn is_admin(identity: &RequestIdentity) -> bool {
    identity.roles.iter().any(|r| r == "service_role" || r == "admin")
        || identity.scopes.iter().any(|s| s == "admin")
}

/// Admin gate shared by every `/v1/admin/*` handler: a non-admin identity gets
/// the SAME 403 `forbidden` body, differing only by the `route` named in the
/// message (`/v1/admin/raw requires role=service_role or scope=admin`). Returns
/// a ready response on denial so the handler just `?`-style early-returns it.
pub(super) fn require_admin(identity: &RequestIdentity, route: &str) -> Result<(), axum::response::Response> {
    if is_admin(identity) {
        return Ok(());
    }
    Err(api_err(
        StatusCode::FORBIDDEN,
        "forbidden",
        &format!("{route} requires role=service_role or scope=admin"),
    ))
}
