//! binocle-one TOTP MFA — RFC 6238 over the in-tree hmac, plus recovery codes.
//!
//! HMAC-SHA1 because that is what every authenticator app (Google
//! Authenticator, Aegis, 1Password, …) generates; SHA1's collision weakness
//! is irrelevant to HMAC-based OTPs. 6 digits, 30-second period, ±1 step
//! drift window.
//!
//! Enrolment is two-step (secret is *pending* until a valid code confirms it
//! — a lost QR can't lock anyone out). Confirmation returns eight single-use
//! recovery codes (digest-stored). With TOTP enabled, password/OTP login
//! returns `{mfa_required, mfa_token}` and `/one/v1/auth/totp/verify`
//! upgrades that 5-minute challenge into a session.

use axum::extract::State;
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::routing::post;
use axum::{Json, Router};
use hmac::{Hmac, Mac};
use serde::Deserialize;
use serde_json::json;

use crate::one::{one_of, sha256_hex};
use crate::routes::{api_err, AppState};

const PERIOD: u64 = 30;
const DIGITS: u32 = 6;

// ─── RFC 4648 base32 (no padding) — the otpauth:// secret alphabet ──────────

fn base32_encode(data: &[u8]) -> String {
    const ALPHABET: &[u8; 32] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    let mut out = String::with_capacity(data.len().div_ceil(5) * 8);
    for chunk in data.chunks(5) {
        let mut buf = [0u8; 5];
        buf[..chunk.len()].copy_from_slice(chunk);
        let n = u64::from(buf[0]) << 32
            | u64::from(buf[1]) << 24
            | u64::from(buf[2]) << 16
            | u64::from(buf[3]) << 8
            | u64::from(buf[4]);
        let chars = [4usize, 9, 14, 19, 24, 29, 34, 39];
        let emit = match chunk.len() {
            1 => 2,
            2 => 4,
            3 => 5,
            4 => 7,
            _ => 8,
        };
        for shift in chars.iter().take(emit) {
            out.push(ALPHABET[((n >> (39 - shift)) & 31) as usize] as char);
        }
    }
    out
}

fn base32_decode(s: &str) -> Option<Vec<u8>> {
    let mut bits: u64 = 0;
    let mut nbits = 0;
    let mut out = Vec::with_capacity(s.len() * 5 / 8);
    for c in s.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a',
            b'2'..=b'7' => c - b'2' + 26,
            b'=' => continue,
            _ => return None,
        };
        bits = (bits << 5) | u64::from(v);
        nbits += 5;
        if nbits >= 8 {
            nbits -= 8;
            out.push((bits >> nbits) as u8);
        }
    }
    Some(out)
}

// ─── RFC 4226 / 6238 ─────────────────────────────────────────────────────────

fn hotp(secret: &[u8], counter: u64) -> u32 {
    let mut mac = Hmac::<sha1::Sha1>::new_from_slice(secret).expect("hmac accepts any key length");
    mac.update(&counter.to_be_bytes());
    let h = mac.finalize().into_bytes();
    let o = (h[h.len() - 1] & 0xf) as usize;
    let dbc = u32::from_be_bytes([h[o], h[o + 1], h[o + 2], h[o + 3]]) & 0x7fff_ffff;
    dbc % 10u32.pow(DIGITS)
}

fn totp_at(secret: &[u8], unix: u64) -> u32 {
    hotp(secret, unix / PERIOD)
}

/// ±1 step drift window, constant format (leading zeros significant).
fn totp_verify(secret_b32: &str, code: &str, unix: u64) -> bool {
    let Some(secret) = base32_decode(secret_b32) else {
        return false;
    };
    let code = code.trim();
    if code.len() != DIGITS as usize {
        return false;
    }
    [-1i64, 0, 1].iter().any(|drift| {
        let t = unix.saturating_add_signed(drift * PERIOD as i64);
        format!("{:06}", totp_at(&secret, t)) == code
    })
}

fn now_unix() -> u64 {
    chrono::Utc::now().timestamp().max(0) as u64
}

// ─── handlers ────────────────────────────────────────────────────────────────

fn bearer_user(
    state: &AppState,
    headers: &header::HeaderMap,
) -> Result<(std::sync::Arc<crate::one::OneState>, crate::one::UserPublic), axum::response::Response> {
    let one = one_of(state)?;
    let token = crate::one::bearer_token(headers)
        .ok_or_else(|| api_err(StatusCode::UNAUTHORIZED, "unauthorized", "Bearer token required"))?;
    let id = one.verify_jwt(&token)?;
    let user = one.users.get_user(&id.key_id).ok_or_else(|| {
        api_err(StatusCode::UNAUTHORIZED, "unauthorized", "account no longer exists")
    })?;
    Ok((one, user))
}

/// POST /one/v1/auth/totp/enroll — generate a pending secret + otpauth URI.
async fn enroll(State(state): State<AppState>, headers: header::HeaderMap) -> axum::response::Response {
    let (one, user) = match bearer_user(&state, &headers) {
        Ok(v) => v,
        Err(r) => return r,
    };
    // 20 bytes of CSPRNG (uuid v4 is getrandom-backed), the RFC 4226 minimum.
    let mut raw = [0u8; 20];
    raw[..16].copy_from_slice(uuid::Uuid::new_v4().as_bytes());
    raw[16..].copy_from_slice(&uuid::Uuid::new_v4().as_bytes()[..4]);
    let secret = base32_encode(&raw);
    if one.users.totp_set_pending(&user.id, &secret).is_err() {
        return api_err(StatusCode::INTERNAL_SERVER_ERROR, "totp_failed", "could not store the secret");
    }
    let label = user.email.replace('@', "%40");
    let uri = format!("otpauth://totp/binocle:{label}?secret={secret}&issuer=binocle&period={PERIOD}&digits={DIGITS}");
    Json(json!({ "secret": secret, "otpauth_url": uri, "pending": true })).into_response()
}

#[derive(Deserialize)]
struct CodeOnly {
    code: String,
}

/// POST /one/v1/auth/totp/confirm {code} — flips the pending secret live and
/// returns the single batch of recovery codes (digests stored, never again).
async fn confirm(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Json(req): Json<CodeOnly>,
) -> axum::response::Response {
    let (one, user) = match bearer_user(&state, &headers) {
        Ok(v) => v,
        Err(r) => return r,
    };
    let Some((secret, _)) = one.users.totp_secret(&user.id) else {
        return api_err(StatusCode::BAD_REQUEST, "not_enrolled", "enroll first");
    };
    if !totp_verify(&secret, &req.code, now_unix()) {
        return api_err(StatusCode::UNAUTHORIZED, "invalid_code", "wrong TOTP code");
    }
    let codes: Vec<String> = (0..8)
        .map(|_| {
            let h = uuid::Uuid::new_v4().simple().to_string();
            format!("{}-{}", &h[..6], &h[6..12])
        })
        .collect();
    let digests: Vec<String> = codes.iter().map(|c| sha256_hex(c)).collect();
    if one.users.recovery_store(&user.id, &digests).is_err() {
        return api_err(StatusCode::INTERNAL_SERVER_ERROR, "totp_failed", "could not store recovery codes");
    }
    one.users.totp_enable(&user.id);
    tracing::info!(target: "audit", event = "totp_enabled", user = %user.id, "TOTP MFA enabled");
    Json(json!({ "enabled": true, "recovery_codes": codes })).into_response()
}

#[derive(Deserialize)]
struct MfaVerify {
    mfa_token: String,
    code: String,
}

/// POST /one/v1/auth/totp/verify {mfa_token, code} — second factor: a live
/// TOTP code or a single-use recovery code; upgrades the challenge to a
/// session.
async fn verify(State(state): State<AppState>, Json(req): Json<MfaVerify>) -> axum::response::Response {
    let one = match one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    let Some(user_id) = one.verify_mfa_token(&req.mfa_token) else {
        return api_err(StatusCode::UNAUTHORIZED, "unauthorized", "invalid or expired MFA token");
    };
    let totp_ok = one
        .users
        .totp_secret(&user_id)
        .map(|(secret, enabled)| enabled && totp_verify(&secret, &req.code, now_unix()))
        .unwrap_or(false);
    let ok = totp_ok || one.users.recovery_consume(&user_id, req.code.trim());
    if !ok {
        return api_err(StatusCode::UNAUTHORIZED, "invalid_code", "wrong TOTP or recovery code");
    }
    match one.issue_session(&user_id) {
        Ok(body) => (StatusCode::OK, Json(body)).into_response(),
        Err(r) => r,
    }
}

/// POST /one/v1/auth/totp/disable {code} — a live factor is required to turn
/// MFA off (a stolen session alone must not be able to strip it).
async fn disable(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Json(req): Json<CodeOnly>,
) -> axum::response::Response {
    let (one, user) = match bearer_user(&state, &headers) {
        Ok(v) => v,
        Err(r) => return r,
    };
    let totp_ok = one
        .users
        .totp_secret(&user.id)
        .map(|(secret, enabled)| enabled && totp_verify(&secret, &req.code, now_unix()))
        .unwrap_or(false);
    let ok = totp_ok || one.users.recovery_consume(&user.id, req.code.trim());
    if !ok {
        return api_err(StatusCode::UNAUTHORIZED, "invalid_code", "a valid TOTP or recovery code is required");
    }
    one.users.totp_remove(&user.id);
    tracing::info!(target: "audit", event = "totp_disabled", user = %user.id, "TOTP MFA disabled");
    StatusCode::NO_CONTENT.into_response()
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/one/v1/auth/totp/enroll", post(enroll))
        .route("/one/v1/auth/totp/confirm", post(confirm))
        .route("/one/v1/auth/totp/verify", post(verify))
        .route("/one/v1/auth/totp/disable", post(disable))
}

#[cfg(test)]
mod tests {
    use super::*;

    // RFC 6238 appendix B vectors use the ASCII secret "12345678901234567890".
    const RFC_SECRET: &[u8] = b"12345678901234567890";

    #[test]
    fn totp_matches_rfc6238_vectors() {
        // 8-digit reference values truncated to our 6 digits.
        assert_eq!(totp_at(RFC_SECRET, 59), 94287082 % 1_000_000);
        assert_eq!(totp_at(RFC_SECRET, 1111111109), 7081804 % 1_000_000);
        assert_eq!(totp_at(RFC_SECRET, 1234567890), 89005924 % 1_000_000);
    }

    #[test]
    fn base32_round_trip_and_rfc4648_vector() {
        assert_eq!(base32_encode(b""), "");
        assert_eq!(base32_encode(b"foobar"), "MZXW6YTBOI");
        assert_eq!(
            base32_encode(RFC_SECRET),
            "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        );
        assert_eq!(base32_decode("MZXW6YTBOI").as_deref(), Some(b"foobar".as_ref()));
        assert_eq!(base32_decode(&base32_encode(RFC_SECRET)).as_deref(), Some(RFC_SECRET));
        assert!(base32_decode("not base32!").is_none());
    }

    #[test]
    fn verify_accepts_drift_and_rejects_garbage() {
        let b32 = base32_encode(RFC_SECRET);
        let now = 1234567890u64;
        let code = format!("{:06}", totp_at(RFC_SECRET, now));
        assert!(totp_verify(&b32, &code, now));
        assert!(totp_verify(&b32, &code, now + PERIOD), "one step late still passes");
        assert!(!totp_verify(&b32, &code, now + 3 * PERIOD), "outside window fails");
        assert!(!totp_verify(&b32, "000000", now) || code == "000000");
        assert!(!totp_verify(&b32, "12345", now), "wrong length fails");
        assert!(!totp_verify("@@@", &code, now), "bad secret fails");
    }
}
