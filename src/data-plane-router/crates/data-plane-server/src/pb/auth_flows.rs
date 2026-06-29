//! PB auth email flows: OTP login, verification, password reset, email
//! change. Request stages are enumeration-safe exactly like PB (request-otp
//! returns an `otpId` whether or not the account exists; the other request
//! endpoints answer 204 unconditionally). Codes live in pb_meta
//! (`pb_codes`: sha256 digest, 10-minute TTL, 5 attempts); confirmation
//! tokens are short-TTL typed JWTs minted by the one runtime. Mail goes out
//! through the binocle-one SMTP mailer when configured (`ONE_SMTP_HOST`),
//! and is skipped silently otherwise — identical observable behavior to a
//! PB instance without SMTP.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::post;
use axum::{Json, Router};
use serde_json::{json, Value};

use super::{exec, pb_err, pb_id, pb_of, PbAuth};
use crate::routes::AppState;

const OTP_TTL_SECS: i64 = 600;
const OTP_MAX_ATTEMPTS: i64 = 5;

impl super::PbState {
    pub(crate) fn code_issue(&self, otp_id: &str, collection: &str, record: &str, code: &str) {
        let conn = self
            .meta
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let _ = conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS pb_codes (
                id         TEXT PRIMARY KEY,
                collection TEXT NOT NULL,
                record     TEXT NOT NULL,
                digest     TEXT NOT NULL,
                expires_at INTEGER NOT NULL,
                attempts   INTEGER NOT NULL DEFAULT 0
            );",
        );
        let _ = conn.execute(
            "INSERT OR REPLACE INTO pb_codes (id, collection, record, digest, expires_at, attempts)
             VALUES (?1, ?2, ?3, ?4, ?5, 0)",
            rusqlite::params![
                otp_id,
                collection,
                record,
                crate::one::sha256_hex(code),
                chrono::Utc::now().timestamp() + OTP_TTL_SECS,
            ],
        );
    }

    /// Burn an attempt; deletes on success or exhaustion. Returns the record
    /// id on a correct, fresh code.
    pub(crate) fn code_consume(
        &self,
        otp_id: &str,
        collection: &str,
        code: &str,
    ) -> Option<String> {
        let conn = self
            .meta
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let row: Option<(String, String, i64, i64)> = conn
            .query_row(
                "SELECT record, digest, expires_at, attempts FROM pb_codes
                 WHERE id = ?1 AND collection = ?2",
                [otp_id, collection],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .ok();
        let (record, digest, expires, attempts) = row?;
        let now = chrono::Utc::now().timestamp();
        let ok = crate::one::ct_eq(&crate::one::sha256_hex(code), &digest);
        if ok || attempts + 1 >= OTP_MAX_ATTEMPTS || now >= expires {
            let _ = conn.execute("DELETE FROM pb_codes WHERE id = ?1", [otp_id]);
        } else {
            let _ = conn.execute(
                "UPDATE pb_codes SET attempts = attempts + 1 WHERE id = ?1",
                [otp_id],
            );
        }
        (ok && now < expires).then_some(record)
    }
}

/// Find an auth record's engine row by email (None when absent).
async fn record_by_email(state: &AppState, collection: &str, email: &str) -> Option<Value> {
    let mut op = super::records::base_op_pub(data_plane_core::DataOperationKind::Get, collection);
    op.filter = Some(json!({ "email": email }));
    exec(state, op).await.ok()?.rows.first().cloned()
}

fn send_mail(state: &AppState, to: &str, subject: &str, body: String) {
    if let Some(one) = state.one.clone() {
        let to = to.to_string();
        let subject = subject.to_string();
        tokio::spawn(async move {
            if let Some(mailer) = one.mailer.as_ref() {
                let _ = mailer.send(&to, &subject, body).await;
            }
        });
    }
}

/// POST /api/collections/{c}/request-otp {email} → {otpId} (always).
async fn request_otp(
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
    if col.options["otp"]["enabled"] != serde_json::json!(true) {
        return pb_err(
            StatusCode::FORBIDDEN,
            "The collection is not configured to allow OTP authentication.",
        );
    }
    let email = req
        .get("email")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .trim()
        .to_lowercase();
    if email.is_empty() {
        return pb_err(StatusCode::BAD_REQUEST, "missing email");
    }
    // PB returns an otpId WHETHER OR NOT the account exists (no enumeration).
    let otp_id = pb_id();
    if let Some(row) = record_by_email(&state, &col.name, &email).await {
        if let Some(rid) = row.get("id").and_then(Value::as_str) {
            let code: String = format!("{:08}", uuid::Uuid::new_v4().as_u128() % 100_000_000);
            pb.code_issue(&otp_id, &col.id, rid, &code);
            send_mail(
                &state,
                &email,
                "Your one-time login code",
                format!("Your code: {code}\n\nIt expires in 10 minutes.\n"),
            );
        }
    }
    (StatusCode::OK, Json(json!({ "otpId": otp_id }))).into_response()
}

/// POST /api/collections/{c}/auth-with-otp {otpId, password: <code>}
async fn auth_with_otp(
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
    if col.options["otp"]["enabled"] != serde_json::json!(true) {
        return pb_err(
            StatusCode::FORBIDDEN,
            "The collection is not configured to allow OTP authentication.",
        );
    }
    let otp_id = req
        .get("otpId")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    let code = req
        .get("password")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    let Some(rid) = pb.code_consume(otp_id, &col.id, code) else {
        return pb_err(StatusCode::BAD_REQUEST, "Failed to authenticate.");
    };
    // second factor of an MFA flow: the mfaId minted by the first factor
    // must exist, match this record, and burn on use
    if let Some(mfa_id) = req.get("mfaId").and_then(|v| v.as_str()) {
        let Some(mfa_rid) = pb.code_consume(&format!("mfa-{mfa_id}"), &col.id, mfa_id) else {
            return pb_err(StatusCode::BAD_REQUEST, "Invalid or expired MFA session.");
        };
        if mfa_rid != rid {
            return pb_err(StatusCode::BAD_REQUEST, "Invalid or expired MFA session.");
        }
    }
    let mut record = match super::records::fetch_shaped(&state, &col.name, &rid).await {
        Ok(Some(rec)) => rec,
        _ => return pb_err(StatusCode::BAD_REQUEST, "Failed to authenticate."),
    };
    let email = record
        .get("email")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();
    let one = match crate::one::one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    let token = match one.mint_jwt(&format!("pb:{}:{}", col.id, rid), &email) {
        Ok((t, _)) => t,
        Err(e) => return pb_err(StatusCode::INTERNAL_SERVER_ERROR, &e),
    };
    super::auth::scrub_auth_record(&mut record, true);
    (
        StatusCode::OK,
        Json(json!({ "token": token, "record": record })),
    )
        .into_response()
}

/// The three "request a mail" doors — 204 unconditionally (no enumeration),
/// mail sent only when the account exists + SMTP is configured.
async fn request_mail_flow(
    state: &AppState,
    cname: &str,
    email: &str,
    subject: &str,
    purpose: &str,
) -> axum::response::Response {
    let pb = match pb_of(state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    let Some(col) = pb.col_get(cname) else {
        return pb_err(StatusCode::NOT_FOUND, "collection not found");
    };
    let email = email.trim().to_lowercase();
    if email.is_empty() {
        return pb_err(StatusCode::BAD_REQUEST, "missing email");
    }
    if let Some(row) = record_by_email(state, &col.name, &email).await {
        if let (Some(rid), Ok(one)) = (
            row.get("id").and_then(Value::as_str),
            crate::one::one_of(state),
        ) {
            if let Ok(token) = one.mint_flow_jwt(&format!("pb:{}:{}", col.id, rid), &email, purpose)
            {
                send_mail(
                    state,
                    &email,
                    subject,
                    format!("Use this token to continue: {token}\n\nIt expires in 30 minutes.\n"),
                );
            }
        }
    }
    StatusCode::NO_CONTENT.into_response()
}

async fn request_verification(
    State(state): State<AppState>,
    Path(cname): Path<String>,
    Json(req): Json<Value>,
) -> axum::response::Response {
    let email = req
        .get("email")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    request_mail_flow(&state, &cname, email, "Verify your email", "pbverify").await
}

async fn request_password_reset(
    State(state): State<AppState>,
    Path(cname): Path<String>,
    Json(req): Json<Value>,
) -> axum::response::Response {
    let email = req
        .get("email")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    request_mail_flow(&state, &cname, email, "Reset your password", "pbreset").await
}

/// POST /api/collections/{c}/request-email-change {newEmail} — authed.
async fn request_email_change(
    State(state): State<AppState>,
    headers: axum::http::header::HeaderMap,
    Path(cname): Path<String>,
    Json(req): Json<Value>,
) -> axum::response::Response {
    let auth = super::pb_auth(&state, &headers);
    if !matches!(auth, PbAuth::Record { .. }) {
        return pb_err(
            StatusCode::UNAUTHORIZED,
            "The request requires valid record authorization token.",
        );
    }
    let new_email = req
        .get("newEmail")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .trim()
        .to_lowercase();
    if new_email.is_empty() || !new_email.contains('@') {
        return pb_err(StatusCode::BAD_REQUEST, "invalid newEmail");
    }
    let _ = cname;
    // Token carries the target address; confirm applies it after verify.
    if let (
        PbAuth::Record {
            collection_id,
            record_id,
        },
        Ok(one),
    ) = (&auth, crate::one::one_of(&state))
    {
        if let Ok(token) = one.mint_flow_jwt(
            &format!("pb:{collection_id}:{record_id}:{new_email}"),
            &new_email,
            "pbemailchange",
        ) {
            send_mail(
                &state,
                &new_email,
                "Confirm your new email",
                format!("Use this token to confirm: {token}\n"),
            );
        }
    }
    StatusCode::NO_CONTENT.into_response()
}

/// Confirm doors: validate the typed flow JWT. Garbage/expired → 400.
async fn confirm_flow(
    state: &AppState,
    token: &str,
    expected_typ: &str,
) -> Result<(String, String, Option<String>), axum::response::Response> {
    let one = crate::one::one_of(state)?;
    let sub = one
        .verify_flow_jwt(token, expected_typ)
        .map_err(|_| pb_err(StatusCode::BAD_REQUEST, "Invalid or expired token."))?;
    let rest = sub.strip_prefix("pb:").unwrap_or(&sub);
    let mut parts = rest.splitn(3, ':');
    let col = parts.next().unwrap_or_default().to_string();
    let rid = parts.next().unwrap_or_default().to_string();
    let extra = parts.next().map(String::from);
    if col.is_empty() || rid.is_empty() {
        return Err(pb_err(StatusCode::BAD_REQUEST, "Invalid or expired token."));
    }
    Ok((col, rid, extra))
}

async fn confirm_verification(
    State(state): State<AppState>,
    Path(cname): Path<String>,
    Json(req): Json<Value>,
) -> axum::response::Response {
    let token = req
        .get("token")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    let (_, rid, _) = match confirm_flow(&state, token, "pbverify").await {
        Ok(v) => v,
        Err(r) => return r,
    };
    let mut op = super::records::base_op_pub(data_plane_core::DataOperationKind::Update, &cname);
    op.data = Some(json!({ "verified": true }));
    op.filter = Some(json!({ "id": rid }));
    match exec(&state, op).await {
        Ok(_) => StatusCode::NO_CONTENT.into_response(),
        Err(r) => r,
    }
}

async fn confirm_password_reset(
    State(state): State<AppState>,
    Path(cname): Path<String>,
    Json(req): Json<Value>,
) -> axum::response::Response {
    let token = req
        .get("token")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    let password = req
        .get("password")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    let confirm = req
        .get("passwordConfirm")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    if password.len() < 8 || password != confirm {
        return pb_err(StatusCode::BAD_REQUEST, "invalid or unconfirmed password");
    }
    let (_, rid, _) = match confirm_flow(&state, token, "pbreset").await {
        Ok(v) => v,
        Err(r) => return r,
    };
    let pw = password.to_string();
    let hash = match crate::one::kdf_blocking(move || crate::one::hash_password(&pw)).await {
        Some(Ok(h)) => h,
        _ => return pb_err(StatusCode::INTERNAL_SERVER_ERROR, "password hashing failed"),
    };
    let mut op = super::records::base_op_pub(data_plane_core::DataOperationKind::Update, &cname);
    op.data = Some(json!({ "password": hash }));
    op.filter = Some(json!({ "id": rid }));
    match exec(&state, op).await {
        Ok(_) => StatusCode::NO_CONTENT.into_response(),
        Err(r) => r,
    }
}

async fn confirm_email_change(
    State(state): State<AppState>,
    Path(cname): Path<String>,
    Json(req): Json<Value>,
) -> axum::response::Response {
    let token = req
        .get("token")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    let (_, rid, extra) = match confirm_flow(&state, token, "pbemailchange").await {
        Ok(v) => v,
        Err(r) => return r,
    };
    let Some(new_email) = extra else {
        return pb_err(StatusCode::BAD_REQUEST, "Invalid or expired token.");
    };
    let mut op = super::records::base_op_pub(data_plane_core::DataOperationKind::Update, &cname);
    op.data = Some(json!({ "email": new_email, "verified": true }));
    op.filter = Some(json!({ "id": rid }));
    match exec(&state, op).await {
        Ok(_) => StatusCode::NO_CONTENT.into_response(),
        Err(r) => r,
    }
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/api/collections/:collection/request-otp",
            post(request_otp),
        )
        .route(
            "/api/collections/:collection/auth-with-otp",
            post(auth_with_otp),
        )
        .route(
            "/api/collections/:collection/request-verification",
            post(request_verification),
        )
        .route(
            "/api/collections/:collection/confirm-verification",
            post(confirm_verification),
        )
        .route(
            "/api/collections/:collection/request-password-reset",
            post(request_password_reset),
        )
        .route(
            "/api/collections/:collection/confirm-password-reset",
            post(confirm_password_reset),
        )
        .route(
            "/api/collections/:collection/request-email-change",
            post(request_email_change),
        )
        .route(
            "/api/collections/:collection/confirm-email-change",
            post(confirm_email_change),
        )
}
