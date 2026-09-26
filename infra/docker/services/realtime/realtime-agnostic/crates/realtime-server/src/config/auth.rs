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

//! Authentication configuration.

use serde::{Deserialize, Serialize};

/// Authentication backend selection.
///
/// - `NoAuth` — accepts all tokens (development only).
/// - `Jwt` — validates HMAC-SHA256 / RSA tokens.
#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum AuthConfig {
    #[serde(rename = "none")]
    #[default]
    NoAuth,
    #[serde(rename = "jwt")]
    Jwt {
        secret: String,
        #[serde(default)]
        issuer: Option<String>,
        #[serde(default)]
        audience: Option<String>,
        /// Accept tokens with no `iss` even when `issuer` lists values (opt-out).
        #[serde(default)]
        allow_no_issuer: bool,
        /// The secret being rotated out (`REALTIME_JWT_SECRET_PREV`), still accepted.
        #[serde(default)]
        previous_secret: Option<String>,
    },
}

/// Manual Debug: the server logs its config at startup (`Auth: {:?}`), and the
/// derived impl printed the JWT secret in plain text into container logs.
impl std::fmt::Debug for AuthConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NoAuth => write!(f, "NoAuth"),
            Self::Jwt {
                issuer,
                audience,
                allow_no_issuer,
                previous_secret,
                ..
            } => f
                .debug_struct("Jwt")
                .field("secret", &"<redacted>")
                .field(
                    "previous_secret",
                    &previous_secret.as_ref().map(|_| "<redacted>"),
                )
                .field("issuer", issuer)
                .field("audience", audience)
                .field("allow_no_issuer", allow_no_issuer)
                .finish(),
        }
    }
}
