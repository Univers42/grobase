//! PB `/api/batch` — `{requests: [{method, url, body}]}` executed as ONE
//! atomic transaction (the SDK's `pb.createBatch()`), answered with an array
//! of `{status, body}` per sub-request.
//!
//! Translation: each sub-request's method+url is parsed back into a records
//! operation (create/update/delete/upsert on `/api/collections/{c}/records
//! [/{id}]`), lowered exactly like the records handlers (typed body, ids,
//! autodate stamps), then the whole set rides the native ATOMIC batch op —
//! a poison item rolls everything back, like PB. Bodies of successful
//! creates/updates are re-fetched post-commit so the SDK sees full records.

use axum::extract::{FromRequest, State};
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::routing::post;
use axum::{Json, Router};
use data_plane_core::{DataOperation, DataOperationKind};
use serde_json::{json, Value};

use super::records::{record_for_batch, BatchPlan};
use super::{exec, pb_auth, pb_err, pb_of, PbAuth};
use crate::routes::AppState;

async fn batch(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    request: axum::extract::Request,
) -> axum::response::Response {
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    // The official SDK sends /api/batch as multipart/form-data with the
    // payload in a `@jsonPayload` part (so file uploads can ride along);
    // plain JSON is accepted too, like PB.
    let content_type = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default()
        .to_string();
    let req: Value = if content_type.starts_with("multipart/form-data") {
        let mut multipart = match axum::extract::Multipart::from_request(request, &state).await {
            Ok(m) => m,
            Err(_) => return pb_err(StatusCode::BAD_REQUEST, "malformed multipart body"),
        };
        let mut payload = None;
        while let Ok(Some(field)) = multipart.next_field().await {
            if field.name() == Some("@jsonPayload") {
                payload = field.text().await.ok();
            }
        }
        match payload.and_then(|t| serde_json::from_str(&t).ok()) {
            Some(v) => v,
            None => return pb_err(StatusCode::BAD_REQUEST, "missing @jsonPayload part"),
        }
    } else {
        let bytes = match axum::body::to_bytes(request.into_body(), 16 * 1024 * 1024).await {
            Ok(b) => b,
            Err(_) => return pb_err(StatusCode::BAD_REQUEST, "unreadable body"),
        };
        match serde_json::from_slice(&bytes) {
            Ok(v) => v,
            Err(_) => return pb_err(StatusCode::BAD_REQUEST, "invalid JSON body"),
        }
    };
    let settings = pb.settings();
    if settings["batch"]["enabled"] != serde_json::json!(true) {
        // PB ships batch DISABLED; superusers enable it via /api/settings.
        return pb_err(StatusCode::FORBIDDEN, "Batch requests are not allowed.");
    }
    let max_batch = settings["batch"]["maxRequests"].as_u64().unwrap_or(50).max(1) as usize;
    let Some(requests) = req.get("requests").and_then(|v| v.as_array()) else {
        return pb_err(StatusCode::BAD_REQUEST, "missing requests array");
    };
    if requests.is_empty() || requests.len() > max_batch {
        return pb_err(
            StatusCode::BAD_REQUEST,
            &format!("batch supports 1..={max_batch} requests"),
        );
    }
    let superuser = matches!(pb_auth(&state, &headers), PbAuth::Superuser);

    // Plan every sub-request BEFORE executing anything (atomicity: a malformed
    // item must fail the whole batch up front, like PB validation).
    let mut plans: Vec<BatchPlan> = Vec::with_capacity(requests.len());
    for (idx, r) in requests.iter().enumerate() {
        let method = r.get("method").and_then(|v| v.as_str()).unwrap_or_default();
        let url = r.get("url").and_then(|v| v.as_str()).unwrap_or_default();
        let body = r.get("body").cloned().unwrap_or_else(|| json!({}));
        match record_for_batch(&pb, &state, &headers, superuser, method, url, &body) {
            Ok(plan) => plans.push(plan),
            Err(m) => return pb_err(StatusCode::BAD_REQUEST, &format!("request {idx}: {m}")),
        }
    }

    // One native atomic batch (savepoint-per-item inside one transaction).
    let sub_ops: Vec<Value> = plans
        .iter()
        .map(|p| serde_json::to_value(&p.op).unwrap_or(Value::Null))
        .collect();
    let mut op = DataOperation {
        op: DataOperationKind::Batch,
        resource: "batch".to_string(),
        data: Some(Value::Array(sub_ops)),
        filter: None,
        sort: None,
        limit: None,
        offset: None,
        idempotency_key: None,
        expected_version: None,
        returning: None,
        aggregate: None,
        fields: None,
        search: None,
        vector: None,
    };
    op.resource = plans
        .first()
        .map(|p| p.op.resource.clone())
        .unwrap_or_else(|| "batch".to_string());
    if let Err(r) = exec(&state, op).await {
        return r;
    }

    // Post-commit: build PB bodies (full records for create/update).
    let mut out = Vec::with_capacity(plans.len());
    for plan in &plans {
        let body = match plan.op.op {
            DataOperationKind::Delete => json!(null),
            _ => match super::records::fetch_shaped(&state, &plan.collection, &plan.record_id).await
            {
                Ok(Some(rec)) => rec,
                _ => json!(null),
            },
        };
        let status = if plan.op.op == DataOperationKind::Delete { 204 } else { 200 };
        out.push(json!({ "status": status, "body": body }));
    }
    (StatusCode::OK, Json(Value::Array(out))).into_response()
}

pub fn routes() -> Router<AppState> {
    Router::new().route("/api/batch", post(batch))
}
