//! binocle-one email flows — verification, password reset, OTP login.
//!
//! One SMTP sender (lettre, rustls — no openssl) drives three code flows over
//! the shared `one_codes` store (8-digit codes, 10-minute TTL, 5 attempts,
//! 30-second resend floor):
//! - **verification**: bearer-authenticated request → code → `verified=1`;
//! - **password reset**: code → new password + every refresh token revoked;
//! - **OTP login**: code IS the factor → session (TOTP challenge still
//!   applies when the account has MFA enabled).
//!
//! `request-reset`/`request-otp` always answer 202 regardless of whether the
//! account exists — no account enumeration through these doors. Configure
//! with `ONE_SMTP_HOST/PORT/USER/PASS/FROM` and `ONE_SMTP_SECURITY`
//! (`none` | `starttls` | `tls`; Mailpit in dev wants `none`).

use axum::extract::State;
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::routing::post;
use axum::{Json, Router};
use lettre::{AsyncTransport, Tokio1Executor};
use serde::Deserialize;
use serde_json::json;

use crate::one::{hash_password, one_of};
use crate::routes::{api_err, AppState};

// ─── mailer ──────────────────────────────────────────────────────────────────

pub struct Mailer {
    transport: lettre::AsyncSmtpTransport<Tokio1Executor>,
    from: lettre::message::Mailbox,
}

impl Mailer {
    /// None when ONE_SMTP_HOST is unset — the email endpoints then 503.
    pub(crate) fn from_env() -> Option<Self> {
        let host = std::env::var("ONE_SMTP_HOST")
            .ok()
            .filter(|h| !h.trim().is_empty())?;
        let security = std::env::var("ONE_SMTP_SECURITY").unwrap_or_else(|_| "starttls".into());
        let default_port = match security.as_str() {
            "none" => 25,
            "tls" => 465,
            _ => 587,
        };
        let port: u16 = std::env::var("ONE_SMTP_PORT")
            .ok()
            .and_then(|p| p.parse().ok())
            .unwrap_or(default_port);
        let builder = match security.as_str() {
            "none" => lettre::AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous(&host),
            "tls" => lettre::AsyncSmtpTransport::<Tokio1Executor>::relay(&host).ok()?,
            _ => lettre::AsyncSmtpTransport::<Tokio1Executor>::starttls_relay(&host).ok()?,
        };
        let mut builder = builder.port(port);
        if let (Ok(user), Ok(pass)) = (
            std::env::var("ONE_SMTP_USER"),
            std::env::var("ONE_SMTP_PASS"),
        ) {
            if !user.is_empty() {
                builder = builder.credentials(
                    lettre::transport::smtp::authentication::Credentials::new(user, pass),
                );
            }
        }
        let from = std::env::var("ONE_SMTP_FROM")
            .unwrap_or_else(|_| "binocle <no-reply@binocle.local>".into())
            .parse()
            .ok()?;
        tracing::info!(host = %host, port, security = %security, "one: SMTP mailer configured");
        Some(Self {
            transport: builder.build(),
            from,
        })
    }

    async fn send(&self, to: &str, subject: &str, body: String) -> Result<(), String> {
        let msg = lettre::Message::builder()
            .from(self.from.clone())
            .to(to
                .parse()
                .map_err(|_| "invalid recipient address".to_string())?)
            .subject(subject)
            .header(lettre::message::header::ContentType::TEXT_PLAIN)
            .body(body)
            .map_err(|e| e.to_string())?;
        self.transport
            .send(msg)
            .await
            .map(|_| ())
            .map_err(|e| e.to_string())
    }
}

/// Issue a code for `(purpose, email)` and mail it. Resend-floor violations
/// surface as 429; SMTP failures as 502.
async fn send_code(
    one: &crate::one::OneState,
    purpose: &str,
    email: &str,
    subject: &str,
) -> Result<(), axum::response::Response> {
    let mailer = one.mailer.as_ref().ok_or_else(|| {
        api_err(
            StatusCode::SERVICE_UNAVAILABLE,
            "smtp_unconfigured",
            "email is not configured on this deployment (set ONE_SMTP_HOST)",
        )
    })?;
    let code = one
        .users
        .issue_code(purpose, email)
        .map_err(|m| api_err(StatusCode::TOO_MANY_REQUESTS, "resend_too_soon", m))?;
    let body = format!(
        "Your binocle code: {code}\n\nIt expires in 10 minutes. If you did not request this, ignore this message.\n"
    );
    mailer.send(email, subject, body).await.map_err(|e| {
        tracing::warn!(error = %e, "smtp send failed");
        api_err(
            StatusCode::BAD_GATEWAY,
            "smtp_failed",
            "could not send the email",
        )
    })
}

// ─── handlers ────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct EmailOnly {
    email: String,
}

#[derive(Deserialize)]
struct EmailCode {
    email: String,
    code: String,
}

#[derive(Deserialize)]
struct ResetConfirm {
    email: String,
    code: String,
    password: String,
}

/// POST /one/v1/auth/request-verification — bearer-authenticated; mails a
/// code to the account's own address.
async fn request_verification(
    State(state): State<AppState>,
    headers: header::HeaderMap,
) -> axum::response::Response {
    let one = match one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    let Some(token) = crate::one::bearer_token(&headers) else {
        return api_err(
            StatusCode::UNAUTHORIZED,
            "unauthorized",
            "Bearer token required",
        );
    };
    let id = match one.verify_jwt(&token) {
        Ok(id) => id,
        Err(r) => return r,
    };
    let Some(user) = one.users.get_user(&id.key_id) else {
        return api_err(
            StatusCode::UNAUTHORIZED,
            "unauthorized",
            "account no longer exists",
        );
    };
    if user.verified {
        return (StatusCode::OK, Json(json!({ "verified": true }))).into_response();
    }
    if let Err(r) = send_code(&one, "verify", &user.email, "Verify your email").await {
        return r;
    }
    (StatusCode::ACCEPTED, Json(json!({ "sent": true }))).into_response()
}

/// POST /one/v1/auth/confirm-verification {email, code}
async fn confirm_verification(
    State(state): State<AppState>,
    Json(req): Json<EmailCode>,
) -> axum::response::Response {
    let one = match one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    let email = req.email.trim().to_lowercase();
    if !one.users.consume_code("verify", &email, req.code.trim()) {
        return api_err(
            StatusCode::UNAUTHORIZED,
            "invalid_code",
            "wrong, expired or used code",
        );
    }
    if let Some(uid) = one.users.find_user_id_by_email(&email) {
        one.users.mark_verified(&uid);
        tracing::info!(target: "audit", event = "email_verified", user = %uid, "email verified");
    }
    StatusCode::NO_CONTENT.into_response()
}

/// POST /one/v1/auth/request-reset {email} — 202 whether or not the account
/// exists (no enumeration).
async fn request_reset(
    State(state): State<AppState>,
    Json(req): Json<EmailOnly>,
) -> axum::response::Response {
    let one = match one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    let email = req.email.trim().to_lowercase();
    if one.users.find_user_id_by_email(&email).is_some() {
        if let Err(r) = send_code(&one, "reset", &email, "Reset your password").await {
            return r;
        }
    }
    (StatusCode::ACCEPTED, Json(json!({ "sent": true }))).into_response()
}

/// POST /one/v1/auth/confirm-reset {email, code, password} — sets the new
/// password and revokes every outstanding refresh token.
async fn confirm_reset(
    State(state): State<AppState>,
    Json(req): Json<ResetConfirm>,
) -> axum::response::Response {
    let one = match one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    if req.password.len() < 8 {
        return api_err(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "password must be at least 8 characters",
        );
    }
    let email = req.email.trim().to_lowercase();
    if !one.users.consume_code("reset", &email, req.code.trim()) {
        return api_err(
            StatusCode::UNAUTHORIZED,
            "invalid_code",
            "wrong, expired or used code",
        );
    }
    let Some(uid) = one.users.find_user_id_by_email(&email) else {
        return api_err(
            StatusCode::UNAUTHORIZED,
            "invalid_code",
            "wrong, expired or used code",
        );
    };
    let password = req.password;
    let hash = match tokio::task::spawn_blocking(move || hash_password(&password)).await {
        Ok(Ok(h)) => h,
        _ => {
            return api_err(
                StatusCode::INTERNAL_SERVER_ERROR,
                "hash_failed",
                "password hashing failed",
            )
        }
    };
    if one.users.set_password(&uid, &hash).is_err() {
        return api_err(
            StatusCode::INTERNAL_SERVER_ERROR,
            "reset_failed",
            "could not update the password",
        );
    }
    one.users.revoke_user_refresh(&uid);
    one.users.mark_verified(&uid); // the code proved control of the inbox
    tracing::info!(target: "audit", event = "password_reset", user = %uid, "password reset; refresh tokens revoked");
    StatusCode::NO_CONTENT.into_response()
}

/// POST /one/v1/auth/request-otp {email} — passwordless login, step 1.
async fn request_otp(
    State(state): State<AppState>,
    Json(req): Json<EmailOnly>,
) -> axum::response::Response {
    let one = match one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    let email = req.email.trim().to_lowercase();
    if one.users.find_user_id_by_email(&email).is_some() {
        if let Err(r) = send_code(&one, "otp", &email, "Your login code").await {
            return r;
        }
    }
    (StatusCode::ACCEPTED, Json(json!({ "sent": true }))).into_response()
}

/// POST /one/v1/auth/login-otp {email, code} — passwordless login, step 2.
/// A TOTP-enabled account still gets the MFA challenge.
async fn login_otp(
    State(state): State<AppState>,
    Json(req): Json<EmailCode>,
) -> axum::response::Response {
    let one = match one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    let email = req.email.trim().to_lowercase();
    if !one.users.consume_code("otp", &email, req.code.trim()) {
        return api_err(
            StatusCode::UNAUTHORIZED,
            "invalid_code",
            "wrong, expired or used code",
        );
    }
    let Some(uid) = one.users.find_user_id_by_email(&email) else {
        return api_err(
            StatusCode::UNAUTHORIZED,
            "invalid_code",
            "wrong, expired or used code",
        );
    };
    one.users.mark_verified(&uid); // the code proved control of the inbox
    match one.finish_login(&uid) {
        Ok(body) => (StatusCode::OK, Json(body)).into_response(),
        Err(r) => r,
    }
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/one/v1/auth/request-verification",
            post(request_verification),
        )
        .route(
            "/one/v1/auth/confirm-verification",
            post(confirm_verification),
        )
        .route("/one/v1/auth/request-reset", post(request_reset))
        .route("/one/v1/auth/confirm-reset", post(confirm_reset))
        .route("/one/v1/auth/request-otp", post(request_otp))
        .route("/one/v1/auth/login-otp", post(login_otp))
}
