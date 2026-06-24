//! PB auth collections: password login, token refresh, impersonation.
//!
//! An auth collection (type `"auth"`) is a records collection whose rows are
//! principals: system columns `email` (unique), `password` (argon2id PHC
//! hash — never serialized), `verified`, `emailVisibility`. Tokens are the
//! same HS256 JWTs binocle-one mints, with `sub = "pb:{collection id}:{record
//! id}"` so one verify path serves both worlds.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::post;
use axum::{Json, Router};
use serde_json::{json, Value};

use super::{exec, pb_err, pb_of, PbAuth};
use crate::routes::AppState;

/// The shaped auth record for a verified `PbAuth::Record` caller (None for
/// guests/superuser) — feeds `@request.auth.*` rule substitution.
pub(crate) async fn auth_record_of(state: &AppState, auth: &PbAuth) -> Option<Value> {
    let PbAuth::Record { collection_id, record_id } = auth else {
        return None;
    };
    super::records::fetch_shaped(state, collection_id, record_id)
        .await
        .ok()
        .flatten()
}

/// Strip secrets + apply email visibility to an auth record's public shape.
/// `privileged` = superuser or the record itself.
pub(crate) fn scrub_auth_record(record: &mut Value, privileged: bool) {
    if let Some(map) = record.as_object_mut() {
        map.remove("password");
        map.remove("passwordConfirm");
        let visible = map
            .get("emailVisibility")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if !visible && !privileged {
            map.remove("email");
        }
    }
}

/// Facade twin of `one::verify_password_singleflight` over PbState's cache.
async fn pb_verify_singleflight(
    pb: &super::PbState,
    rid: &str,
    stored: &str,
    password: &str,
) -> bool {
    if pb.verify_cached_pb(rid, password) {
        return true;
    }
    static FLIGHTS: std::sync::OnceLock<
        std::sync::Mutex<std::collections::HashMap<String, std::sync::Arc<tokio::sync::Mutex<()>>>>,
    > = std::sync::OnceLock::new();
    let flights = FLIGHTS.get_or_init(Default::default);
    let key = crate::one::sha256_hex(&format!("{rid}\u{0}{password}"));
    let gate = {
        let mut map = flights.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if map.len() > 4096 {
            map.retain(|_, v| std::sync::Arc::strong_count(v) > 1);
        }
        map.entry(key.clone()).or_default().clone()
    };
    let _guard = gate.lock().await;
    if pb.verify_cached_pb(rid, password) {
        return true;
    }
    let pw = password.to_string();
    let st = stored.to_string();
    let ok = matches!(
        crate::one::kdf_blocking(move || crate::one::verify_password(&pw, &st)).await,
        Some(true)
    );
    if ok {
        pb.cache_verify_pb(rid, password);
    }
    drop(_guard);
    let mut map = flights.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    if map.get(&key).map(|v| std::sync::Arc::strong_count(v) <= 1).unwrap_or(false) {
        map.remove(&key);
    }
    ok
}

fn mint_record_token(
    state: &AppState,
    collection_id: &str,
    record_id: &str,
    email: &str,
) -> Result<String, axum::response::Response> {
    let one = crate::one::one_of(state)?;
    one.mint_jwt(&format!("pb:{collection_id}:{record_id}"), email)
        .map(|(t, _)| t)
        .map_err(|e| pb_err(StatusCode::INTERNAL_SERVER_ERROR, &e))
}

/// POST /api/collections/{c}/auth-with-password {identity, password}
async fn auth_with_password(
    State(state): State<AppState>,
    Path(cname): Path<String>,
    Json(req): Json<Value>,
) -> axum::response::Response {
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    let Some(col) = pb.col_get(&cname) else {
        return pb_err(StatusCode::NOT_FOUND, "collection not found");
    };
    if col.kind != "auth" {
        return pb_err(StatusCode::BAD_REQUEST, "not an auth collection");
    }
    let identity = req
        .get("identity")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .trim()
        .to_lowercase();
    let password = req
        .get("password")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();
    if identity.is_empty() || password.is_empty() {
        return pb_err(StatusCode::BAD_REQUEST, "Failed to authenticate.");
    }

    // Fetch by email INCLUDING the stored hash (engine row, pre-shaping).
    let mut op = super::records::base_op_pub(data_plane_core::DataOperationKind::Get, &col.name);
    op.filter = Some(json!({ "email": identity }));
    let result = match exec(&state, op).await {
        Ok(r) => r,
        Err(r) => return r,
    };
    let Some(row) = result.rows.first() else {
        // burn comparable time: unknown email is indistinguishable
        let pw = password.clone();
        let _ = crate::one::kdf_blocking(move || crate::one::hash_password(&pw)).await;
        return pb_err(StatusCode::BAD_REQUEST, "Failed to authenticate.");
    };
    let stored = row
        .get("password")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();
    let rid = row.get("id").and_then(|v| v.as_str()).unwrap_or_default().to_string();
    // cache + single-flight: identical concurrent logins collapse to one KDF
    let ok = pb_verify_singleflight(&pb, &rid, &stored, &password).await;
    if !ok {
        return pb_err(StatusCode::BAD_REQUEST, "Failed to authenticate.");
    }
    // PB MFA: when the collection enables it, the FIRST factor answers 401
    // with an mfaId; the client completes with a second method (OTP here),
    // passing the mfaId along.
    if col.options["mfa"]["enabled"] == serde_json::json!(true) {
        let mfa_id = super::pb_id();
        pb.code_issue(&format!("mfa-{mfa_id}"), &col.id, &rid, &mfa_id);
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "mfaId": mfa_id })),
        )
            .into_response();
    }
    let token = match mint_record_token(&state, &col.id, &rid, &identity) {
        Ok(t) => t,
        Err(r) => return r,
    };
    let mut record = match super::records::fetch_shaped(&state, &col.name, &rid).await {
        Ok(Some(rec)) => rec,
        _ => return pb_err(StatusCode::INTERNAL_SERVER_ERROR, "record vanished"),
    };
    scrub_auth_record(&mut record, true); // it IS the caller
    (StatusCode::OK, Json(json!({ "token": token, "record": record }))).into_response()
}

/// POST /api/collections/{c}/auth-refresh — fresh token for the bearer.
async fn auth_refresh(
    State(state): State<AppState>,
    headers: axum::http::header::HeaderMap,
    Path(cname): Path<String>,
) -> axum::response::Response {
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    let Some(col) = pb.col_get(&cname) else {
        return pb_err(StatusCode::NOT_FOUND, "collection not found");
    };
    let auth = super::pb_auth(&state, &headers);
    let PbAuth::Record { collection_id, record_id } = &auth else {
        return pb_err(StatusCode::UNAUTHORIZED, "The request requires valid record authorization token.");
    };
    if *collection_id != col.id && *collection_id != col.name {
        return pb_err(StatusCode::FORBIDDEN, "token does not belong to this collection");
    }
    let mut record = match super::records::fetch_shaped(&state, &col.name, record_id).await {
        Ok(Some(rec)) => rec,
        _ => return pb_err(StatusCode::NOT_FOUND, "missing auth record"),
    };
    let email = record.get("email").and_then(|v| v.as_str()).unwrap_or_default().to_string();
    let token = match mint_record_token(&state, &col.id, record_id, &email) {
        Ok(t) => t,
        Err(r) => return r,
    };
    scrub_auth_record(&mut record, true);
    (StatusCode::OK, Json(json!({ "token": token, "record": record }))).into_response()
}

/// POST /api/collections/{c}/impersonate/{id} — superuser-only,
/// non-renewable; honors the SDK's custom `{duration}` (seconds).
async fn impersonate(
    State(state): State<AppState>,
    headers: axum::http::header::HeaderMap,
    Path((cname, rid)): Path<(String, String)>,
    body: Option<Json<Value>>,
) -> axum::response::Response {
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    if !matches!(super::pb_auth(&state, &headers), PbAuth::Superuser) {
        return pb_err(StatusCode::FORBIDDEN, "Only superusers can perform this action.");
    }
    let Some(col) = pb.col_get(&cname) else {
        return pb_err(StatusCode::NOT_FOUND, "collection not found");
    };
    let mut record = match super::records::fetch_shaped(&state, &col.name, &rid).await {
        Ok(Some(rec)) => rec,
        _ => return pb_err(StatusCode::NOT_FOUND, "The requested resource wasn't found."),
    };
    let email = record.get("email").and_then(|v| v.as_str()).unwrap_or_default().to_string();
    let duration = body
        .as_ref()
        .and_then(|Json(b)| b.get("duration").and_then(Value::as_u64))
        .filter(|d| *d > 0);
    let token = match duration {
        Some(ttl) => {
            let one = match crate::one::one_of(&state) {
                Ok(o) => o,
                Err(r) => return r,
            };
            match one.mint_jwt_ttl(&format!("pb:{}:{}", col.id, rid), &email, ttl) {
                Ok(t) => t,
                Err(e) => return pb_err(StatusCode::INTERNAL_SERVER_ERROR, &e),
            }
        }
        None => match mint_record_token(&state, &col.id, &rid, &email) {
            Ok(t) => t,
            Err(r) => return r,
        },
    };
    scrub_auth_record(&mut record, true);
    (StatusCode::OK, Json(json!({ "token": token, "record": record }))).into_response()
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/collections/:collection/auth-with-password", post(auth_with_password))
        .route("/api/collections/:collection/auth-refresh", post(auth_refresh))
        .route("/api/collections/:collection/impersonate/:id", post(impersonate))
}
