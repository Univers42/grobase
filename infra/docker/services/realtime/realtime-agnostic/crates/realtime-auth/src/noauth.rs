/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   noauth.rs                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! No-authentication provider for development and testing.
//!
//! Accepts **any** token and grants full access to all namespaces.
//! **Never use this in production.**

use std::collections::HashMap;

use async_trait::async_trait;
use realtime_core::{AuthClaims, AuthContext, AuthProvider, Result, TopicPath, TopicPattern};

/// Development-only auth provider that accepts all tokens.
///
/// Returns [`AuthClaims`] with `can_publish: true`, `can_subscribe: true`,
/// and `namespaces: ["*"]` regardless of the token value. If the token
/// is empty, the subject is set to `"anonymous"`.
pub struct NoAuthProvider;

impl NoAuthProvider {
    /// Create a new no-auth provider.
    #[must_use]
    pub const fn new() -> Self {
        Self
    }
}

impl Default for NoAuthProvider {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl AuthProvider for NoAuthProvider {
    async fn verify(&self, token: &str, _context: &AuthContext) -> Result<AuthClaims> {
        // In no-auth mode, accept any token and return full-access claims
        Ok(AuthClaims {
            sub: if token.is_empty() {
                "anonymous".to_string()
            } else {
                token.to_string()
            },
            namespaces: vec!["*".to_string()],
            can_publish: true,
            can_subscribe: true,
            metadata: HashMap::default(),
        })
    }

    async fn authorize_subscribe(&self, _claims: &AuthClaims, _topic: &TopicPattern) -> Result<()> {
        Ok(())
    }

    async fn authorize_publish(&self, _claims: &AuthClaims, _topic: &TopicPath) -> Result<()> {
        Ok(())
    }
}

#[allow(clippy::unwrap_used)]
#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_noauth_accepts_everything() {
        let provider = NoAuthProvider::new();
        let ctx = AuthContext {
            peer_addr: "127.0.0.1:12345".parse().unwrap(),
            transport: "ws".to_string(),
        };
        let claims = provider.verify("any-token", &ctx).await.unwrap();
        assert!(claims.can_publish);
        assert!(claims.can_subscribe);
        assert!(claims.namespaces.contains(&"*".to_string()));
    }
}
