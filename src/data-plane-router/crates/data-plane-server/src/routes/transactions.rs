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
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
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

pub(super) async fn commit_transaction(
    State(state): State<AppState>,
    Path(tx_id): Path<String>,
) -> impl IntoResponse {
    let (handle, pool_key) = match state.transactions.take(&tx_id).await {
        Some(entry) => entry,
        None => return transaction_not_found(&tx_id),
    };
    let result = handle.commit().await;
    // The tx no longer holds the pool's connection — release the pin so the
    // registry may evict/reap it again. Always unpin, even on commit error.
    state.registry.unpin_tx(&pool_key).await;
    match result {
        Ok(()) => (
            StatusCode::OK,
            Json(TxFinalize {
                tx_id,
                state: "committed",
            }),
        )
            .into_response(),
        Err(err) => map_data_plane_error(&err),
    }
}

pub(super) async fn rollback_transaction(
    State(state): State<AppState>,
    Path(tx_id): Path<String>,
) -> impl IntoResponse {
    let (handle, pool_key) = match state.transactions.take(&tx_id).await {
        Some(entry) => entry,
        None => return transaction_not_found(&tx_id),
    };
    let result = handle.rollback().await;
    state.registry.unpin_tx(&pool_key).await;
    match result {
        Ok(()) => (
            StatusCode::OK,
            Json(TxFinalize {
                tx_id,
                state: "rolled_back",
            }),
        )
            .into_response(),
        Err(err) => map_data_plane_error(&err),
    }
}

#[derive(Debug, Clone, Serialize)]
pub(super) struct TxFinalize {
    tx_id: String,
    state: &'static str,
}
