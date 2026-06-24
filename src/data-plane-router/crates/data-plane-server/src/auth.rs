/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   auth.rs                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:32:52 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:32:53 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Phase 7 — Rust-native authentication for the direct `/data/v1` front door.
//!
//! Go remains the SOLE identity authority: Rust never hashes or stores API keys.
//! It only CALLS tenant-control `POST /v1/keys/verify` (Argon2id verification
//! stays in Go) to turn an `X-Baas-Api-Key` into a tenant identity, and
//! adapter-registry `GET /databases/{id}/connect` to resolve the mount's DSN +
//! tier mask. Both use the internal service token.
//!
//! This module is only reachable when the bypass is explicitly enabled
//! (`DATA_PLANE_BYPASS_ENABLED=1`); the existing `/query/v1` → query-router path
//! is untouched, so the front door ships as pure SHADOW.

use serde::Deserialize;

/// Why a bypass request was rejected, mapped to an HTTP status by the route.
#[derive(Debug)]
pub enum AuthError {
    /// Key missing / invalid / expired — 401.
    Unauthorized(String),
    /// An upstream (tenant-control / adapter-registry) failed — 502.
    Upstream(String),
    /// The mount id is unknown for this tenant — 404.
    NotFound(String),
}

#[derive(Debug, Deserialize)]
struct VerifyResponse {
    valid: bool,
    #[serde(default)]
    tenant_id: Option<String>,
    #[serde(default)]
    key_id: Option<String>,
    #[serde(default)]
    scopes: Vec<String>,
    #[serde(default)]
    reason: Option<String>,
}

/// A verified caller identity (the trusted output of tenant-control — or, in
/// the nano/one editions, of the in-process key store / JWT verifier).
#[derive(Clone)]
pub struct VerifiedIdentity {
    pub tenant_id: String,
    pub key_id: String,
    pub scopes: Vec<String>,
    /// The EXACT principal stamped as `user_id` on the request envelope (and
    /// therefore as the row owner): `api-key:<key id>` for machine keys,
    /// `user:<user id>` for binocle-one account holders. Keeping it here (not
    /// re-derived at envelope time) is what lets user JWTs flow through the
    /// same bypass with per-user owner-scoping + ABAC masks.
    pub principal: String,
    /// Envelope identity source: `ServiceToken` for keys, `Jwt` for users.
    pub source: data_plane_core::IdentitySource,
}

/// Exchange an API key for a tenant identity via tenant-control. Go performs the
/// Argon2id hash compare; Rust trusts the `valid`/`tenant_id` result.
pub async fn verify_key(
    client: &reqwest::Client,
    base_url: &str,
    token: &str,
    key: &str,
) -> Result<VerifiedIdentity, AuthError> {
    let path = "/v1/keys/verify";
    let url = format!("{}{path}", base_url.trim_end_matches('/'));
    // Serialize once so the HMAC body digest signs the exact bytes sent.
    let body = serde_json::to_vec(&serde_json::json!({ "key": key }))
        .map_err(|e| AuthError::Upstream(format!("verify body encode: {e}")))?;
    let req = client
        .post(&url)
        .header(reqwest::header::CONTENT_TYPE, "application/json");
    let req = if data_plane_pool::service_auth::hmac_mode() {
        req.header(
            "X-Service-Auth",
            data_plane_pool::service_auth::compute_service_auth(token, "POST", path, &body),
        )
    } else {
        req.header("X-Service-Token", token)
    };
    let resp = req
        .body(body)
        .send()
        .await
        .map_err(|e| AuthError::Upstream(format!("tenant-control verify: {e}")))?;
    // A 5xx is an upstream failure (502); a 4xx OR a 200-with-`valid:false` both
    // mean the KEY is bad (401). Parse the body either way so a structured
    // `reason` surfaces; an unparseable 4xx is still an unauthorized key.
    let status = resp.status();
    if status.is_server_error() {
        return Err(AuthError::Upstream(format!(
            "tenant-control verify status {status}"
        )));
    }
    let text = resp.text().await.unwrap_or_default();
    match serde_json::from_str::<VerifyResponse>(&text) {
        Ok(body) if body.valid => {
            let key_id = body.key_id.unwrap_or_default();
            Ok(VerifiedIdentity {
                tenant_id: body
                    .tenant_id
                    .ok_or_else(|| AuthError::Upstream("verify missing tenant_id".into()))?,
                // Same principal string the query-router stamps — parity.
                principal: format!("api-key:{key_id}"),
                key_id,
                scopes: body.scopes,
                source: data_plane_core::IdentitySource::ServiceToken,
            })
        }
        Ok(body) => Err(AuthError::Unauthorized(
            body.reason.unwrap_or_else(|| "invalid api key".into()),
        )),
        Err(_) if status.is_client_error() => {
            Err(AuthError::Unauthorized(format!("key rejected ({status})")))
        }
        Err(e) => Err(AuthError::Upstream(format!("verify decode: {e}"))),
    }
}

#[derive(Debug, Deserialize)]
struct ConnectResponse {
    engine: String,
    connection_string: String,
    #[serde(default)]
    isolation: Option<String>,
    #[serde(default)]
    capability_overrides: Option<serde_json::Value>,
}

/// A resolved mount: engine + DSN + the tenant's tier mask (Phase 4).
#[derive(Clone)]
pub struct ResolvedMount {
    pub engine: String,
    pub connection_string: String,
    pub isolation: Option<String>,
    pub capability_overrides: Option<serde_json::Value>,
}

/// Resolve a mount (engine + DSN + tier mask) for `(tenant, db_id)` via
/// adapter-registry. The registry scopes `/connect` to the caller tenant, so a
/// cross-tenant db id is a 404 there — the same isolation the query-router relies
/// on. The inline DSN never transits any client.
pub async fn resolve_mount(
    client: &reqwest::Client,
    registry_url: &str,
    token: &str,
    tenant: &str,
    db_id: &str,
) -> Result<ResolvedMount, AuthError> {
    let path = format!("/databases/{db_id}/connect");
    let url = format!("{}{path}", registry_url.trim_end_matches('/'));
    let req = client.get(&url).header("X-Tenant-Id", tenant);
    let req = if data_plane_pool::service_auth::hmac_mode() {
        req.header(
            "X-Service-Auth",
            data_plane_pool::service_auth::compute_service_auth(token, "GET", &path, b""),
        )
    } else {
        req.header("X-Service-Token", token)
    };
    let resp = req
        .send()
        .await
        .map_err(|e| AuthError::Upstream(format!("adapter-registry connect: {e}")))?;
    if resp.status() == reqwest::StatusCode::NOT_FOUND {
        return Err(AuthError::NotFound(format!(
            "mount '{db_id}' not found for this tenant"
        )));
    }
    if !resp.status().is_success() {
        return Err(AuthError::Upstream(format!(
            "adapter-registry connect status {}",
            resp.status()
        )));
    }
    let body: ConnectResponse = resp
        .json()
        .await
        .map_err(|e| AuthError::Upstream(format!("connect decode: {e}")))?;
    Ok(ResolvedMount {
        engine: body.engine,
        connection_string: body.connection_string,
        isolation: body.isolation,
        capability_overrides: body.capability_overrides,
    })
}
