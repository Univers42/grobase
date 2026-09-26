//! Secret rotation: `JwtConfig::previous_secret` is accepted alongside the
//! current secret, never instead of it, and never widens the other checks.

#![allow(clippy::unwrap_used)]

use super::{JwtAuthProvider, JwtConfig};
use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use realtime_core::{AuthContext, AuthProvider};
use serde_json::json;

const CURRENT: &str = "the-current-realtime-secret-32-chars!";
const PREVIOUS: &str = "the-previous-realtime-secret-32-chars";

/// sign returns a token for `user-1` signed with `key` under `alg`, expiring
/// `exp_in` seconds from now (negative = already expired).
fn sign(key: &str, alg: Algorithm, exp_in: i64) -> String {
    #[allow(clippy::cast_sign_loss)]
    let exp = (chrono::Utc::now().timestamp() + exp_in) as u64;
    encode(
        &Header::new(alg),
        &json!({ "sub": "user-1", "exp": exp }),
        &EncodingKey::from_secret(key.as_bytes()),
    )
    .unwrap()
}

/// accepts reports whether a provider on CURRENT with `previous` verifies `token`.
async fn accepts(previous: Option<&str>, token: &str) -> bool {
    let mut cfg = JwtConfig::hmac(CURRENT);
    cfg.previous_secret = previous.map(str::to_string);
    let ctx = AuthContext {
        peer_addr: "127.0.0.1:1".parse().unwrap(),
        transport: "ws".to_string(),
    };
    let provider = JwtAuthProvider::new(&cfg).unwrap();
    provider.verify(token, &ctx).await.is_ok()
}

#[tokio::test]
async fn previous_secret_is_accepted_when_set() {
    assert!(accepts(Some(PREVIOUS), &sign(PREVIOUS, Algorithm::HS256, 600)).await);
    assert!(accepts(Some(PREVIOUS), &sign(CURRENT, Algorithm::HS256, 600)).await);
}

#[tokio::test]
async fn previous_secret_is_refused_when_unset() {
    assert!(!accepts(None, &sign(PREVIOUS, Algorithm::HS256, 600)).await);
    assert!(!accepts(Some(""), &sign(PREVIOUS, Algorithm::HS256, 600)).await);
    assert!(accepts(None, &sign(CURRENT, Algorithm::HS256, 600)).await);
}

#[tokio::test]
async fn an_unrelated_secret_is_refused() {
    let token = sign(
        "an-unrelated-secret-at-least-32-chars",
        Algorithm::HS256,
        600,
    );
    assert!(!accepts(Some(PREVIOUS), &token).await);
}

#[tokio::test]
async fn previous_equal_to_current_is_harmless() {
    assert!(accepts(Some(CURRENT), &sign(CURRENT, Algorithm::HS256, 600)).await);
    assert!(!accepts(Some(CURRENT), &sign(PREVIOUS, Algorithm::HS256, 600)).await);
}

#[tokio::test]
async fn previous_secret_keeps_the_algorithm_pinned() {
    assert!(!accepts(Some(PREVIOUS), &sign(PREVIOUS, Algorithm::HS384, 600)).await);
}

#[tokio::test]
async fn previous_secret_does_not_revive_an_expired_token() {
    assert!(!accepts(Some(PREVIOUS), &sign(PREVIOUS, Algorithm::HS256, -600)).await);
    assert!(!accepts(Some(PREVIOUS), &sign(CURRENT, Algorithm::HS256, -600)).await);
}
