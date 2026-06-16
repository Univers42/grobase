/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mod.rs                                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! JWT-based authentication provider using HMAC-SHA256 (or RSA).
//!
//! Verifies JSON Web Tokens and extracts [`AuthClaims`] for authorization.
//! Supports `Bearer` prefix stripping, configurable issuer/audience
//! validation, and namespace-based access control.

mod auth;
mod config;

pub use config::JwtConfig;

use std::collections::HashMap;

use jsonwebtoken::{Algorithm, DecodingKey, Validation};
use realtime_core::{RealtimeError, Result};
use serde::{Deserialize, Serialize};

/// JWT authentication provider.
///
/// Verifies tokens using HMAC-SHA256 (or RSA if configured) and
/// extracts [`AuthClaims`] for namespace-based authorization.
pub struct JwtAuthProvider {
    pub(crate) decoding_key: DecodingKey,
    pub(crate) validation: Validation,
}

/// Internal JWT claims structure expected in the token payload.
#[derive(Debug, Serialize, Deserialize)]
pub(crate) struct JwtClaims {
    pub sub: String,
    pub exp: Option<u64>,
    pub iat: Option<u64>,
    #[serde(default)]
    pub namespaces: Vec<String>,
    #[serde(default)]
    pub can_publish: bool,
    #[serde(default = "default_true")]
    pub can_subscribe: bool,
    #[serde(default)]
    pub metadata: HashMap<String, serde_json::Value>,
}

const fn default_true() -> bool {
    true
}

impl JwtAuthProvider {
    /// Create a new JWT auth provider from config.
    ///
    /// Returns an error if the RSA PEM key is invalid (for RSA algorithms).
    ///
    /// # Errors
    ///
    /// Returns [`RealtimeError::Internal`] if the RSA public key PEM is invalid.
    pub fn new(config: &JwtConfig) -> Result<Self> {
        let decoding_key = build_decoding_key(config)?;
        let validation = build_validation(config);
        Ok(Self {
            decoding_key,
            validation,
        })
    }
}

fn build_decoding_key(config: &JwtConfig) -> Result<DecodingKey> {
    match config.algorithm {
        Algorithm::HS256 | Algorithm::HS384 | Algorithm::HS512 => {
            Ok(DecodingKey::from_secret(config.secret.as_bytes()))
        }
        _ => DecodingKey::from_rsa_pem(config.secret.as_bytes())
            .map_err(|e| RealtimeError::Internal(format!("Invalid RSA public key PEM: {e}"))),
    }
}

fn build_validation(config: &JwtConfig) -> Validation {
    let mut validation = Validation::new(config.algorithm);
    if let Some(ref issuer) = config.issuer {
        validation.set_issuer(&[issuer]);
    }
    if let Some(ref audience) = config.audience {
        validation.set_audience(&[audience]);
    } else {
        // When no audience is configured, accept tokens with any (or no) `aud` claim.
        // `Validation::new()` defaults `validate_aud` to `true`, which rejects tokens
        // containing an `aud` field when no expected audience is set.
        validation.validate_aud = false;
    }
    validation
}

#[allow(clippy::unwrap_used)]
#[cfg(test)]
mod tests {
    use super::*;
    use jsonwebtoken::{encode, EncodingKey, Header};
    use realtime_core::{AuthContext, AuthProvider, TopicPattern};

    fn create_test_jwt(claims: &JwtClaims, secret: &str) -> String {
        let key = EncodingKey::from_secret(secret.as_bytes());
        encode(&Header::default(), claims, &key).unwrap()
    }

    #[tokio::test]
    async fn test_jwt_verify_valid_token() {
        let secret = "test-secret-key-at-least-32-chars!!";
        let provider = JwtAuthProvider::new(&JwtConfig::hmac(secret)).unwrap();

        let jwt_claims = JwtClaims {
            sub: "user-123".to_string(),
            #[allow(clippy::cast_sign_loss)]
            exp: Some(chrono::Utc::now().timestamp() as u64 + 3600),
            #[allow(clippy::cast_sign_loss)]
            iat: Some(chrono::Utc::now().timestamp() as u64),
            namespaces: vec!["orders".to_string()],
            can_publish: true,
            can_subscribe: true,
            metadata: HashMap::new(),
        };

        let token = create_test_jwt(&jwt_claims, secret);

        let ctx = AuthContext {
            peer_addr: "127.0.0.1:12345".parse().unwrap(),
            transport: "ws".to_string(),
        };

        let claims = provider.verify(&token, &ctx).await.unwrap();
        assert_eq!(claims.sub, "user-123");
        assert!(claims.can_publish);
        assert!(claims.can_subscribe);
        assert!(claims.namespaces.contains(&"orders".to_string()));
    }

    #[tokio::test]
    async fn test_jwt_verify_invalid_token() {
        let provider =
            JwtAuthProvider::new(&JwtConfig::hmac("secret-key-32-chars-minimum!!!!")).unwrap();

        let ctx = AuthContext {
            peer_addr: "127.0.0.1:12345".parse().unwrap(),
            transport: "ws".to_string(),
        };

        let result = provider.verify("invalid-token", &ctx).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn test_jwt_verify_with_bearer_prefix() {
        let secret = "test-secret-key-at-least-32-chars!!";
        let provider = JwtAuthProvider::new(&JwtConfig::hmac(secret)).unwrap();

        let jwt_claims = JwtClaims {
            sub: "user-456".to_string(),
            #[allow(clippy::cast_sign_loss)]
            exp: Some(chrono::Utc::now().timestamp() as u64 + 3600),
            iat: None,
            namespaces: vec![],
            can_publish: false,
            can_subscribe: true,
            metadata: HashMap::new(),
        };

        let token = format!("Bearer {}", create_test_jwt(&jwt_claims, secret));

        let ctx = AuthContext {
            peer_addr: "127.0.0.1:12345".parse().unwrap(),
            transport: "ws".to_string(),
        };

        let claims = provider.verify(&token, &ctx).await.unwrap();
        assert_eq!(claims.sub, "user-456");
        assert!(!claims.can_publish);
    }

    #[tokio::test]
    async fn test_jwt_authorize_subscribe() {
        let secret = "test-secret-key-at-least-32-chars!!";
        let provider = JwtAuthProvider::new(&JwtConfig::hmac(secret)).unwrap();

        let claims = realtime_core::AuthClaims {
            sub: "user1".to_string(),
            namespaces: vec!["orders".to_string()],
            can_publish: false,
            can_subscribe: true,
            metadata: HashMap::new(),
        };

        let topic_ok = TopicPattern::parse("orders/created");
        let topic_denied = TopicPattern::parse("admin/settings");

        assert!(provider
            .authorize_subscribe(&claims, &topic_ok)
            .await
            .is_ok());
        assert!(provider
            .authorize_subscribe(&claims, &topic_denied)
            .await
            .is_err());
    }
}
