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

use async_trait::async_trait;

use crate::error::Result;
use crate::types::{AuthClaims, AuthContext, TopicPath, TopicPattern};

/// Authentication provider — verifies tokens and authorizes operations.
///
/// # Purpose
/// Implement this trait to plug in custom auth schemes (JWT, OAuth,
/// API keys). The `noauth` module provides a dev-mode implementation.
#[async_trait]
pub trait AuthProvider: Send + Sync + 'static {
    /// Verify a bearer token and return decoded claims.
    ///
    /// # Arguments
    /// * `token` — Raw token string from the AUTH message.
    /// * `context` — Peer address and transport metadata.
    ///
    /// # Errors
    /// Returns `AuthError` if the token is invalid or expired.
    async fn verify(&self, token: &str, context: &AuthContext) -> Result<AuthClaims>;

    /// Authorize a subscribe request against claims.
    ///
    /// # Errors
    /// Returns `AuthError` if subscription is denied.
    async fn authorize_subscribe(&self, claims: &AuthClaims, topic: &TopicPattern) -> Result<()>;

    /// Authorize a publish request against claims.
    ///
    /// # Errors
    /// Returns `AuthError` if publishing is denied.
    async fn authorize_publish(&self, claims: &AuthClaims, topic: &TopicPath) -> Result<()>;

    /// Authorize a presence TRACK against claims.
    ///
    /// A token that may publish to `topic` may track it. A subscribe-only token
    /// may too when its issuer opted in with `metadata.can_track: true`: an
    /// issuer that keeps clients off PUBLISH (so its own write gate cannot be
    /// bypassed) still needs every member to announce presence. The opt-in is
    /// checked by this provider's own subscribe rule on the EXACT topic, so the
    /// namespace and protected-prefix rules apply unchanged.
    ///
    /// # Errors
    /// Returns `AuthError` if tracking is denied.
    async fn authorize_track(&self, claims: &AuthClaims, topic: &TopicPath) -> Result<()> {
        let publish = self.authorize_publish(claims, topic).await;
        let opted_in = claims
            .metadata
            .get("can_track")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false);
        if publish.is_ok() || !opted_in {
            return publish;
        }
        self.authorize_subscribe(claims, &TopicPattern::Exact(topic.clone()))
            .await
    }
}
