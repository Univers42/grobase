//! Shared `/data/v1` bypass authentication plumbing, split out of `bypass.rs`:
//! the scope check, the cached key-verify, the verify+resolve pair, the internal
//! envelope builder, the audited scope-denial, and the explicit rate-limit the
//! non-`run_query` handlers call. `bypass.rs` re-exports the `pub(crate)` items
//! so their `bypass::X` paths (and the mod.rs facade) are unchanged.
use axum::http::{header, StatusCode};
use data_plane_core::{CredentialRef, DatabaseMount, PoolPolicy, RequestIdentity};

use crate::ratelimit::tier_rate;
use super::helpers::{api_err, auth_error_response, too_many_requests};
use super::state::AppState;

/// A scope check: `admin` satisfies anything; otherwise the exact scope is
/// required. Shared by the op gate (read/write) and the schema/ddl bypass
/// handlers (read for introspect, write for DDL).
pub(crate) fn require_scope(scopes: &[String], needed: &'static str) -> Result<(), &'static str> {
    if scopes.iter().any(|s| s == "admin" || s == needed) {
        Ok(())
    } else {
        Err(needed)
    }
}

/// Validate the `X-Baas-Api-Key` (Go performs the Argon2id compare via
/// tenant-control) → a verified caller identity, or a ready error response. The
/// key-verification half of `bypass_auth`, split out so a multi-mount handler
/// (graph) can verify ONCE and resolve per dbId.
pub(crate) async fn bypass_verify(
    state: &AppState,
    headers: &header::HeaderMap,
) -> Result<crate::auth::VerifiedIdentity, axum::response::Response> {
    // Nano edition: the key store lives IN-PROCESS (no tenant-control, no
    // service token, no network hop) — the local verify replaces the whole
    // HTTP path below.
    #[cfg(feature = "nano")]
    if let Some(nano) = state.nano.as_ref() {
        // binocle-one: a Bearer JWT is a first-class identity on the SAME
        // door — user requests get per-user owner-scoping + ABAC masks. An
        // explicit API key still wins (machine callers may send both).
        #[cfg(feature = "one")]
        if !headers.contains_key("x-baas-api-key") {
            if let (Some(one), Some(token)) =
                (state.one.as_ref(), crate::one::bearer_token(headers))
            {
                return one.verify_jwt(&token);
            }
        }
        return nano.verify_headers(headers);
    }
    let key = match headers.get("x-baas-api-key").and_then(|v| v.to_str().ok()) {
        Some(k) if !k.trim().is_empty() => k.to_string(),
        _ => {
            return Err(api_err(
                StatusCode::UNAUTHORIZED,
                "unauthorized",
                "X-Baas-Api-Key header is required",
            ))
        }
    };
    if state.config.internal_service_token.is_empty() {
        return Err(api_err(
            StatusCode::SERVICE_UNAVAILABLE,
            "bypass_misconfigured",
            "INTERNAL_SERVICE_TOKEN not set on the data plane",
        ));
    }
    // Cache hit → skip the tenant-control round-trip (+ its Argon2id). Mirrors the
    // query-router's 30 s ApiKeyMiddleware cache, so a revoked key has the same
    // (short) validity window on both front doors. The lock is never held across
    // the await below.
    let ttl = std::time::Duration::from_millis(state.config.verify_cache_ttl_ms);
    if !ttl.is_zero() {
        if let Ok(cache) = state.verify_cache.lock() {
            if let Some((at, id)) = cache.get(&key) {
                if at.elapsed() < ttl {
                    state.metrics.record_verify_cache(true);
                    return Ok(id.clone());
                }
            }
        }
    }
    state.metrics.record_verify_cache(false);
    // Go performs the Argon2id compare; Rust trusts the verified result.
    let identity = crate::auth::verify_key(
        &state.http_client,
        &state.config.tenant_control_url,
        &state.config.internal_service_token,
        &key,
    )
    .await
    .map_err(auth_error_response)?;
    if !ttl.is_zero() {
        if let Ok(mut cache) = state.verify_cache.lock() {
            // Bound the map so a key-spray can't grow it unboundedly.
            if cache.len() >= 4096 {
                cache.clear();
            }
            cache.insert(key, (std::time::Instant::now(), identity.clone()));
        }
    }
    Ok(identity)
}

/// Shared `/data/v1` authentication: verify the key + resolve the (single) mount,
/// tenant-scoped. Every single-mount bypass handler (query, schema, ddl) routes
/// through here so authentication is byte-identical.
pub(super) async fn bypass_auth(
    state: &AppState,
    headers: &header::HeaderMap,
    db_id: &str,
) -> Result<(crate::auth::VerifiedIdentity, crate::auth::ResolvedMount), axum::response::Response> {
    let id = bypass_verify(state, headers).await?;
    let mount_info = state
        .resolve_bypass_mount(&id.tenant_id, db_id)
        .await
        .map_err(auth_error_response)?;
    Ok((id, mount_info))
}

/// Build the internal (identity, mount) envelope for a verified bypass caller —
/// the SAME shape the query-router constructs. The verified principal flows
/// through verbatim: `api-key:<id>` for machine keys (byte-parity with the
/// query-router), `user:<id>` for binocle-one account holders (which is what
/// makes per-user owner-scoping + ABAC masks light up on the same path).
pub(crate) fn bypass_envelope(
    id: &crate::auth::VerifiedIdentity,
    db_id: &str,
    mount_info: crate::auth::ResolvedMount,
) -> (RequestIdentity, DatabaseMount) {
    (
        RequestIdentity {
            tenant_id: id.tenant_id.clone(),
            project_id: None,
            app_id: None,
            user_id: Some(id.principal.clone()),
            roles: vec![],
            scopes: id.scopes.clone(),
            source: id.source.clone(),
        },
        DatabaseMount {
            id: db_id.to_string(),
            tenant_id: id.tenant_id.clone(),
            project_id: None,
            engine: mount_info.engine,
            name: "bypass".to_string(),
            credential_ref: CredentialRef {
                provider: "adapter-registry".to_string(),
                reference: db_id.to_string(),
                version: "live".to_string(),
            },
            pool_policy: PoolPolicy::default(),
            capability_overrides: mount_info.capability_overrides,
            inline_dsn: Some(mount_info.connection_string),
            isolation: mount_info.isolation,
            replica_inline_dsn: None,
            read_replica_route: false,
        },
    )
}

/// Audited 403 for a bypass caller lacking a scope.
pub(crate) fn scope_denied(
    id: &crate::auth::VerifiedIdentity,
    surface: &str,
    missing: &str,
) -> axum::response::Response {
    tracing::warn!(
        target: "audit",
        event = "scope_denied",
        tenant = %id.tenant_id,
        surface = %surface,
        "api key lacks '{missing}' scope (403)"
    );
    api_err(
        StatusCode::FORBIDDEN,
        "forbidden",
        &format!("api key lacks '{missing}' scope for this operation"),
    )
}

/// Apply the per-tenant token-bucket rate limit for a bypass request using the
/// mount's tier mask. `/data/v1/query` does this inside `run_query`; the schema
/// / ddl / graph handlers must call it explicitly since they bypass `run_query`.
/// A no-op when the mount carries no tier mask (parity), so untiered tenants are
/// unaffected.
pub(crate) async fn bypass_ratelimit(
    state: &AppState,
    tenant: &str,
    overrides: Option<&serde_json::Value>,
    surface: &str,
) -> Result<(), axum::response::Response> {
    if let Some((rps, burst)) = tier_rate(overrides) {
        if !state.ratelimiter.allow(tenant, rps, burst).await {
            tracing::warn!(
                target: "audit",
                event = "rate_limited",
                tenant = %tenant,
                surface = %surface,
                rps,
                "tenant exceeded package rate limit (429)"
            );
            return Err(too_many_requests(rps));
        }
    }
    Ok(())
}
