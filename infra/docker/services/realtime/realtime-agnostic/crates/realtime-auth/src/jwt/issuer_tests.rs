/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   issuer_tests.rs                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! M-4: the `iss` allow-list and the missing-`iss` rule.

#![allow(clippy::unwrap_used)]

use super::{JwtAuthProvider, JwtConfig};
use jsonwebtoken::{encode, EncodingKey, Header};
use realtime_core::{AuthContext, AuthProvider};
use serde_json::{json, Value};

const SECRET: &str = "issuer-test-secret-at-least-32-chars";

/// token signs `claims` (an `exp` one hour out is added) with the test secret.
fn token(mut claims: Value) -> String {
    #[allow(clippy::cast_sign_loss)]
    let exp = chrono::Utc::now().timestamp() as u64 + 3600;
    claims["exp"] = json!(exp);
    claims["sub"] = json!("user-1");
    encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(SECRET.as_bytes()),
    )
    .unwrap()
}

/// accepts reports whether a provider built from `issuer`/`require` verifies `claims`.
async fn accepts(issuer: Option<&str>, require: bool, claims: Value) -> bool {
    let mut cfg = JwtConfig::hmac(SECRET);
    cfg.issuer = issuer.map(str::to_string);
    cfg.require_issuer = require;
    let ctx = AuthContext {
        peer_addr: "127.0.0.1:1".parse().unwrap(),
        transport: "ws".to_string(),
    };
    let provider = JwtAuthProvider::new(&cfg).unwrap();
    provider.verify(&token(claims), &ctx).await.is_ok()
}

const LIST: Option<&str> = Some("http://gw/auth/v1, supabase,,grobase-realtime");

#[tokio::test]
async fn listed_issuers_are_accepted() {
    for iss in ["http://gw/auth/v1", "supabase", "grobase-realtime"] {
        assert!(accepts(LIST, true, json!({ "iss": iss })).await, "{iss}");
    }
}

#[tokio::test]
async fn foreign_issuer_is_rejected() {
    assert!(!accepts(LIST, true, json!({ "iss": "osionos-bridge" })).await);
    assert!(!accepts(LIST, false, json!({ "iss": "osionos-bridge" })).await);
}

#[tokio::test]
async fn missing_issuer_is_rejected_unless_opted_out() {
    assert!(!accepts(LIST, true, json!({})).await);
    assert!(accepts(LIST, false, json!({})).await);
}

#[tokio::test]
async fn no_list_keeps_todays_behaviour() {
    assert!(accepts(None, true, json!({})).await);
    assert!(accepts(Some(" , "), true, json!({ "iss": "anything" })).await);
}

#[test]
fn accepted_issuers_trims_and_drops_blanks() {
    let mut cfg = JwtConfig::hmac(SECRET);
    cfg.issuer = LIST.map(str::to_string);
    assert_eq!(
        cfg.accepted_issuers(),
        ["http://gw/auth/v1", "supabase", "grobase-realtime"]
    );
}
