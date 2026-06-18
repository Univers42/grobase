/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   auth.rs                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! [`AuthProvider`] trait implementation for JWT verification.

use async_trait::async_trait;
use jsonwebtoken::decode;
use realtime_core::{
    AuthClaims, AuthContext, AuthProvider, RealtimeError, Result, TopicPath, TopicPattern,
};
use tracing::{debug, warn};

use super::{JwtAuthProvider, JwtClaims};

#[async_trait]
impl AuthProvider for JwtAuthProvider {
    async fn verify(&self, token: &str, _context: &AuthContext) -> Result<AuthClaims> {
        let token = token.strip_prefix("Bearer ").unwrap_or(token);
        let token_data =
            decode::<JwtClaims>(token, &self.decoding_key, &self.validation).map_err(|e| {
                warn!("JWT verification failed: {}", e);
                RealtimeError::AuthFailed(format!("Invalid token: {e}"))
            })?;
        let claims = token_data.claims;
        debug!(sub = %claims.sub, "JWT verified successfully");
        Ok(build_auth_claims(claims))
    }

    async fn authorize_subscribe(&self, claims: &AuthClaims, topic: &TopicPattern) -> Result<()> {
        if claims.can_subscribe_to(topic) {
            Ok(())
        } else {
            Err(RealtimeError::AuthorizationDenied(format!(
                "Not authorized to subscribe to {topic}"
            )))
        }
    }

    async fn authorize_publish(&self, claims: &AuthClaims, topic: &TopicPath) -> Result<()> {
        if claims.can_publish_to(topic) {
            Ok(())
        } else {
            Err(RealtimeError::AuthorizationDenied(format!(
                "Not authorized to publish to {topic}"
            )))
        }
    }
}

/// Whether a namespace-less token should fall back to all-access (`["*"]`) or
/// be denied. DENY is the secure posture (Phase 5); permissive is a one-release
/// backward-compat escape hatch. Policy:
///   * `REALTIME_NAMESPACE_FALLBACK=permissive|deny` — explicit, wins;
///   * else `SECURITY_MODE=max` — deny (max mode is strict by default);
///   * else — permissive (baseline keeps existing namespace-less tokens working
///     for one release, with a deprecation warning each time it's exercised).
fn namespace_fallback_permissive() -> bool {
    match std::env::var("REALTIME_NAMESPACE_FALLBACK").ok().as_deref() {
        Some("permissive") => true,
        Some("deny") => false,
        _ => std::env::var("SECURITY_MODE").ok().as_deref() != Some("max"),
    }
}

fn build_auth_claims(claims: JwtClaims) -> AuthClaims {
    let mut namespaces = claims.namespaces;
    // `&&` short-circuits identically to the previous nested `if`s; deny mode
    // (or a non-empty namespace list) leaves `namespaces` untouched so
    // can_subscribe_to/can_publish_to deny by default — the secure posture.
    if namespaces.is_empty() && namespace_fallback_permissive() {
        // DEPRECATED (Phase 5→6): a namespace-less token is being granted
        // all-access. Set SECURITY_MODE=max or REALTIME_NAMESPACE_FALLBACK=deny
        // to deny instead; mint tokens with explicit `namespaces`.
        warn!(
            sub = %claims.sub,
            "namespace-less token granted ALL-access via permissive fallback (deprecated; \
             set REALTIME_NAMESPACE_FALLBACK=deny / SECURITY_MODE=max to deny)"
        );
        namespaces = vec!["*".to_string()];
    }
    AuthClaims {
        sub: claims.sub,
        namespaces,
        can_publish: claims.can_publish,
        can_subscribe: claims.can_subscribe,
        metadata: claims.metadata,
    }
}
