/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   config.rs                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Configuration for the JWT auth provider.

use jsonwebtoken::Algorithm;

/// Configuration for the JWT auth provider.
///
/// Use [`JwtConfig::hmac()`] for the common HMAC-SHA256 setup.
pub struct JwtConfig {
    /// HMAC secret string or RSA PEM-encoded public key.
    pub secret: String,
    /// JWT algorithm (default: HS256).
    pub algorithm: Algorithm,
    /// Accepted `iss` values, comma-separated (optional). Blank entries are ignored.
    pub issuer: Option<String>,
    /// With a non-empty issuer list, reject tokens that carry no `iss` at all.
    pub require_issuer: bool,
    /// Expected `aud` claim (optional).
    pub audience: Option<String>,
}

impl JwtConfig {
    /// Create a simple HMAC-SHA256 JWT config.
    pub fn hmac(secret: impl Into<String>) -> Self {
        Self {
            secret: secret.into(),
            algorithm: Algorithm::HS256,
            issuer: None,
            require_issuer: true,
            audience: None,
        }
    }

    /// Returns the accepted `iss` values: the comma-separated `issuer` list,
    /// trimmed, blanks dropped. Empty means no issuer check.
    pub fn accepted_issuers(&self) -> Vec<&str> {
        self.issuer.as_deref().map_or_else(Vec::new, |raw| {
            raw.split(',')
                .map(str::trim)
                .filter(|i| !i.is_empty())
                .collect()
        })
    }
}
