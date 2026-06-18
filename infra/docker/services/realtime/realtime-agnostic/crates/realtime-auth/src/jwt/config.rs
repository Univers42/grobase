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
    /// Expected `iss` claim (optional).
    pub issuer: Option<String>,
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
            audience: None,
        }
    }
}
