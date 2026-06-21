/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   permissions.rs                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:32:25 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:32:26 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! In-Rust ABAC/RBAC decision endpoint (`/v1/permissions/decide`) mirroring the
//! NestJS DecisionsService shape, with a 503 fallback when no bundle is loaded.
use crate::abac::Decision;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use serde::Deserialize;

use super::helpers::ApiError;
use super::state::AppState;

// ── /v1/permissions/decide ──────────────────────────────────────────────────
//
// In-Rust ABAC/RBAC decision endpoint. Mirrors the NestJS
// `DecisionsService.decide()` shape so the query-router can swap targets
// without changing its request envelope. When the local evaluator isn't
// configured (no DATA_PLANE_PERMISSION_BUNDLE env) the endpoint returns 503
// and the caller falls back to the permission-engine HTTP path.

#[derive(Debug, Clone, Deserialize)]
pub(super) struct DecisionUser {
    id: String,
}

#[derive(Debug, Clone, Deserialize)]
pub(super) struct DecideRequest {
    user: DecisionUser,
    resource_type: String,
    resource_name: String,
    op: String,
    #[serde(default)]
    tenant_id: Option<String>,
    #[serde(default)]
    project_id: Option<String>,
    #[serde(default)]
    app_id: Option<String>,
}

pub(super) async fn decide_permission(
    State(state): State<AppState>,
    Json(request): Json<DecideRequest>,
) -> impl IntoResponse {
    // tenant/project/app are accepted for future scoping; today's evaluator
    // doesn't use them (the SQL function didn't either). Drop on the floor
    // until the bundle format adds tenant-scoped policies.
    let _ = (request.tenant_id, request.project_id, request.app_id);
    let Some(evaluator) = state.evaluator.as_ref() else {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(ApiError {
                error: "evaluator_not_configured".to_string(),
                message:
                    "DATA_PLANE_PERMISSION_BUNDLE is not set; fall back to permission-engine HTTP"
                        .to_string(),
            }),
        )
            .into_response();
    };
    let action = action_for_op(&request.op);
    let decision: Decision = evaluator.decide(
        &request.user.id,
        &request.resource_type,
        &request.resource_name,
        &action,
    );
    (StatusCode::OK, Json(decision)).into_response()
}

fn action_for_op(op: &str) -> String {
    match op {
        "list" | "get" => "select".to_string(),
        "upsert" => "update".to_string(),
        other => other.to_string(),
    }
}
