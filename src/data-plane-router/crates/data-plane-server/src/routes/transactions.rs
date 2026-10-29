/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   transactions.rs                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:32:44 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:32:45 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Multi-statement transaction lifecycle: begin/execute/commit/rollback over the
//! in-`AppState` registry, with pool pinning and cross-tenant guards.
use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use data_plane_core::{DataOperation, PoolRegistry, RequestIdentity, TxBeginRequest, TxHandle};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::Duration;

use super::helpers::{
    bad_request, json_result, map_data_plane_error, require_capability, transaction_not_found,
    validate_identity_mount,
};
use super::state::AppState;
use super::txregistry::TakeRefusal;

// Default transaction TTL — after this the registry stops handing out the
// handle on lookup. The connection is NOT force-closed here; a follow-up
// slice can add a reaper task that calls rollback on expired entries.
const DEFAULT_TX_TTL_SECS: u64 = 30;

#[derive(Debug, Clone, Serialize)]
pub(super) struct TxBeginResponse {
    tx_id: String,
    mount_id: String,
    expires_in_ms: u64,
}

pub(super) async fn begin_transaction(
    State(state): State<AppState>,
    Json(request): Json<TxBeginRequest>,
) -> impl IntoResponse {
    if let Err(message) = validate_identity_mount(&state, &request.identity, &request.mount) {
        return bad_request(message);
    }
    // Honesty gate: an engine whose `begin()` is NotImplemented (mongo/redis/
    // http) advertises `transactions:false` — reject here with 400 rather than
    // 501 from deep in the adapter.
    if let Err(resp) = require_capability(&state, &request.mount.engine, "transactions", |c| {
        c.transactions
    }) {
        return resp;
    }
    // Phase 4 tiering: the engine may support transactions but the tenant's
    // package tier can exclude them (Essential) → 403 CapabilityGated, distinct
    // from the 422 above (engine genuinely can't begin()).
    if let Some(descriptor) = state
        .engines
        .iter()
        .find(|e| e.engine == request.mount.engine)
    {
        let effective = data_plane_core::apply_capability_overrides(
            &descriptor.capabilities,
            request.mount.capability_overrides.as_ref(),
        );
        if descriptor.capabilities.transactions && !effective.transactions {
            return map_data_plane_error(&data_plane_core::DataPlaneError::CapabilityGated {
                capability: "transactions".to_string(),
            });
        }
    }

    // Capture identity/mount info BEFORE moving `request` into pool.begin.
    let tenant_id = request.identity.tenant_id.clone();
    let mount = request.mount.clone();
    // `pool_key` identifies the pool the tx's connection comes from, so we can
    // pin it against eviction/reaping for the life of the transaction. Derived
    // through the registry so it honors the pool-sharing policy (B4-pools) — a
    // shared_rls tx must pin the SAME shared pool `get_or_create` handed out.
    let pool_key = state.registry.pool_key_for(&mount);

    let pool = match state.registry.get_or_create(mount).await {
        Ok(pool) => pool,
        Err(err) => return map_data_plane_error(&err),
    };
    let handle = match pool.begin(request).await {
        Ok(handle) => handle,
        Err(err) => return map_data_plane_error(&err),
    };
    // Pin the pool now that a tx holds one of its connections: the registry
    // must not close it (eviction / idle reap) until commit/rollback unpins.
    state.registry.pin_tx(&pool_key).await;

    let ttl = Duration::from_secs(DEFAULT_TX_TTL_SECS);
    let mount_id = handle.mount_id().to_string();
    let handle_arc: Arc<dyn TxHandle> = Arc::from(handle);
    let tx_id = state
        .transactions
        .register(handle_arc, tenant_id, mount_id.clone(), pool_key, ttl)
        .await;

    (
        StatusCode::CREATED,
        Json(TxBeginResponse {
            tx_id,
            mount_id,
            expires_in_ms: ttl.as_millis() as u64,
        }),
    )
        .into_response()
}

#[derive(Debug, Clone, Deserialize)]
pub(super) struct TxExecuteRequest {
    identity: RequestIdentity,
    operation: DataOperation,
}

pub(super) async fn execute_in_transaction(
    State(state): State<AppState>,
    Path(tx_id): Path<String>,
    Json(request): Json<TxExecuteRequest>,
) -> impl IntoResponse {
    if !request.identity.is_tenant_scoped() {
        return bad_request("identity.tenant_id is required".to_string());
    }
    let (handle, tx_tenant) = match state.transactions.get(&tx_id).await {
        Some(entry) => entry,
        None => return transaction_not_found(&tx_id),
    };
    // Cross-tenant guard: a tenant cannot resume another tenant's tx by
    // guessing the tx_id. Identity-tenant must match the tenant that opened
    // the transaction.
    if request.identity.tenant_id != tx_tenant {
        return bad_request(
            "identity tenant does not match the tenant that opened this transaction".to_string(),
        );
    }
    if request.operation.resource.trim().is_empty() {
        return bad_request("operation.resource is required".to_string());
    }

    json_result(handle.execute(request.operation, request.identity).await)
}

/// Commit/rollback body. `identity` is optional so a body-less caller keeps
/// working; when sent, only the tenant that opened the tx may finalise it.
#[derive(Debug, Default, Deserialize)]
pub(super) struct TxFinalizeRequest {
    #[serde(default)]
    identity: Option<RequestIdentity>,
}

/// The tenant a finalise call claims: `Ok(None)` for an empty body or one
/// without `identity`.
fn claimed_tenant(body: &[u8]) -> Result<Option<String>, Response> {
    if body.iter().all(u8::is_ascii_whitespace) {
        return Ok(None);
    }
    let request: TxFinalizeRequest = serde_json::from_slice(body)
        .map_err(|e| bad_request(format!("invalid finalize body: {e}")))?;
    match request.identity {
        None => Ok(None),
        Some(identity) if identity.is_tenant_scoped() => Ok(Some(identity.tenant_id)),
        Some(_) => Err(bad_request("identity.tenant_id is required".to_string())),
    }
}

#[derive(Clone, Copy)]
enum Finalize {
    Commit,
    Rollback,
}

async fn finalize(state: AppState, tx_id: String, body: &[u8], how: Finalize) -> Response {
    let tenant = match claimed_tenant(body) {
        Ok(tenant) => tenant,
        Err(refusal) => return refusal,
    };
    let (handle, pool_key) = match state
        .transactions
        .take_for_tenant(&tx_id, tenant.as_deref())
        .await
    {
        Ok(entry) => entry,
        Err(TakeRefusal::NotFound) => return transaction_not_found(&tx_id),
        Err(TakeRefusal::OtherTenant) => {
            return bad_request(
                "identity tenant does not match the tenant that opened this transaction"
                    .to_string(),
            )
        }
    };
    let (result, done) = match how {
        Finalize::Commit => (handle.commit().await, "committed"),
        Finalize::Rollback => (handle.rollback().await, "rolled_back"),
    };
    // The tx no longer holds the pool's connection — release the pin so the
    // registry may evict/reap it again. Always unpin, even on a finalise error.
    state.registry.unpin_tx(&pool_key).await;
    match result {
        Ok(()) => (StatusCode::OK, Json(TxFinalize { tx_id, state: done })).into_response(),
        Err(err) => map_data_plane_error(&err),
    }
}

pub(super) async fn commit_transaction(
    State(state): State<AppState>,
    Path(tx_id): Path<String>,
    body: Bytes,
) -> Response {
    finalize(state, tx_id, &body, Finalize::Commit).await
}

pub(super) async fn rollback_transaction(
    State(state): State<AppState>,
    Path(tx_id): Path<String>,
    body: Bytes,
) -> Response {
    finalize(state, tx_id, &body, Finalize::Rollback).await
}

#[derive(Debug, Clone, Serialize)]
pub(super) struct TxFinalize {
    tx_id: String,
    state: &'static str,
}

#[cfg(test)]
mod tests {
    use super::claimed_tenant;

    fn identity(tenant: &str) -> String {
        format!(r#"{{"identity":{{"tenant_id":"{tenant}","source":"service_token"}}}}"#)
    }

    #[test]
    fn a_finalize_body_without_identity_claims_no_tenant() {
        assert_eq!(claimed_tenant(b"").ok(), Some(None));
        assert_eq!(claimed_tenant(b" \n").ok(), Some(None));
        assert_eq!(claimed_tenant(b"{}").ok(), Some(None));
    }

    #[test]
    fn a_finalize_body_with_identity_claims_its_tenant() {
        assert_eq!(
            claimed_tenant(identity("t-1").as_bytes()).ok(),
            Some(Some("t-1".to_string()))
        );
    }

    #[test]
    fn an_empty_tenant_or_a_broken_body_is_refused() {
        assert!(claimed_tenant(identity(" ").as_bytes()).is_err());
        assert!(claimed_tenant(b"{\"identity\":").is_err());
    }
}
